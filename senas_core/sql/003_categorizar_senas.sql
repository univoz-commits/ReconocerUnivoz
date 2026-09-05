-- Poner categoria a las senas que ya estan en la base (columna `signs.categoria`,
-- TEXT libre, ya existe desde 001_schema.sql -- solo faltaba llenarla).
--
-- Correr en el SQL Editor de Supabase. No lo pude correr yo directo: esta
-- sesion no tiene salida de red hacia tu Postgres (ni siquiera instalando
-- un driver), asi que este es un script para que lo revises y lo corras vos.
--
-- Paso 1: mira que hay ahora mismo (¿son estas 10 las unicas señas, o hay
-- mas que no vi porque solo conozco los .mp4 de tu carpeta videos/ y las
-- 30 palabras de videos/palabras_sm.xlsx?).
SELECT gloss, espanol, categoria
FROM signs
ORDER BY categoria NULLS FIRST, gloss;

-- Paso 2: las que coinciden exacto con una fila de tu propio
-- videos/palabras_sm.xlsx (misma categoria que ya usa tu equipo ahi) --
-- alta confianza, deberian estar bien tal cual.
UPDATE signs SET categoria = 'Saludos y Cortesía' WHERE gloss = 'HOLA'    AND categoria IS NULL;
UPDATE signs SET categoria = 'Saludos y Cortesía' WHERE gloss = 'GRACIAS' AND categoria IS NULL;
UPDATE signs SET categoria = 'Acciones / Verbos'   WHERE gloss = 'AYUDAR' AND categoria IS NULL;
UPDATE signs SET categoria = 'Preguntas e Interacción' WHERE gloss = 'COMO_ESTAS' AND categoria IS NULL;

-- Paso 3: ADIOS -- ojo, tu Excel tiene la fila "Adiós / Hasta luego", que en
-- glosa da ADIOS_HASTA_LUEGO (con el "/" convertido en guion bajo), NO
-- "ADIOS" a secas -- por eso ingest_carpeta.py --excel no la habria
-- enganchado sola. Le pongo la misma categoria de todos modos; si preferis
-- que la glosa tambien diga ADIOS_HASTA_LUEGO avisame y armo el UPDATE del
-- nombre (no rompe nada: sign_samples apunta por id, no por texto de gloss).
UPDATE signs SET categoria = 'Saludos y Cortesía' WHERE gloss = 'ADIOS' AND categoria IS NULL;

-- Paso 4: estas NO estan en tu lista de 30 palabras -- categoria propuesta
-- mia, no de un dato que ya tuvieras. Revisalas antes de correr (o
-- cambia el texto de categoria por el que prefieras).
UPDATE signs SET categoria = 'Acciones / Verbos'    WHERE gloss = 'AYUDA'              AND categoria IS NULL;  -- junto con AYUDAR
UPDATE signs SET categoria = 'Acciones / Verbos'    WHERE gloss = 'ME_AYUDAS_UN_POCO'  AND categoria IS NULL;  -- frase de la familia de AYUDAR
UPDATE signs SET categoria = 'Respuestas BÁSICAS'   WHERE gloss = 'BIEN'               AND categoria IS NULL;  -- respuesta tipica a COMO_ESTAS
UPDATE signs SET categoria = 'Respuestas BÁSICAS'   WHERE gloss = 'NO_PUEDO'           AND categoria IS NULL;  -- junto con SI/NO de tu Excel
UPDATE signs SET categoria = 'Respuestas BÁSICAS'   WHERE gloss = 'SI_PUEDO'           AND categoria IS NULL;

-- Paso 5: confirmar -- no deberia quedar ninguna NULL salvo que haya senas
-- que no conociamos (revisalas a mano si aparecen).
SELECT gloss, espanol, categoria FROM signs WHERE categoria IS NULL ORDER BY gloss;
