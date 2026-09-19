-- Contrato canónico MotionSequenceV2.
-- Ejecutar después de 001_schema.sql y 002_app_acceso.sql.
-- No elimina ni convierte muestras antiguas: una versión incompatible se
-- excluye explícitamente del reconocimiento.

INSERT INTO norm_versions (version, frame_dim, t_frames, notas)
VALUES (
    '2.0.0', 152, 32,
    'pose mundial 3D, manos relativas a muñeca, float16 little-endian'
)
ON CONFLICT (version) DO UPDATE SET
    frame_dim = EXCLUDED.frame_dim,
    t_frames = EXCLUDED.t_frames,
    notas = EXCLUDED.notas;

ALTER TABLE sign_samples
    ADD COLUMN IF NOT EXISTS raw_landmarks_uri TEXT,
    ADD COLUMN IF NOT EXISTS raw_landmarks_format TEXT,
    ADD COLUMN IF NOT EXISTS checksum_sha256 TEXT;

ALTER TABLE sample_landmarks
    ADD COLUMN IF NOT EXISTS schema_version TEXT NOT NULL DEFAULT 'MotionSequenceV2';

CREATE INDEX IF NOT EXISTS sample_landmarks_norm_idx
    ON sample_landmarks (norm_version, frame_dim, t_frames);

-- La vista ya filtra por norm_version desde la app. Esta vista adicional deja
-- explícito que no se deben descargar formatos antiguos al teléfono.
CREATE OR REPLACE VIEW v_motion_v2_aprobadas
WITH (security_invoker = true) AS
SELECT ss.id AS sample_id,
       s.id AS sign_id,
       s.gloss,
       s.espanol,
       sl.norm_version,
       sl.t_frames,
       sl.frame_dim,
       sl.data,
       ss.fps,
       ss.duracion_ms,
       ss.n_frames_orig,
       ss.frames_invalidos,
       ss.quality_score,
       ss.checksum_sha256
FROM sign_samples ss
JOIN signs s ON s.id = ss.sign_id
JOIN sample_landmarks sl ON sl.sample_id = ss.id
WHERE ss.estado = 'aprobada'
  AND sl.norm_version = '2.0.0'
  AND sl.t_frames = 32
  AND sl.frame_dim = 152;

GRANT SELECT ON v_motion_v2_aprobadas TO anon, authenticated;
