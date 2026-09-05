-- Acceso directo desde la app de Flutter, con la clave PUBLISHABLE.
--
-- Corre esto UNA VEZ en el SQL Editor de Supabase, despues de 001_schema.sql.
--
-- Por que hace falta: hoy las tablas estan SIN row level security. En
-- Supabase eso significa que cualquiera con la clave publishable puede leer,
-- escribir Y BORRAR todo. Este archivo es lo que convierte esa situacion en
-- una segura: prende RLS y deja pasar solo lo que la app necesita.
--
-- Lo que queda permitido para la app (rol anon):
--   * leer el lexico y las muestras
--   * dar de alta senas nuevas
--   * subir muestras, pero SIEMPRE en estado 'pendiente'
-- Lo que queda prohibido:
--   * modificar o borrar cualquier cosa
--   * aprobar muestras (eso solo se puede desde el panel de Supabase o con
--     la clave secreta desde tu PC, que ignoran RLS)
--
-- O sea: alguien que extraiga la clave del APK, en el peor caso, puede
-- ensuciar la cola de pendientes. No puede tocar el diccionario aprobado.

-- Permisos de tabla. Supabase normalmente ya se los da al rol anon por
-- default privileges, pero dejarlo explicito evita un "permission denied"
-- imposible de diagnosticar si ese default no estaba puesto. Ojo: esto solo
-- abre la puerta; quien decide fila por fila son las politicas de abajo.
GRANT SELECT, INSERT ON signs            TO anon, authenticated;
GRANT SELECT, INSERT ON sign_samples     TO anon, authenticated;
GRANT SELECT, INSERT ON sample_landmarks TO anon, authenticated;

ALTER TABLE norm_versions      ENABLE ROW LEVEL SECURITY;
ALTER TABLE model_versions     ENABLE ROW LEVEL SECURITY;
ALTER TABLE signs              ENABLE ROW LEVEL SECURITY;
ALTER TABLE sign_samples       ENABLE ROW LEVEL SECURITY;
ALTER TABLE sample_landmarks   ENABLE ROW LEVEL SECURITY;
ALTER TABLE sample_embeddings  ENABLE ROW LEVEL SECURITY;
ALTER TABLE sign_prototypes    ENABLE ROW LEVEL SECURITY;

-- sample_embeddings, sign_prototypes, model_versions y norm_versions quedan
-- con RLS prendido y SIN ninguna politica: nadie los toca desde la app. Son
-- de la fase 2 y del versionado del pipeline.

-- --------------------------------------------------------------------------
-- Lexico: la app lo lee y puede agregar palabras nuevas.
-- --------------------------------------------------------------------------
DROP POLICY IF EXISTS signs_lectura ON signs;
CREATE POLICY signs_lectura ON signs
    FOR SELECT TO anon, authenticated
    USING (true);

DROP POLICY IF EXISTS signs_alta ON signs;
CREATE POLICY signs_alta ON signs
    FOR INSERT TO anon, authenticated
    WITH CHECK (true);

-- --------------------------------------------------------------------------
-- Muestras: alta solo como 'pendiente'. El WITH CHECK es la parte
-- importante: aunque alguien arme el pedido a mano, no puede insertar una
-- muestra ya aprobada y meterse en el diccionario sin revision.
-- --------------------------------------------------------------------------
DROP POLICY IF EXISTS samples_lectura ON sign_samples;
CREATE POLICY samples_lectura ON sign_samples
    FOR SELECT TO anon, authenticated
    USING (true);

DROP POLICY IF EXISTS samples_alta ON sign_samples;
CREATE POLICY samples_alta ON sign_samples
    FOR INSERT TO anon, authenticated
    WITH CHECK (estado = 'pendiente');

DROP POLICY IF EXISTS landmarks_lectura ON sample_landmarks;
CREATE POLICY landmarks_lectura ON sample_landmarks
    FOR SELECT TO anon, authenticated
    USING (true);

DROP POLICY IF EXISTS landmarks_alta ON sample_landmarks;
CREATE POLICY landmarks_alta ON sample_landmarks
    FOR INSERT TO anon, authenticated
    WITH CHECK (true);

-- No hay ninguna politica de UPDATE ni de DELETE a proposito: con RLS
-- prendido, lo que no tiene politica esta prohibido.

-- --------------------------------------------------------------------------
-- Lo que la app se descarga para reconocer: una fila por plantilla aprobada,
-- ya lista para el DTW. Aplanarlo en una vista evita que el telefono tenga
-- que armar joins por HTTP.
--
-- security_invoker: la vista respeta las politicas de arriba en vez de
-- saltearlas. Con las politicas de SELECT que ya pusimos alcanza.
-- --------------------------------------------------------------------------
DROP VIEW IF EXISTS v_dtw_aprobadas;
CREATE VIEW v_dtw_aprobadas
WITH (security_invoker = true) AS
SELECT ss.id            AS sample_id,
       s.id             AS sign_id,
       s.gloss,
       s.espanol,
       sl.norm_version,
       sl.t_frames,
       sl.frame_dim,
       sl.data
FROM sign_samples ss
JOIN signs s            ON s.id = ss.sign_id
JOIN sample_landmarks sl ON sl.sample_id = ss.id
WHERE ss.estado = 'aprobada';

GRANT SELECT ON v_dtw_aprobadas TO anon, authenticated;

-- Comprobacion rapida: deberia devolver una fila por plantilla aprobada.
-- SELECT gloss, count(*) FROM v_dtw_aprobadas GROUP BY gloss ORDER BY 1;
