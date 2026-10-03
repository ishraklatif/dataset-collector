import base64
import hashlib
import io
import json
import uuid
import zipfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import psycopg
import pytest
from PIL import Image
import app as app_module
from app import digest
from domain import MODEL_HASH, MODEL_METADATA, Invalid, boxes, image_info, yolo_labels
from drive import DriveError

AUTH={'Authorization':'Bearer test-token'}
OTHER={'Authorization':'Bearer other-token'}

def jpeg():
    buffer=io.BytesIO()
    Image.new('RGB',(320,240),(120,30,60)).save(buffer,format='JPEG')
    return buffer.getvalue()

def prepare(env,proposals=None):
    app,dsn,project,_,_=env
    client=app.test_client()
    session=client.post('/v1/projects/'+project+'/sessions',headers=AUTH,json={'name':'Scene 1','specimen':'Tube A','designation':'proxy'}).json['id']
    data=jpeg()
    metadata={'id':str(uuid.uuid4()),'project_id':project,'session_id':session,'captured_at':'2026-10-01T10:00:00Z','width':320,'height':240,'sha256':digest(data),'model_hash':MODEL_HASH,'preprocessing_version':MODEL_METADATA['preprocessing_version'],'proposals':proposals or []}
    headers={**AUTH,'Content-Type':'image/jpeg','Idempotency-Key':metadata['id'],'X-Capture':base64.b64encode(json.dumps(metadata).encode()).decode()}
    return client,data,metadata,headers

def send(client,data,headers):
    return client.post('/v1/samples',data=data,headers=headers)

def approve(client,sample_id,revision,annotations=None,negative=True):
    return client.put('/v1/samples/'+sample_id+'/review',headers=AUTH,json={'expected_revision':revision,'status':'approved','explicit_negative':negative,'annotations':annotations or []})

def test_geometry_validation_and_yolo():
    valid={'class_id':0,'x':10,'y':20,'width':40,'height':60}
    assert yolo_labels([valid],100,100)=='0 0.100000000 0.200000000 0.500000000 0.200000000 0.500000000 0.800000000 0.100000000 0.800000000\n'
    assert yolo_labels([],100,100)==''
    for change in ({'class_id':5},{'class_id':True},{'x':float('nan')},{'width':0},{'x':90}):
        with pytest.raises(Invalid):
            boxes([{**valid,**change}],100,100)
    polygon={**valid,'points':[{'x':20,'y':10},{'x':70,'y':20},{'x':60,'y':80},{'x':10,'y':60}]}
    assert yolo_labels([polygon],100,100)=='0 0.200000000 0.100000000 0.700000000 0.200000000 0.600000000 0.800000000 0.100000000 0.600000000\n'
    for points in ([{'x':1,'y':1},{'x':2,'y':2}],
                   [{'x':10,'y':10},{'x':90,'y':90},{'x':10,'y':90},{'x':90,'y':10}],
                   [{'x':-1,'y':10},{'x':90,'y':10},{'x':50,'y':90}]):
        with pytest.raises(Invalid):boxes([{**valid,'points':points}],100,100)

def test_images_require_canonical_bytes():
    assert image_info(jpeg(),12000000,4096)[:2]==(320,240)
    with pytest.raises(Invalid):image_info(jpeg(),10,4096)
    with pytest.raises(Invalid):image_info(jpeg(),12000000,100)
    with pytest.raises(Invalid):image_info(b'not an image',12000000,4096)
    buffer=io.BytesIO();exif=Image.Exif();exif[274]=6
    Image.new('RGB',(10,20)).save(buffer,format='JPEG',exif=exif)
    with pytest.raises(Invalid):image_info(buffer.getvalue(),12000000,4096)

def test_atomic_upload_and_lost_ack_retry(env):
    client,data,meta,headers=prepare(env)
    first=send(client,data,headers)
    assert first.status_code==201,first.json
    second=send(client,data,headers)
    assert second.json==first.json
    with psycopg.connect(env[1]) as conn:
        assert conn.execute('SELECT count(*) FROM samples').fetchone()[0]==1
        row=conn.execute('SELECT image_bytes,sha256 FROM sample_images').fetchone()
        assert bytes(row[0])==data and row[1]==hashlib.sha256(data).hexdigest()
        assert conn.execute('SELECT status FROM annotation_revisions').fetchone()[0]=='pending_review'
    assert client.get('/v1/samples/'+meta['id']+'/image',headers=AUTH).data==data
    listing=client.get('/v1/projects/'+env[2]+'/samples',headers=AUTH)
    assert b'image_bytes' not in listing.data
    assert listing.headers['Cache-Control']=='no-store'

