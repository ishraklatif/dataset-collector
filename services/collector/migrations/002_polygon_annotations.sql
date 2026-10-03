-- Store segmentation geometry separately so older API instances can keep
-- writing the unchanged rectangle annotations table during deployment.
CREATE TABLE annotation_polygons(
    revision_id uuid NOT NULL,
    ordinal integer NOT NULL,
    points jsonb NOT NULL CHECK (
        CASE WHEN jsonb_typeof(points)='array' THEN jsonb_array_length(points) BETWEEN 3 AND 256 ELSE false END
    ),
    PRIMARY KEY(revision_id,ordinal),
    FOREIGN KEY(revision_id,ordinal) REFERENCES annotations(revision_id,ordinal)
);
CREATE TRIGGER immutable_annotation_polygons BEFORE UPDATE OR DELETE ON annotation_polygons FOR EACH ROW EXECUTE FUNCTION reject_mutation();
CREATE FUNCTION validate_annotation_polygon() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE iw integer; ih integer; revision_txid bigint; vertex jsonb; px double precision; py double precision;
BEGIN
 SELECT i.width,i.height,r.created_txid INTO iw,ih,revision_txid
 FROM sample_images i JOIN annotation_revisions r ON r.sample_id=i.sample_id WHERE r.id=NEW.revision_id;
 IF revision_txid<>txid_current() THEN RAISE EXCEPTION 'cannot append to immutable annotation revision'; END IF;
 FOR vertex IN SELECT value FROM jsonb_array_elements(NEW.points) LOOP
   IF jsonb_typeof(vertex)<>'object' OR jsonb_typeof(vertex->'x')<>'number' OR jsonb_typeof(vertex->'y')<>'number' THEN
     RAISE EXCEPTION 'invalid polygon point';
   END IF;
   px=(vertex->>'x')::double precision; py=(vertex->>'y')::double precision;
   IF px<0 OR py<0 OR px>iw OR py>ih THEN RAISE EXCEPTION 'polygon point outside image'; END IF;
 END LOOP;
 RETURN NEW;
END $$;
CREATE TRIGGER annotation_polygon_bounds BEFORE INSERT ON annotation_polygons FOR EACH ROW EXECUTE FUNCTION validate_annotation_polygon();
DO $$ BEGIN
    IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname='collector_app') THEN
        GRANT SELECT,INSERT ON annotation_polygons TO collector_app;
    END IF;
END $$;
INSERT INTO schema_migrations(version) VALUES(2);
