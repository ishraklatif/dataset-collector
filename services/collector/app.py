"""Dedicated collector API. Binary uploads and ZIP streams never spool to disk."""
import base64
import hashlib
import io
import json
import os
import secrets
import threading
import uuid
import zipfile
from collections import deque
from datetime import datetime, timezone
from functools import wraps
from urllib.parse import urlparse

import click
import psycopg
from flask import Flask, Response, g, jsonify, request, stream_with_context, render_template_string
from psycopg.rows import dict_row
from psycopg.types.json import Jsonb
from psycopg_pool import ConnectionPool
from werkzeug.security import check_password_hash, generate_password_hash

from domain import CLASSES, MODEL_HASH, MODEL_METADATA, Invalid, boxes, image_info, yolo_labels
from drive import DriveClient, DriveError

def digest(value):
    return hashlib.sha256(value.encode() if isinstance(value, str) else value).hexdigest()

def uid(value):
    try:
        return str(uuid.UUID(str(value)))
    except (ValueError, TypeError, AttributeError) as error:
        raise Invalid('Invalid UUID') from error

def new_id():
    return str(uuid.uuid4())

def json_dump(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), default=str)

def create_app(config=None):
    app = Flask(__name__)
    app.config.update(MAX_CONTENT_LENGTH=int(os.getenv('MAX_IMAGE_BYTES', '12582912')),
                      MAX_IMAGE_DIMENSION=int(os.getenv('MAX_IMAGE_DIMENSION', '4096')),
                      MAX_EXPORT_SAMPLES=int(os.getenv('MAX_EXPORT_SAMPLES', '5000')),
                      PUBLIC_BASE_URL=os.getenv('PUBLIC_BASE_URL', '').rstrip('/'),
                      DATABASE_URL=os.getenv('DATABASE_URL', ''),
                      ALLOW_LOCAL_DATABASE=os.getenv('ALLOW_LOCAL_DATABASE') == '1',
                      DB_BYTE_LIMIT=int(os.getenv('DB_BYTE_LIMIT', '1073741824')),
                      ARCHIVE_PROMPT_RATIO=float(os.getenv('ARCHIVE_PROMPT_RATIO', '0.95')),
                      MAX_ARCHIVE_SAMPLES=int(os.getenv('MAX_ARCHIVE_SAMPLES', '50')),
                      MAX_ARCHIVE_BYTES=int(os.getenv('MAX_ARCHIVE_BYTES', '157286400')),
                      GOOGLE_OAUTH_CLIENT_ID=os.getenv('GOOGLE_OAUTH_CLIENT_ID', ''),
                      GOOGLE_OAUTH_CLIENT_SECRET=os.getenv('GOOGLE_OAUTH_CLIENT_SECRET', ''),
                      GOOGLE_OAUTH_REFRESH_TOKEN=os.getenv('GOOGLE_OAUTH_REFRESH_TOKEN', ''),
                      GOOGLE_DRIVE_FOLDER_ID=os.getenv('GOOGLE_DRIVE_FOLDER_ID', ''))
    if config:
        app.config.update(config)
    from psycopg.conninfo import conninfo_to_dict
    if not app.config['DATABASE_URL']:
        raise RuntimeError('A dedicated PostgreSQL DATABASE_URL is required')
    options = conninfo_to_dict(app.config['DATABASE_URL'])
    if not (app.config['ALLOW_LOCAL_DATABASE'] and options.get('host') in ('localhost', '127.0.0.1')):
        if options.get('sslmode') != 'verify-full':
            raise RuntimeError('Production database connections require sslmode=verify-full')
    pool = ConnectionPool(app.config['DATABASE_URL'], min_size=0, max_size=int(os.getenv('DB_POOL_SIZE', '4')),
                          timeout=10, kwargs={'row_factory': dict_row, 'connect_timeout': 10}, open=True)
    app.extensions['pool'] = pool
    upload_slots = threading.BoundedSemaphore(2)
    export_slots = threading.BoundedSemaphore(1)

    @app.errorhandler(Invalid)
    def invalid(error):
        return jsonify(error=str(error)), 400

    @app.errorhandler(413)
    def too_large(error):
        return jsonify(error='Image exceeds byte limit'), 413

    @app.errorhandler(500)
    def failed(error):
        return jsonify(error='Server request failed; retry with the same sample ID'), 500

    @app.errorhandler(psycopg.Error)
    def database_failure(error):
        # Database exception detail can include rejected binary values. Log only a code.
        app.logger.error('Database request failed: %s', error.sqlstate or 'connection')
        return jsonify(error='Database request failed; retry with the same sample ID'), 503

    @app.after_request
    def no_cache(response):
        response.headers['Cache-Control'] = 'no-store'
        response.headers['X-Content-Type-Options'] = 'nosniff'
        return response

    def authenticated(fn):
        @wraps(fn)
        def wrapper(*args, **kwargs):
            token = request.headers.get('Authorization', '').removeprefix('Bearer ')
            if not token or len(token) > 256:
                return jsonify(error='Sign in required'), 401
            with pool.connection() as conn:
                session = conn.execute('SELECT operator_id FROM auth_sessions WHERE token_hash=%s AND NOT revoked AND expires_at>now()', (digest(token),)).fetchone()
            if not session:
                return jsonify(error='Session expired or revoked'), 401
            g.operator = session['operator_id']
            return fn(*args, **kwargs)
        return wrapper

    def authorized(conn, project_id):
        return conn.execute('SELECT 1 FROM project_members WHERE project_id=%s AND operator_id=%s', (project_id, g.operator)).fetchone() is not None

    def sample(conn, sample_id, lock=False):
        return conn.execute('''SELECT s.*,i.width,i.height,i.sha256,i.archived_at,r.status,r.explicit_negative
            FROM samples s JOIN sample_images i ON i.sample_id=s.id JOIN annotation_revisions r ON r.id=s.current_revision
            JOIN project_members m ON m.project_id=s.project_id AND m.operator_id=%s
            WHERE s.id=%s AND s.deleted_at IS NULL''' + (' FOR UPDATE OF s' if lock else ''), (g.operator, sample_id)).fetchone()

    def annotations(conn, revision):
        if conn.execute("SELECT to_regclass('annotation_polygons') AS polygons_table").fetchone()['polygons_table']:
            return conn.execute('''SELECT a.class_id,a.x,a.y,a.width,a.height,p.points FROM annotations a
                LEFT JOIN annotation_polygons p USING(revision_id,ordinal) WHERE a.revision_id=%s ORDER BY a.ordinal''', (revision,)).fetchall()
        rows=conn.execute('SELECT class_id,x,y,width,height FROM annotations WHERE revision_id=%s ORDER BY ordinal', (revision,)).fetchall()
        return [dict(row,points=None) for row in rows]

    def insert_revision(conn, sample_id, annotations_value, status, negative):
        revision = new_id()
        conn.execute('INSERT INTO annotation_revisions(id,sample_id,reviewer_id,status,explicit_negative,reviewed_at) VALUES(%s,%s,%s,%s,%s,%s)',
                     (revision, sample_id, g.operator, status, negative, datetime.now(timezone.utc) if status == 'approved' else None))
        has_polygon_table=bool(conn.execute("SELECT to_regclass('annotation_polygons') AS polygons_table").fetchone()['polygons_table'])
        for index, box in enumerate(annotations_value):
            if box.get('points') is not None and not has_polygon_table:
                raise Invalid('Polygon migration is not applied to the collector database')
            conn.execute('INSERT INTO annotations(revision_id,ordinal,class_id,x,y,width,height) VALUES(%s,%s,%s,%s,%s,%s,%s)', (revision, index, box['class_id'], box['x'], box['y'], box['width'], box['height']))
            if box.get('points') is not None:
                conn.execute('INSERT INTO annotation_polygons(revision_id,ordinal,points) VALUES(%s,%s,%s)', (revision,index,Jsonb(box['points'])))
        return revision

    def approved_unarchived_samples(conn, project, limit):
        rows = conn.execute('''SELECT s.id,s.session_id,s.captured_at,s.current_revision,i.sha256,i.width,i.height,i.byte_count,
            r.explicit_negative,p.model_hash,p.proposals,c.specimen_id,c.scene_tags,sp.designation,sp.name AS specimen_name
            FROM samples s JOIN sample_images i ON i.sample_id=s.id JOIN annotation_revisions r ON r.id=s.current_revision
            JOIN prediction_runs p ON p.sample_id=s.id JOIN capture_sessions c ON c.id=s.session_id JOIN specimens sp ON sp.id=c.specimen_id
            WHERE s.project_id=%s AND s.deleted_at IS NULL AND r.status='approved' AND i.archived_at IS NULL
            ORDER BY s.id LIMIT %s''', (project, limit+1)).fetchall()
        if len(rows) > limit:
            raise Invalid('Approved collection exceeds the configured sample limit for this operation')
        for row in rows:
            row['annotations'] = annotations(conn, row['current_revision'])
            boxes(row['annotations'], row['width'], row['height'])
            if any(box.get('points') is None for box in row['annotations']):
                raise Invalid('Reopen and approve legacy rectangles as polygons before freezing this segmentation dataset')
            if (not row['annotations']) != row['explicit_negative']:
                raise Invalid('Invalid negative review')
        return rows

    def zip_chunks(manifest, version):
        class Sink:
            def __init__(self):
                self.chunks=deque(); self.position=0
            def write(self,data):
                self.chunks.append(bytes(data)); self.position+=len(data); return len(data)
            def tell(self):
                return self.position
            def flush(self):
                pass
        sink=Sink()
        def info(name):
            z=zipfile.ZipInfo('collector-export-'+version+'/'+name,date_time=(2026,1,1,0,0,0))
            z.compress_type=zipfile.ZIP_STORED
            z.external_attr=0o644<<16
            return z
        with zipfile.ZipFile(sink,'w',allowZip64=True) as archive:
            for item in manifest['samples']:
                with pool.connection() as conn:
                    image=conn.execute('SELECT image_bytes,width,height,sha256 FROM sample_images WHERE sample_id=%s',(item['id'],)).fetchone()
                if image['image_bytes'] is None:
                    raise Invalid('Sample image was archived to Google Drive after this version was frozen')
                data=bytes(image['image_bytes'])
                if digest(data)!=item['sha256'] or image['width']!=item['width'] or image['height']!=item['height']:
                    raise Invalid('Frozen image checksum/dimensions disagree')
                image_info(data,app.config['MAX_CONTENT_LENGTH'],app.config['MAX_IMAGE_DIMENSION'])
                with archive.open(info('images/'+item['id']+'.jpg'),'w',force_zip64=True) as output:
                    for offset in range(0,len(data),65536):
                        output.write(data[offset:offset+65536])
                        while sink.chunks:
                            yield sink.chunks.popleft()
                del data,image
                archive.writestr(info('labels/'+item['id']+'.txt'),yolo_labels(item['annotations'],item['width'],item['height']))
                while sink.chunks:
                    yield sink.chunks.popleft()
            archive.writestr(info('manifest.json'),json_dump(manifest))
            archive.writestr(info('data.yaml'),'# YOLO instance-segmentation labels. UNSPLIT COLLECTION: prepare independent grouped train/val/test splits before training.\npath: .\nnames:\n'+''.join(f'  {i}: {name}\n' for i,name in enumerate(CLASSES)))
            archive.writestr(info('README.md'),'Approved unsplit instance-segmentation collection. Each label row contains a class ID followed by normalized polygon vertex pairs in YOLO segmentation format. Images and immutable human annotations are frozen by version. Group related sessions/specimens and review near-duplicates before creating train/validation/test splits. Train a segmentation model, not a detection-only model. No validation/test paths are supplied intentionally.\n')
        while sink.chunks:
            yield sink.chunks.popleft()

    @app.get('/healthz')
    def healthz():
        return jsonify(status='running')

    @app.post('/v1/login')
    def login():
        body = request.get_json() or {}
        username, password = body.get('username', ''), body.get('password', '')
        if not isinstance(username, str) or not isinstance(password, str) or len(username)>100 or len(password)>256:
            raise Invalid('Invalid credentials')
        with pool.connection() as conn:
            attempt = conn.execute("""INSERT INTO login_attempts VALUES(%s,1,now()+interval '10 minutes')
                ON CONFLICT(key) DO UPDATE SET attempts=CASE WHEN login_attempts.expires_at<now() THEN 1 ELSE login_attempts.attempts+1 END,
                expires_at=CASE WHEN login_attempts.expires_at<now() THEN now()+interval '10 minutes' ELSE login_attempts.expires_at END RETURNING attempts""", (digest(username.lower()),)).fetchone()
            if attempt['attempts'] > 30:
                return jsonify(error='Too many login attempts; wait ten minutes'), 429
            user = conn.execute('SELECT * FROM operators WHERE username=%s', (username,)).fetchone()
            # Perform a password check even for unknown accounts. Rate-limit login at the ingress.
            hash_value = user['password_hash'] if user else app.config.setdefault('DUMMY_HASH', generate_password_hash(secrets.token_hex(32)))
            if not check_password_hash(hash_value, password) or not user:
                return jsonify(error='Invalid credentials'), 401
            token = secrets.token_urlsafe(48)
            conn.execute("INSERT INTO auth_sessions VALUES(%s,%s,now()+interval '7 days',false)", (digest(token), user['id']))
        return jsonify(token=token)

    @app.post('/v1/logout')
    @authenticated
    def logout():
        with pool.connection() as conn:
            conn.execute('UPDATE auth_sessions SET revoked=true WHERE token_hash=%s', (digest(request.headers['Authorization'].removeprefix('Bearer ')),))
        return jsonify(ok=True)

    @app.get('/v1/health')
    @authenticated
    def health():
        with pool.connection() as conn:
            projects = conn.execute('SELECT p.* FROM projects p JOIN project_members m ON m.project_id=p.id WHERE m.operator_id=%s ORDER BY p.name', (g.operator,)).fetchall()
            polygon_schema=bool(conn.execute("SELECT to_regclass('annotation_polygons') AS polygons_table").fetchone()['polygons_table'])
            db_bytes_used = conn.execute('SELECT pg_database_size(current_database()) AS size').fetchone()['size']
        needs_archive = db_bytes_used >= app.config['DB_BYTE_LIMIT'] * app.config['ARCHIVE_PROMPT_RATIO']
        return jsonify(projects=projects, max_image_bytes=app.config['MAX_CONTENT_LENGTH'], max_image_dimension=app.config['MAX_IMAGE_DIMENSION'], model_hash=MODEL_HASH, annotation_format='yolo-segmentation-v1' if polygon_schema else 'yolo-detection-v1', db_bytes_used=db_bytes_used, db_byte_limit=app.config['DB_BYTE_LIMIT'], needs_archive=needs_archive)

    @app.route('/v1/projects/<project>/sessions', methods=['GET', 'POST'])
    @authenticated
    def sessions(project):
        project = uid(project)
        with pool.connection() as conn:
            if not authorized(conn, project):
                return jsonify(error='Project unavailable'), 404
            if request.method == 'GET':
                return jsonify(sessions=conn.execute('SELECT c.*,s.name AS specimen_name,s.designation FROM capture_sessions c JOIN specimens s ON s.id=c.specimen_id WHERE c.project_id=%s ORDER BY c.started_at DESC LIMIT 100', (project,)).fetchall())
            body = request.get_json() or {}
            name, specimen_name, designation = body.get('name'), body.get('specimen'), body.get('designation')
            if not all(isinstance(v, str) and 0<len(v)<=200 for v in (name, specimen_name)) or designation not in ('real','proxy'):
                raise Invalid('Session name, specimen identity, and real/proxy designation are required')
            tags = body.get('scene_tags', [])
            if not isinstance(tags,list) or len(tags)>20 or any(not isinstance(t,str) or len(t)>100 for t in tags):
                raise Invalid('Invalid scene tags')
            specimen = conn.execute('INSERT INTO specimens VALUES(%s,%s,%s,%s) ON CONFLICT(project_id,name,designation) DO UPDATE SET name=EXCLUDED.name RETURNING id', (new_id(), project, specimen_name, designation)).fetchone()['id']
            session_id = new_id()
            conn.execute('INSERT INTO capture_sessions(id,project_id,specimen_id,name,device,scene_tags) VALUES(%s,%s,%s,%s,%s,%s)', (session_id, project, specimen, name, str(body.get('device','iPhone'))[:100], Jsonb(tags)))
        return jsonify(id=session_id), 201

    @app.post('/v1/samples')
    @authenticated
    def upload():
        if request.mimetype != 'image/jpeg':
            raise Invalid('Upload binary JPEG with X-Capture metadata')
        if not upload_slots.acquire(blocking=False):
            return jsonify(error='Upload busy; retry the same sample'), 503
        try:
            header = request.headers.get('X-Capture','')
            if len(header)>24576:
                raise Invalid('Capture metadata too large')
            try:
                metadata = json.loads(base64.b64decode(header, validate=True))
            except (ValueError, UnicodeDecodeError) as error:
                raise Invalid('Invalid capture metadata') from error
            if not isinstance(metadata,dict):
                raise Invalid('Invalid capture metadata')
            sample_id, project, session_id = (uid(metadata.get(k)) for k in ('id','project_id','session_id'))
            if request.headers.get('Idempotency-Key') != sample_id:
                raise Invalid('Idempotency-Key must equal sample UUID')
            if metadata.get('model_hash') != MODEL_HASH or metadata.get('preprocessing_version') != MODEL_METADATA['preprocessing_version']:
                raise Invalid('Unsupported model or preprocessing version')
            try:
                captured_at = datetime.fromisoformat(metadata['captured_at'].replace('Z','+00:00'))
                if captured_at.tzinfo is None:
                    raise ValueError()
            except (KeyError, ValueError, AttributeError) as error:
                raise Invalid('Capture timestamp requires a timezone') from error
            data = request.get_data(cache=False)
            width, height, image_hash = image_info(data, app.config['MAX_CONTENT_LENGTH'], app.config['MAX_IMAGE_DIMENSION'])
            if metadata.get('sha256') != image_hash or metadata.get('width') != width or metadata.get('height') != height:
                raise Invalid('Image hash or dimensions disagree')
            proposals = boxes(metadata.get('proposals'), width, height, predictions=True)
            request_hash = digest(image_hash + json_dump(metadata))
            with pool.connection() as conn:
                if not authorized(conn,project):
                    return jsonify(error='Project unavailable'), 404
                if not conn.execute('SELECT 1 FROM capture_sessions WHERE id=%s AND project_id=%s AND ended_at IS NULL', (session_id,project)).fetchone():
                    raise Invalid('Active session unavailable')
                # Serializes a retry even if its first request has not committed yet.
                conn.execute('SELECT pg_advisory_xact_lock(hashtextextended(%s,0))', (sample_id,))
                old = conn.execute('SELECT id,project_id,request_hash,deleted_at,current_revision FROM samples WHERE id=%s', (sample_id,)).fetchone()
                if old:
                    if str(old['project_id']) != project or old['request_hash'] != request_hash or old['deleted_at']:
                        return jsonify(error='Sample ID conflicts with a different or discarded request'), 409
                    result = {'id': sample_id, 'revision': str(old['current_revision']), 'saved': True}
                else:
                    initial = new_id()
                    conn.execute('INSERT INTO model_versions VALUES(%s,%s) ON CONFLICT DO NOTHING', (MODEL_HASH,Jsonb(MODEL_METADATA)))
                    conn.execute('INSERT INTO samples(id,project_id,session_id,captured_at,request_hash,current_revision) VALUES(%s,%s,%s,%s,%s,%s)', (sample_id,project,session_id,captured_at,request_hash,initial))
                    conn.execute('INSERT INTO sample_images VALUES(%s,%s,%s,%s,%s,%s,%s)', (sample_id,data,'image/jpeg',image_hash,width,height,len(data)))
                    conn.execute('INSERT INTO prediction_runs VALUES(%s,%s,%s,%s)', (sample_id,MODEL_HASH,Jsonb(proposals),Jsonb(MODEL_METADATA)))
                    conn.execute('INSERT INTO annotation_revisions(id,sample_id,reviewer_id,status,explicit_negative) VALUES(%s,%s,%s,%s,false)', (initial,sample_id,g.operator,'pending_review'))
                    for i, b in enumerate(proposals):
                        conn.execute('INSERT INTO annotations(revision_id,ordinal,class_id,x,y,width,height) VALUES(%s,%s,%s,%s,%s,%s,%s)', (initial,i,b['class_id'],b['x'],b['y'],b['width'],b['height']))
                    result = {'id': sample_id, 'revision': initial, 'saved': True}
            # Pool context commits before an acknowledgment is returned.
            return jsonify(result), 201
        finally:
            upload_slots.release()

    @app.get('/v1/projects/<project>/samples')
    @authenticated
    def list_samples(project):
        project = uid(project)
        try:
            offset = max(0,int(request.args.get('offset',0)))
        except ValueError as error:
            raise Invalid('Invalid page offset') from error
        with pool.connection() as conn:
            if not authorized(conn,project):
                return jsonify(error='Project unavailable'), 404
            rows = conn.execute('''SELECT s.id,s.session_id,s.captured_at,s.current_revision,r.status,r.explicit_negative,i.width,i.height,i.sha256,i.archived_at,
                COALESCE((SELECT array_agg(DISTINCT a.class_id ORDER BY a.class_id) FROM annotations a WHERE a.revision_id=s.current_revision),ARRAY[]::integer[]) AS class_ids
                FROM samples s JOIN annotation_revisions r ON r.id=s.current_revision JOIN sample_images i ON i.sample_id=s.id
                WHERE s.project_id=%s AND s.deleted_at IS NULL ORDER BY s.created_at DESC,s.id LIMIT 50 OFFSET %s''', (project,offset)).fetchall()
            counts = conn.execute('SELECT r.status,count(*) AS count FROM samples s JOIN annotation_revisions r ON r.id=s.current_revision WHERE s.project_id=%s AND s.deleted_at IS NULL GROUP BY r.status', (project,)).fetchall()
            classes = conn.execute('''SELECT a.class_id,count(*) AS instances,count(DISTINCT s.id) AS images FROM samples s
                JOIN annotations a ON a.revision_id=s.current_revision WHERE s.project_id=%s AND s.deleted_at IS NULL GROUP BY a.class_id ORDER BY a.class_id''', (project,)).fetchall()
        return jsonify(samples=rows, counts=counts, classes=classes, next_offset=offset+50 if len(rows)==50 else None)

    @app.route('/v1/samples/<sample_id>', methods=['GET','DELETE'])
    @authenticated
    def sample_detail(sample_id):
        with pool.connection() as conn:
            row = sample(conn,uid(sample_id),request.method=='DELETE')
            if not row:
                return jsonify(error='Sample unavailable'), 404
            if request.method == 'DELETE':
                conn.execute('UPDATE samples SET deleted_at=now() WHERE id=%s',(sample_id,))
                return jsonify(discarded=True)
            row['annotations'] = annotations(conn,row['current_revision'])
            row['proposals'] = conn.execute('SELECT proposals FROM prediction_runs WHERE sample_id=%s',(sample_id,)).fetchone()['proposals']
        return jsonify(row)

    @app.get('/v1/samples/<sample_id>/image')
    @authenticated
    def get_image(sample_id):
        with pool.connection() as conn:
            row = sample(conn,uid(sample_id))
            if not row:
                return jsonify(error='Sample unavailable'), 404
            data = conn.execute('SELECT image_bytes FROM sample_images WHERE sample_id=%s',(sample_id,)).fetchone()['image_bytes']
            if data is None:
                return jsonify(error='Image archived to Google Drive'), 410
        return Response(bytes(data), mimetype='image/jpeg')

    @app.put('/v1/samples/<sample_id>/review')
    @authenticated
    def review(sample_id):
        body = request.get_json() or {}
        with pool.connection() as conn:
            row = sample(conn,uid(sample_id),True)
            if not row:
                return jsonify(error='Sample unavailable'), 404
            if uid(body.get('expected_revision')) != str(row['current_revision']):
                return jsonify(error='Review changed on the server; reload before saving'), 409
            if row['archived_at']:
                raise Invalid('Image archived to Google Drive; this sample can no longer be reviewed')
            status, negative = body.get('status'), body.get('explicit_negative',False)
            if status not in ('pending_review','approved') or type(negative) is not bool:
                raise Invalid('Invalid review state')
            final = boxes(body.get('annotations'),row['width'],row['height'])
            if status=='approved' and any(box.get('points') is None for box in final):
                raise Invalid('Convert every rectangle to a reviewed polygon before approving this sample')
            if status=='approved' and ((not final) != negative):
                raise Invalid('Confirm empty negative explicitly; nonempty reviews cannot be negative')
            revision = insert_revision(conn,sample_id,final,status,negative)
            conn.execute('UPDATE samples SET current_revision=%s WHERE id=%s',(revision,sample_id))
        return jsonify(revision=revision,status=status,saved=True)

    @app.post('/v1/projects/<project>/versions')
    @authenticated
    def freeze(project):
        project = uid(project)
        with pool.connection() as conn:
            conn.execute('SET TRANSACTION ISOLATION LEVEL REPEATABLE READ')
            if not authorized(conn,project):
                return jsonify(error='Project unavailable'), 404
            rows = approved_unarchived_samples(conn, project, app.config['MAX_EXPORT_SAMPLES'])
            if not rows:
                raise Invalid('Approve at least one sample before export')
            version, job = new_id(),new_id()
            manifest = json.loads(json_dump({'schema_version':2,'label_format':'yolo-segmentation','version':version,'split':'unsplit','classes':CLASSES,'models':{MODEL_HASH:MODEL_METADATA},'samples':rows}))
            conn.execute('INSERT INTO dataset_versions(id,project_id,manifest) VALUES(%s,%s,%s)',(version,project,Jsonb(manifest)))
            for row in rows:
                conn.execute('INSERT INTO dataset_version_samples(version_id,sample_id,revision_id,image_hash,capture_group) VALUES(%s,%s,%s,%s,%s)',(version,row['id'],row['current_revision'],row['sha256'],row['session_id']))
            conn.execute("INSERT INTO export_jobs(id,version_id,status,validation) VALUES(%s,%s,'ready',%s)",(job,version,Jsonb({'samples':len(rows),'labels_valid':True})))
        return jsonify(id=version,job_id=job,samples=len(rows)),201

    @app.post('/v1/projects/<project>/archive')
    @authenticated
    def archive_to_drive(project):
        project = uid(project)
        if not (app.config['GOOGLE_OAUTH_CLIENT_ID'] and app.config['GOOGLE_OAUTH_CLIENT_SECRET']
                and app.config['GOOGLE_OAUTH_REFRESH_TOKEN'] and app.config['GOOGLE_DRIVE_FOLDER_ID']):
            return jsonify(error='Google Drive archiving is not configured on this backend'), 503
        if not export_slots.acquire(blocking=False):
            return jsonify(error='Export busy; retry later'), 503
        try:
            with pool.connection() as conn:
                conn.execute('SET TRANSACTION ISOLATION LEVEL REPEATABLE READ')
                if not authorized(conn, project):
                    export_slots.release()
                    return jsonify(error='Project unavailable'), 404
                rows = approved_unarchived_samples(conn, project, app.config['MAX_ARCHIVE_SAMPLES'])
                if not rows:
                    raise Invalid('No newly approved, unarchived samples to archive')
                sample_ids = [r['id'] for r in rows]
                already_versioned = conn.execute(
                    'SELECT DISTINCT sample_id FROM dataset_version_samples WHERE sample_id = ANY(%s)',
                    (sample_ids,)).fetchall()
                warnings = []
                if already_versioned:
                    warnings.append(f'{len(already_versioned)} of these samples already belong to an earlier frozen '
                                     'dataset version; that version will no longer be downloadable as a ZIP once '
                                     'this archive run completes. Use the Drive copy instead.')
                version, job = new_id(), new_id()
                bytes_freed = sum(r['byte_count'] for r in rows)
                manifest = json.loads(json_dump({'schema_version':2,'label_format':'yolo-segmentation','version':version,
                    'split':'unsplit','classes':CLASSES,'models':{MODEL_HASH:MODEL_METADATA},'samples':rows}))
                conn.execute('INSERT INTO dataset_versions(id,project_id,manifest) VALUES(%s,%s,%s)',(version,project,Jsonb(manifest)))
                for row in rows:
                    conn.execute('INSERT INTO dataset_version_samples(version_id,sample_id,revision_id,image_hash,capture_group) VALUES(%s,%s,%s,%s,%s)',
                                 (version,row['id'],row['current_revision'],row['sha256'],row['session_id']))
                conn.execute("INSERT INTO export_jobs(id,version_id,status) VALUES(%s,%s,'streaming')",(job,version))
        except Exception:
            export_slots.release()
            raise

        try:
            buffer = bytearray()
            for chunk in zip_chunks(manifest, version):
                buffer += chunk
                if len(buffer) > app.config['MAX_ARCHIVE_BYTES']:
                    raise Invalid('This batch is too large to archive in one call; lower MAX_ARCHIVE_SAMPLES or try again')
            drive = DriveClient(app.config['GOOGLE_OAUTH_CLIENT_ID'], app.config['GOOGLE_OAUTH_CLIENT_SECRET'],
                                 app.config['GOOGLE_OAUTH_REFRESH_TOKEN'], app.config['GOOGLE_DRIVE_FOLDER_ID'])
            result = drive.upload_zip(bytes(buffer), f'collector-export-{version}.zip')
        except (Invalid, DriveError) as error_obj:
            with pool.connection() as conn:
                conn.execute("UPDATE export_jobs SET status='failed',error=%s WHERE id=%s",(str(error_obj),job))
            export_slots.release()
            raise Invalid(str(error_obj)) from error_obj
        except Exception:
            with pool.connection() as conn:
                conn.execute("UPDATE export_jobs SET status='failed',error=%s WHERE id=%s",('Archive build failed',job))
            export_slots.release()
            raise

        try:
            with pool.connection() as conn:
                conn.execute('UPDATE sample_images SET image_bytes=NULL,archived_at=now() WHERE sample_id=ANY(%s) AND archived_at IS NULL',(sample_ids,))
                conn.execute("UPDATE export_jobs SET status='complete',validation=%s WHERE id=%s",
                             (Jsonb({'drive_file_id':result['id'],'drive_link':result.get('webViewLink'),'bytes_freed':bytes_freed}),job))
        finally:
            export_slots.release()
        return jsonify(version=version, job_id=job, samples=len(rows), drive_link=result.get('webViewLink'),
                       bytes_freed=bytes_freed, warnings=warnings), 201

    @app.get('/v1/projects/<project>/versions')
    @authenticated
    def versions(project):
        project=uid(project)
        with pool.connection() as conn:
            if not authorized(conn,project):
                return jsonify(error='Project unavailable'),404
            rows=conn.execute('''SELECT v.id,v.created_at,(SELECT count(*) FROM dataset_version_samples s WHERE s.version_id=v.id) AS samples,
                (SELECT status FROM export_jobs j WHERE j.version_id=v.id ORDER BY j.created_at DESC LIMIT 1) AS status,
                (SELECT j.validation->>'drive_link' FROM export_jobs j WHERE j.version_id=v.id ORDER BY j.created_at DESC LIMIT 1) AS drive_link
                FROM dataset_versions v WHERE v.project_id=%s ORDER BY v.created_at DESC LIMIT 100''',(project,)).fetchall()
        return jsonify(versions=rows)

    @app.post('/v1/versions/<version>/link')
    @authenticated
    def download_link(version):
        version=uid(version)
        base=app.config['PUBLIC_BASE_URL']
        if not base.startswith('https://'):
            return jsonify(error='Configure PUBLIC_BASE_URL with the deployed HTTPS endpoint'),503
        with pool.connection() as conn:
            row=conn.execute('SELECT project_id FROM dataset_versions WHERE id=%s',(version,)).fetchone()
            if not row or not authorized(conn,row['project_id']):
                return jsonify(error='Version unavailable'),404
            token=secrets.token_urlsafe(48)
            conn.execute("INSERT INTO download_tokens VALUES(%s,%s,%s,now()+interval '30 minutes')",(digest(token),version,g.operator))
        return jsonify(url=base+'/download/'+token,expires_in=1800)

    def export(version):
        if not export_slots.acquire(blocking=False):
            return jsonify(error='Export busy; retry later'),503
        try:
            with pool.connection() as conn:
                row=conn.execute('SELECT manifest FROM dataset_versions WHERE id=%s',(version,)).fetchone()
                if not row:
                    export_slots.release()
                    return jsonify(error='Version unavailable'),404
                manifest=row['manifest']
                job=new_id()
                conn.execute("INSERT INTO export_jobs(id,version_id,status) VALUES(%s,%s,'streaming')",(job,version))
        except Exception:
            export_slots.release()
            raise

        def stream():
            status,error='complete',None
            try:
                yield from zip_chunks(manifest, version)
            except GeneratorExit:
                status,error='interrupted','Client disconnected before stream completion'
                raise
            except Exception:
                status,error='failed','Checksum, label validation, or export stream failed'
                raise
            finally:
                export_slots.release()
                with pool.connection() as conn:
                    conn.execute('UPDATE export_jobs SET status=%s,error=%s WHERE id=%s',(status,error,job))
        response=Response(stream_with_context(stream()),mimetype='application/zip')
        response.headers['Content-Disposition']=f'attachment; filename="collector-export-{version}.zip"'
        response.headers['Referrer-Policy']='no-referrer'
        return response

    def resolve_download(token):
        # This capability grants access to one immutable version, never the database.
        with pool.connection() as conn:
            row=conn.execute('''SELECT t.version_id FROM download_tokens t JOIN dataset_versions v ON v.id=t.version_id
                JOIN project_members m ON m.project_id=v.project_id AND m.operator_id=t.operator_id
                WHERE t.token_hash=%s AND t.expires_at>now()''',(digest(token),)).fetchone()
        return str(row['version_id']) if row else None

    @app.get('/download/<token>')
    def download_page(token):
        # URL share previews fetch a text-only page, never the ZIP or a dataset image.
        # The archive requires a deliberate click on the training computer.
        if not resolve_download(token):
            return jsonify(error='Download link expired or unavailable'),404
        response=Response(render_template_string('''<!doctype html><html lang="en"><meta charset="utf-8">
            <meta name="viewport" content="width=device-width,initial-scale=1"><title>Collector export</title>
            <h1>Reviewed collection export</h1><p>Open this page on the training computer to download the unsplit dataset.
            The link expires 30 minutes after creation.</p><a href="{{ path }}">Download ZIP on the training computer</a></html>''',path='/download/'+token+'/archive'),mimetype='text/html')
        response.headers['Referrer-Policy']='no-referrer'
        response.headers['Content-Security-Policy']="default-src 'none'; base-uri 'none'; frame-ancestors 'none'"
        return response

    @app.get('/download/<token>/archive')
    def token_download(token):
        version=resolve_download(token)
        if not version:
            return jsonify(error='Download link expired or unavailable'),404
        return export(version)

    @app.cli.command('migrate')
    def migrate():
        import pathlib
        import psycopg
        migration_url=os.getenv('MIGRATION_DATABASE_URL')
        if not migration_url:
            raise click.ClickException('Set MIGRATION_DATABASE_URL separately from runtime credentials')
        with psycopg.connect(migration_url) as conn:
            conn.execute('SELECT pg_advisory_xact_lock(10602026)')
            migrations=pathlib.Path(__file__).with_name('migrations')
            if not conn.execute("SELECT to_regclass('schema_migrations')").fetchone()[0]:
                conn.execute((migrations/'001_collector.sql').read_text())
                click.echo('Migration 1 applied')
            for path in sorted(migrations.glob('[0-9][0-9][0-9]_*.sql')):
                version=int(path.name[:3])
                if version==1 or conn.execute('SELECT 1 FROM schema_migrations WHERE version=%s',(version,)).fetchone():
                    continue
                conn.execute(path.read_text())
                click.echo(f'Migration {version} applied')

    @app.cli.command('create-operator')
    @click.option('--username',prompt=True)
    @click.option('--password',prompt=True,hide_input=True,confirmation_prompt=True)
    @click.option('--project-name',default='AR Collector')
    def create_operator(username,password,project_name):
        if len(password)<12:
            raise click.ClickException('Use at least 12 characters')
        import psycopg
        if not os.getenv('MIGRATION_DATABASE_URL'):
            raise click.ClickException('Administration requires MIGRATION_DATABASE_URL')
        with psycopg.connect(os.environ['MIGRATION_DATABASE_URL']) as conn:
            operator,project=new_id(),new_id()
            conn.execute('INSERT INTO operators VALUES(%s,%s,%s)',(operator,username,generate_password_hash(password)))
            conn.execute('INSERT INTO projects VALUES(%s,%s)',(project,project_name))
            conn.execute('INSERT INTO project_members VALUES(%s,%s)',(project,operator))
        click.echo('Operator created; project ID: '+project)

    @app.cli.command('revoke-operator')
    @click.argument('username')
    def revoke_operator(username):
        import psycopg
        with psycopg.connect(os.environ['MIGRATION_DATABASE_URL']) as conn:
            conn.execute('UPDATE auth_sessions SET revoked=true WHERE operator_id=(SELECT id FROM operators WHERE username=%s)',(username,))
            conn.execute('DELETE FROM download_tokens WHERE operator_id=(SELECT id FROM operators WHERE username=%s)',(username,))
        click.echo('Device sessions and export links revoked')

    return app