def test_simultaneous_retries_create_one_sample(env):
    _,data,meta,headers=prepare(env)
    def attempt(_):
        with env[0].test_client() as client:return send(client,data,headers)
    with ThreadPoolExecutor(max_workers=2) as executor:
        results=list(executor.map(attempt,range(2)))
    assert all(r.status_code==201 for r in results)
    assert results[0].json==results[1].json
    with psycopg.connect(env[1]) as conn:assert conn.execute('SELECT count(*) FROM samples').fetchone()[0]==1

def test_conflicting_idempotency_request_rejected(env):
    client,data,meta,headers=prepare(env)
    assert send(client,data,headers).status_code==201
    meta['captured_at']='2026-10-01T11:00:00Z'
    headers['X-Capture']=base64.b64encode(json.dumps(meta).encode()).decode()
    assert send(client,data,headers).status_code==409

def test_upload_transaction_rolls_back_on_database_error(env):
    client,data,meta,headers=prepare(env)
    with psycopg.connect(env[1]) as conn:
        conn.execute("CREATE FUNCTION fail_image() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'injected failure'; END $$")
        conn.execute('CREATE TRIGGER fail BEFORE INSERT ON sample_images FOR EACH ROW EXECUTE FUNCTION fail_image()')
    assert send(client,data,headers).status_code==503
    with psycopg.connect(env[1]) as conn:
        for table in ('samples','sample_images','prediction_runs','annotation_revisions','annotations'):
            assert conn.execute('SELECT count(*) FROM '+table).fetchone()[0]==0

def test_project_access_isolation_and_revocation(env):
    client,data,meta,headers=prepare(env)
    send(client,data,headers)
    assert client.get('/v1/samples/'+meta['id'],headers=OTHER).status_code==404
    assert client.get('/v1/samples/'+meta['id']+'/image',headers=OTHER).status_code==404
    assert client.get('/v1/projects/'+env[2]+'/samples',headers=OTHER).status_code==404
    assert client.get('/v1/health').status_code==401
    assert client.post('/v1/logout',headers=AUTH).status_code==200
    assert client.get('/v1/health',headers=AUTH).status_code==401

def test_negative_review_and_stale_writes(env):
    client,data,meta,headers=prepare(env)
    revision=send(client,data,headers).json['revision']
    assert approve(client,meta['id'],revision,negative=False).status_code==400
    accepted=approve(client,meta['id'],revision)
    assert accepted.status_code==200
    assert approve(client,meta['id'],revision).status_code==409
    draft=client.put('/v1/samples/'+meta['id']+'/review',headers=AUTH,json={'expected_revision':accepted.json['revision'],'status':'pending_review','explicit_negative':False,'annotations':[]})
    assert draft.status_code==200
    assert client.get('/v1/samples/'+meta['id'],headers=AUTH).json['status']=='pending_review'
    assert client.post('/v1/projects/'+env[2]+'/versions',headers=AUTH).status_code==400

