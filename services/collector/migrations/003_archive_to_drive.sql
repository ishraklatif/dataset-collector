-- Allow exactly one narrowly-scoped mutation: archiving a sample's image
-- bytes to external cold storage (Google Drive) after a verified upload, to
-- keep the Neon database under its storage cap. No other UPDATE/DELETE on
-- sample_images is permitted, and an already-archived row can never be
-- touched again.
ALTER TABLE sample_images ALTER COLUMN image_bytes DROP NOT NULL;
ALTER TABLE sample_images ADD COLUMN archived_at timestamptz;

DO $$
DECLARE old_name text;
BEGIN
  SELECT conname INTO old_name FROM pg_constraint
    WHERE conrelid = 'sample_images'::regclass AND contype = 'c'
      AND pg_get_constraintdef(oid) LIKE '%octet_length(image_bytes)%';
  IF old_name IS NOT NULL THEN
    EXECUTE format('ALTER TABLE sample_images DROP CONSTRAINT %I', old_name);
  END IF;
END $$;

ALTER TABLE sample_images ADD CONSTRAINT sample_images_archival_check CHECK (
  byte_count > 0
  AND (archived_at IS NULL) = (image_bytes IS NOT NULL)
  AND (image_bytes IS NULL OR octet_length(image_bytes) = byte_count)
);

DROP TRIGGER immutable_images ON sample_images;

CREATE FUNCTION reject_image_mutation() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'immutable dataset history';
  END IF;
  IF OLD.archived_at IS NOT NULL THEN
    RAISE EXCEPTION 'immutable dataset history';
  END IF;
  IF NEW.archived_at IS NOT NULL
     AND NEW.image_bytes IS NULL
     AND NEW.sample_id  IS NOT DISTINCT FROM OLD.sample_id
     AND NEW.mime_type  IS NOT DISTINCT FROM OLD.mime_type
     AND NEW.sha256     IS NOT DISTINCT FROM OLD.sha256
     AND NEW.width      IS NOT DISTINCT FROM OLD.width
     AND NEW.height     IS NOT DISTINCT FROM OLD.height
     AND NEW.byte_count IS NOT DISTINCT FROM OLD.byte_count
  THEN
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'immutable dataset history';
END $$;

CREATE TRIGGER immutable_images BEFORE UPDATE OR DELETE ON sample_images
  FOR EACH ROW EXECUTE FUNCTION reject_image_mutation();

DO $$ BEGIN
    IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname='collector_app') THEN
        GRANT UPDATE(image_bytes,archived_at) ON sample_images TO collector_app;
    END IF;
END $$;

INSERT INTO schema_migrations(version) VALUES(3);
