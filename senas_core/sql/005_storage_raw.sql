-- Storage privado opcional para sidecars de landmarks.
-- No crea permisos de lectura pública ni permisos de borrado.

INSERT INTO storage.buckets (id, name, public)
VALUES ('motion-raw', 'motion-raw', false)
ON CONFLICT (id) DO UPDATE SET public = false;

DROP POLICY IF EXISTS motion_raw_insert ON storage.objects;
CREATE POLICY motion_raw_insert ON storage.objects
    FOR INSERT TO anon, authenticated
    WITH CHECK (
        bucket_id = 'motion-raw'
        AND name LIKE 'raw/%.json.gz'
    );