def test_frozen_export_retains_original_review_and_image(env,tmp_path):
    box={'class_id':4,'x':10,'y':20,'width':40,'height':50,'confidence':0.9}
    client,data,meta,headers=prepare(env,[box])
    revision=send(client,data,headers).json['revision']
    final=[{**box,'class_id':0},{**box,'x':80,'class_id':0}]
    final=[{k:v for k,v in b.items() if k!='confidence'} for b in final]
    for b in final:
        b['points']=[{'x':b['x'],'y':b['y']},{'x':b['x']+b['width'],'y':b['y']},
                     {'x':b['x']+b['width'],'y':b['y']+b['height']},{'x':b['x'],'y':b['y']+b['height']}]
    accepted=approve(client,meta['id'],revision,final,False)
    assert accepted.status_code==200,accepted.json
    version=client.post('/v1/projects/'+env[2]+'/versions',headers=AUTH).json['id']
    # Later edits and deliberate discard must not alter the frozen revision.
    assert client.put('/v1/samples/'+meta['id']+'/review',headers=AUTH,json={'expected_revision':accepted.json['revision'],'status':'pending_review','annotations':[]}).status_code==200
    assert client.delete('/v1/samples/'+meta['id'],headers=AUTH).status_code==200
    url=client.post('/v1/versions/'+version+'/link',headers=AUTH).json['url'].removeprefix('https://collector.example.com')
    page=client.get(url)
    assert page.mimetype=='text/html' and b'Download ZIP on the training computer' in page.data
    assert b'<img' not in page.data and not page.data.startswith(b'PK')
    url+='/archive'
    response=client.get(url)
    assert response.status_code==200
    first=response.data
    assert client.get(url).data==first
    sys_path=Path(__file__).resolve().parents[3]/'scripts'
    import importlib.util
    spec=importlib.util.spec_from_file_location('independent_validator',sys_path/'validate_export.py')
    validator=importlib.util.module_from_spec(spec);spec.loader.exec_module(validator)
    path=tmp_path/'export.zip';path.write_bytes(first)
    result=validator.validate(path,tmp_path/'previews')
    assert result['images']==1 and result['objects']==2
    with zipfile.ZipFile(io.BytesIO(first)) as archive:
        prefix='collector-export-'+version+'/'
        assert archive.read(prefix+'images/'+meta['id']+'.jpg')==data
        rows=archive.read(prefix+'labels/'+meta['id']+'.txt').decode().splitlines()
        assert len(rows)==2 and all(len(row.split())==9 for row in rows)
        assert all(row.startswith('0 ') for row in rows)
        manifest=json.loads(archive.read(prefix+'manifest.json'))
        assert manifest['samples'][0]['current_revision']==accepted.json['revision']
        assert manifest['samples'][0]['proposals'][0]['class_id']==4
        assert 'val:' not in archive.read(prefix+'data.yaml').decode()
    with psycopg.connect(env[1]) as conn:
        assert conn.execute("SELECT status FROM export_jobs ORDER BY created_at DESC LIMIT 1").fetchone()[0]=='complete'

def test_approved_negative_exports_empty_label(env):
    client,data,meta,headers=prepare(env)
    revision=send(client,data,headers).json['revision'];approve(client,meta['id'],revision)
    version=client.post('/v1/projects/'+env[2]+'/versions',headers=AUTH).json['id']
    url=client.post('/v1/versions/'+version+'/link',headers=AUTH).json['url'].removeprefix('https://collector.example.com')
    with zipfile.ZipFile(io.BytesIO(client.get(url+'/archive').data)) as archive:
        assert archive.read('collector-export-'+version+'/labels/'+meta['id']+'.txt')==b''

def test_polygon_annotation_roundtrips_and_exports_segmentation(env,tmp_path):
    client,data,meta,headers=prepare(env)
    revision=send(client,data,headers).json['revision']
    polygon={'class_id':2,'x':20,'y':20,'width':120,'height':160,
             'points':[{'x':80,'y':20},{'x':140,'y':80},{'x':110,'y':180},{'x':35,'y':150},{'x':20,'y':65}]}
    accepted=approve(client,meta['id'],revision,[polygon],False)
    assert accepted.status_code==200,accepted.json
    detail=client.get('/v1/samples/'+meta['id'],headers=AUTH).json
    assert detail['annotations'][0]['points']==polygon['points']
    with psycopg.connect(env[1]) as conn:
        assert conn.execute('SELECT points FROM annotation_polygons WHERE revision_id=%s',(accepted.json['revision'],)).fetchone()[0]==polygon['points']
    version=client.post('/v1/projects/'+env[2]+'/versions',headers=AUTH).json['id']
    link=client.post('/v1/versions/'+version+'/link',headers=AUTH).json['url'].removeprefix('https://collector.example.com')
    archive_bytes=client.get(link+'/archive').data
    with zipfile.ZipFile(io.BytesIO(archive_bytes)) as archive:
        prefix='collector-export-'+version+'/'
        label=archive.read(prefix+'labels/'+meta['id']+'.txt').decode().strip().split()
        assert len(label)==11 and label[0]=='2'
        manifest=json.loads(archive.read(prefix+'manifest.json'))
        assert manifest['label_format']=='yolo-segmentation'
        assert manifest['samples'][0]['annotations'][0]['points']==polygon['points']
    script=Path(__file__).resolve().parents[3]/'scripts'/'validate_export.py'
    import importlib.util
    spec=importlib.util.spec_from_file_location('polygon_export_validator',script)
    validator=importlib.util.module_from_spec(spec);spec.loader.exec_module(validator)
    path=tmp_path/'polygon.zip';path.write_bytes(archive_bytes)
    assert validator.validate(path)['objects']==1

