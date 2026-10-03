CREATE TABLE IF NOT EXISTS schema_migrations(version integer PRIMARY KEY);
CREATE TABLE projects(id uuid PRIMARY KEY, name text NOT NULL);
CREATE TABLE operators(id uuid PRIMARY KEY, username text UNIQUE NOT NULL, password_hash text NOT NULL);
CREATE TABLE project_members(project_id uuid REFERENCES projects, operator_id uuid REFERENCES operators, PRIMARY KEY(project_id,operator_id));
CREATE TABLE auth_sessions(token_hash text PRIMARY KEY, operator_id uuid REFERENCES operators NOT NULL, expires_at timestamptz NOT NULL, revoked boolean NOT NULL DEFAULT false);
CREATE TABLE login_attempts(key text PRIMARY KEY, attempts integer NOT NULL, expires_at timestamptz NOT NULL);
CREATE TABLE specimens(id uuid PRIMARY KEY, project_id uuid REFERENCES projects NOT NULL, name text NOT NULL, designation text CHECK(designation IN ('real','proxy')) NOT NULL, UNIQUE(project_id,name,designation));
CREATE TABLE capture_sessions(id uuid PRIMARY KEY, project_id uuid REFERENCES projects NOT NULL, specimen_id uuid REFERENCES specimens NOT NULL, name text NOT NULL, device text NOT NULL, scene_tags jsonb NOT NULL DEFAULT '[]', started_at timestamptz NOT NULL DEFAULT now(), ended_at timestamptz);
CREATE TABLE model_versions(hash text PRIMARY KEY CHECK(hash ~ '^[a-f0-9]{64}$'), metadata jsonb NOT NULL);
CREATE TABLE samples(id uuid PRIMARY KEY, project_id uuid REFERENCES projects NOT NULL, session_id uuid REFERENCES capture_sessions NOT NULL, captured_at timestamptz NOT NULL, request_hash text NOT NULL, current_revision uuid NOT NULL, deleted_at timestamptz, created_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE sample_images(sample_id uuid PRIMARY KEY REFERENCES samples, image_bytes bytea NOT NULL, mime_type text NOT NULL CHECK(mime_type='image/jpeg'), sha256 text NOT NULL CHECK(sha256 ~ '^[a-f0-9]{64}$'), width integer NOT NULL CHECK(width>0), height integer NOT NULL CHECK(height>0), byte_count integer NOT NULL CHECK(byte_count>0 AND octet_length(image_bytes)=byte_count));
CREATE TABLE prediction_runs(sample_id uuid PRIMARY KEY REFERENCES samples, model_hash text REFERENCES model_versions NOT NULL, proposals jsonb NOT NULL, settings jsonb NOT NULL);
CREATE TABLE annotation_revisions(id uuid PRIMARY KEY, sample_id uuid REFERENCES samples NOT NULL, reviewer_id uuid REFERENCES operators NOT NULL, status text NOT NULL CHECK(status IN ('pending_review','approved')), explicit_negative boolean NOT NULL, reviewed_at timestamptz, created_at timestamptz NOT NULL DEFAULT now(), created_txid bigint NOT NULL DEFAULT txid_current(), UNIQUE(id,sample_id), CHECK((status='approved')=(reviewed_at IS NOT NULL)));
ALTER TABLE samples ADD CONSTRAINT current_revision_sample FOREIGN KEY(current_revision,id) REFERENCES annotation_revisions(id,sample_id) DEFERRABLE INITIALLY DEFERRED;
CREATE TABLE annotations(revision_id uuid REFERENCES annotation_revisions NOT NULL, ordinal integer NOT NULL, class_id integer NOT NULL CHECK(class_id BETWEEN 0 AND 4), x double precision NOT NULL CHECK(x>=0 AND x<'Infinity'), y double precision NOT NULL CHECK(y>=0 AND y<'Infinity'), width double precision NOT NULL CHECK(width>0 AND width<'Infinity'), height double precision NOT NULL CHECK(height>0 AND height<'Infinity'), PRIMARY KEY(revision_id,ordinal));
CREATE TABLE dataset_versions(id uuid PRIMARY KEY, project_id uuid REFERENCES projects NOT NULL, created_at timestamptz NOT NULL DEFAULT now(), manifest jsonb NOT NULL, created_txid bigint NOT NULL DEFAULT txid_current());
CREATE TABLE dataset_version_samples(version_id uuid REFERENCES dataset_versions NOT NULL, sample_id uuid REFERENCES samples NOT NULL, revision_id uuid NOT NULL, image_hash text NOT NULL, capture_group uuid REFERENCES capture_sessions NOT NULL, split text NOT NULL DEFAULT 'unsplit' CHECK(split='unsplit'), PRIMARY KEY(version_id,sample_id), FOREIGN KEY(revision_id,sample_id) REFERENCES annotation_revisions(id,sample_id));
CREATE TABLE export_jobs(id uuid PRIMARY KEY, version_id uuid REFERENCES dataset_versions NOT NULL, status text NOT NULL CHECK(status IN ('ready','streaming','complete','failed','interrupted')), validation jsonb NOT NULL DEFAULT '{}', error text, created_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE download_tokens(token_hash text PRIMARY KEY, version_id uuid REFERENCES dataset_versions NOT NULL, operator_id uuid REFERENCES operators NOT NULL, expires_at timestamptz NOT NULL);
CREATE INDEX samples_project_order ON samples(project_id,created_at,id) WHERE deleted_at IS NULL;
CREATE INDEX revisions_sample ON annotation_revisions(sample_id);
CREATE INDEX sessions_project ON capture_sessions(project_id);
-- Immutable history protects retained dataset versions even after review edits.
CREATE FUNCTION reject_mutation() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'immutable dataset history'; END $$;
CREATE TRIGGER immutable_images BEFORE UPDATE OR DELETE ON sample_images FOR EACH ROW EXECUTE FUNCTION reject_mutation();
CREATE TRIGGER immutable_revisions BEFORE UPDATE OR DELETE ON annotation_revisions FOR EACH ROW EXECUTE FUNCTION reject_mutation();
CREATE TRIGGER immutable_annotations BEFORE UPDATE OR DELETE ON annotations FOR EACH ROW EXECUTE FUNCTION reject_mutation();
CREATE TRIGGER immutable_predictions BEFORE UPDATE OR DELETE ON prediction_runs FOR EACH ROW EXECUTE FUNCTION reject_mutation();
CREATE TRIGGER immutable_models BEFORE UPDATE OR DELETE ON model_versions FOR EACH ROW EXECUTE FUNCTION reject_mutation();
CREATE TRIGGER immutable_versions BEFORE UPDATE OR DELETE ON dataset_versions FOR EACH ROW EXECUTE FUNCTION reject_mutation();
CREATE TRIGGER immutable_membership BEFORE UPDATE OR DELETE ON dataset_version_samples FOR EACH ROW EXECUTE FUNCTION reject_mutation();
CREATE FUNCTION validate_annotation_bounds() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE iw integer; ih integer; revision_txid bigint;
BEGIN
 SELECT i.width,i.height,r.created_txid INTO iw,ih,revision_txid FROM sample_images i JOIN annotation_revisions r ON r.sample_id=i.sample_id WHERE r.id=NEW.revision_id;
 IF revision_txid<>txid_current() THEN RAISE EXCEPTION 'cannot append to immutable annotation revision'; END IF;
 IF iw IS NULL OR NEW.x+NEW.width>iw+0.000001 OR NEW.y+NEW.height>ih+0.000001 THEN RAISE EXCEPTION 'box outside image'; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER annotation_bounds BEFORE INSERT ON annotations FOR EACH ROW EXECUTE FUNCTION validate_annotation_bounds();
CREATE FUNCTION validate_frozen_membership() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM dataset_versions v JOIN samples s ON s.project_id=v.project_id
   JOIN sample_images i ON i.sample_id=s.id JOIN annotation_revisions r ON r.sample_id=s.id
   WHERE v.id=NEW.version_id AND v.created_txid=txid_current() AND s.id=NEW.sample_id
   AND r.id=NEW.revision_id AND r.status='approved' AND i.sha256=NEW.image_hash AND s.session_id=NEW.capture_group)
 THEN RAISE EXCEPTION 'invalid or immutable frozen membership'; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER frozen_membership BEFORE INSERT ON dataset_version_samples FOR EACH ROW EXECUTE FUNCTION validate_frozen_membership();
CREATE FUNCTION validate_review() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE n integer;
BEGIN
 SELECT count(*) INTO n FROM annotations WHERE revision_id=NEW.id;
 IF NEW.status='approved' AND ((n=0)<>NEW.explicit_negative) THEN RAISE EXCEPTION 'approval requires explicit empty negative or nonempty annotations'; END IF;
 RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER review_check AFTER INSERT ON annotation_revisions DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION validate_review();
INSERT INTO schema_migrations VALUES(1);
