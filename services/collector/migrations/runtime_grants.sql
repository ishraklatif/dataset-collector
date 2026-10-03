-- Run as migration owner after creating a dedicated collector_app LOGIN role.
-- Set its password privately in Neon; never write it into this script.
GRANT CONNECT ON DATABASE neondb TO collector_app;
GRANT USAGE ON SCHEMA public TO collector_app;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO collector_app;
GRANT INSERT ON auth_sessions, login_attempts, specimens, capture_sessions, model_versions,
    samples, sample_images, prediction_runs, annotation_revisions, annotations,
    dataset_versions, dataset_version_samples, export_jobs, download_tokens TO collector_app;
GRANT SELECT,INSERT ON annotation_polygons TO collector_app;
GRANT UPDATE(attempts,expires_at) ON login_attempts TO collector_app;
GRANT UPDATE(revoked) ON auth_sessions TO collector_app;
GRANT UPDATE(name) ON specimens TO collector_app;
GRANT UPDATE(current_revision,deleted_at) ON samples TO collector_app;
GRANT UPDATE(status,error,validation) ON export_jobs TO collector_app;
GRANT UPDATE(image_bytes,archived_at) ON sample_images TO collector_app;
-- No DDL, revision mutation, operator creation, membership changes, or hard deletion;
-- image bytes may only be nulled via the Google Drive archival path (migration 003).