def test_api_remains_usable_before_polygon_migration(env):
    app,dsn,project,_,schema=env
    with psycopg.connect(dsn) as conn:
        conn.execute('DROP TABLE annotation_polygons CASCADE')
        conn.execute('DELETE FROM schema_migrations WHERE version=2')
    proposal={'class_id':0,'x':20,'y':20,'width':80,'height':80,'confidence':0.8}
    client,data,meta,headers=prepare(env,[proposal])
    health=client.get('/v1/health',headers=AUTH)
    assert health.json['annotation_format']=='yolo-detection-v1'
    assert send(client,data,headers).status_code==201
    detail=client.get('/v1/samples/'+meta['id'],headers=AUTH)
    assert detail.status_code==200 and detail.json['annotations'][0]['points'] is None

def test_database_rejects_mutating_frozen_content(env):
    client,data,meta,headers=prepare(env);result=send(client,data,headers)
    polygon={'class_id':0,'x':20,'y':20,'width':80,'height':80,'points':[{'x':20,'y':20},{'x':100,'y':20},{'x':100,'y':100},{'x':20,'y':100}]}
    accepted=approve(client,meta['id'],result.json['revision'],[polygon],False)
    with psycopg.connect(env[1]) as conn:
        with pytest.raises(psycopg.Error):conn.execute('UPDATE sample_images SET width=100 WHERE sample_id=%s',(meta['id'],))
        with pytest.raises(psycopg.Error):conn.execute("UPDATE annotation_polygons SET points='[]' WHERE revision_id=%s",(accepted.json['revision'],))
    with psycopg.connect(env[1]) as conn:
        with pytest.raises(psycopg.Error):conn.execute('DELETE FROM annotation_revisions WHERE id=%s',(result.json['revision'],))
    with psycopg.connect(env[1]) as conn:
        with pytest.raises(psycopg.Error):conn.execute('INSERT INTO annotations(revision_id,ordinal,class_id,x,y,width,height) VALUES(%s,0,0,1,1,10,10)',(result.json['revision'],))

def test_export_disconnect_marked_interrupted(env):
    client,data,meta,headers=prepare(env);revision=send(client,data,headers).json['revision'];approve(client,meta['id'],revision)
    version=client.post('/v1/projects/'+env[2]+'/versions',headers=AUTH).json['id']
    url=client.post('/v1/versions/'+version+'/link',headers=AUTH).json['url'].removeprefix('https://collector.example.com')
    response=client.get(url+'/archive',buffered=False)
    next(iter(response.response));response.close()
    with psycopg.connect(env[1]) as conn:
        assert conn.execute('SELECT status FROM export_jobs ORDER BY created_at DESC LIMIT 1').fetchone()[0]=='interrupted'

def test_login_and_expired_download_capability(env):
    client,data,meta,headers=prepare(env)
    assert client.post('/v1/login',json={'username':'operator','password':'wrong'}).status_code==401
    login=client.post('/v1/login',json={'username':'operator','password':'collector-test-password'})
    assert login.status_code==200
    assert client.get('/v1/health',headers={'Authorization':'Bearer '+login.json['token']}).status_code==200
    revision=send(client,data,headers).json['revision'];approve(client,meta['id'],revision)
    version=client.post('/v1/projects/'+env[2]+'/versions',headers=AUTH).json['id']
    assert client.post('/v1/versions/'+version+'/link',headers=OTHER).status_code==404
    url=client.post('/v1/versions/'+version+'/link',headers=AUTH).json['url'].removeprefix('https://collector.example.com')
    with psycopg.connect(env[1]) as conn:conn.execute("UPDATE download_tokens SET expires_at=now()-interval '1 second'")
    assert client.get(url).status_code==404

def polygon_sample(env):
    client,data,meta,headers=prepare(env)
    revision=send(client,data,headers).json['revision']
    polygon={'class_id':0,'x':20,'y':20,'width':80,'height':80,'points':[{'x':20,'y':20},{'x':100,'y':20},{'x':100,'y':100},{'x':20,'y':100}]}
    approve(client,meta['id'],revision,[polygon],False)
    return client,meta

def configure_drive(app):
    app.config.update(GOOGLE_OAUTH_CLIENT_ID='id',GOOGLE_OAUTH_CLIENT_SECRET='secret',
                       GOOGLE_OAUTH_REFRESH_TOKEN='refresh',GOOGLE_DRIVE_FOLDER_ID='folder')

class FakeDriveClient:
    def __init__(self,*args,**kwargs):
        pass
    def upload_zip(self,data,filename):
        return {'id':'fake-file-id','webViewLink':'https://drive.example/fake','size':len(data)}

class FailingDriveClient:
    def __init__(self,*args,**kwargs):
        pass
    def upload_zip(self,data,filename):
        raise DriveError('simulated Drive outage')

def test_archive_to_drive_frees_storage(env,monkeypatch):
    app,dsn,project,_,_=env
    configure_drive(app)
    monkeypatch.setattr(app_module,'DriveClient',FakeDriveClient)
    client,meta=polygon_sample(env)
    response=client.post('/v1/projects/'+project+'/archive',headers=AUTH)
    assert response.status_code==201
    assert response.json['samples']==1
    assert response.json['bytes_freed']>0
    assert response.json['drive_link']=='https://drive.example/fake'
    with psycopg.connect(dsn) as conn:
        row=conn.execute('SELECT image_bytes,archived_at FROM sample_images WHERE sample_id=%s',(meta['id'],)).fetchone()
        assert row[0] is None and row[1] is not None
        job_status=conn.execute('SELECT status FROM export_jobs ORDER BY created_at DESC LIMIT 1').fetchone()[0]
        assert job_status=='complete'
    with psycopg.connect(dsn) as conn:
        with pytest.raises(psycopg.Error):conn.execute('DELETE FROM sample_images WHERE sample_id=%s',(meta['id'],))
    with psycopg.connect(dsn) as conn:
        with pytest.raises(psycopg.Error):conn.execute("UPDATE sample_images SET archived_at=now() WHERE sample_id=%s",(meta['id'],))
    assert client.get('/v1/samples/'+meta['id']+'/image',headers=AUTH).status_code==410
    current_revision=client.get('/v1/samples/'+meta['id'],headers=AUTH).json['current_revision']
    assert client.put('/v1/samples/'+meta['id']+'/review',headers=AUTH,
        json={'expected_revision':current_revision,'status':'pending_review','explicit_negative':False,'annotations':[]}).status_code==400

def test_archive_to_drive_failure_leaves_bytes_untouched(env,monkeypatch):
    app,dsn,project,_,_=env
    configure_drive(app)
    monkeypatch.setattr(app_module,'DriveClient',FailingDriveClient)
    client,meta=polygon_sample(env)
    response=client.post('/v1/projects/'+project+'/archive',headers=AUTH)
    assert response.status_code==400
    with psycopg.connect(dsn) as conn:
        row=conn.execute('SELECT image_bytes,archived_at FROM sample_images WHERE sample_id=%s',(meta['id'],)).fetchone()
        assert row[0] is not None and row[1] is None
        job_status=conn.execute('SELECT status FROM export_jobs ORDER BY created_at DESC LIMIT 1').fetchone()[0]
        assert job_status=='failed'

def test_archive_to_drive_requires_configuration(env):
    client,meta=polygon_sample(env)
    response=client.post('/v1/projects/'+env[2]+'/archive',headers=AUTH)
    assert response.status_code==503

def test_archive_to_drive_batches_instead_of_erroring_when_more_remain(env,monkeypatch):
    # Regression test: more approved samples than MAX_ARCHIVE_SAMPLES must not
    # error - it should archive exactly one batch and leave the rest for the
    # next call (this previously 400'd with "exceeds the configured sample
    # limit", the same strict/non-strict mix-up freeze() correctly uses).
    app,dsn,project,_,_=env
    configure_drive(app)
    app.config['MAX_ARCHIVE_SAMPLES']=2
    monkeypatch.setattr(app_module,'DriveClient',FakeDriveClient)
    ids=[polygon_sample(env)[1]['id'] for _ in range(3)]
    client=app.test_client()
    response=client.post('/v1/projects/'+project+'/archive',headers=AUTH)
    assert response.status_code==201,response.json
    assert response.json['samples']==2
    with psycopg.connect(dsn) as conn:
        archived=conn.execute('SELECT sample_id FROM sample_images WHERE archived_at IS NOT NULL').fetchall()
        assert len(archived)==2
    # The remaining sample archives cleanly on a follow-up call.
    response=client.post('/v1/projects/'+project+'/archive',headers=AUTH)
    assert response.status_code==201,response.json
    assert response.json['samples']==1
    with psycopg.connect(dsn) as conn:
        remaining=conn.execute('SELECT count(*) FROM sample_images WHERE archived_at IS NULL').fetchone()[0]
        assert remaining==0
