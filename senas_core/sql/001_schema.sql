-- Esquema base para el reconocimiento de senas.
-- Requiere PostgreSQL 14+ y la extension pgvector.
--
-- Este archivo es idempotente: se puede correr mas de una vez, incluso si
-- alguna tabla ya existia de antes con menos columnas (creada a mano desde
-- el dashboard, por ejemplo). Los ALTER TABLE ... ADD COLUMN IF NOT EXISTS
-- parchan lo que falte sin tocar lo que ya esta.

CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ---------------------------------------------------------------------------
-- Versionado del pipeline.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS norm_versions (
    version     TEXT PRIMARY KEY,
    frame_dim   INT  NOT NULL,
    t_frames    INT  NOT NULL,
    notas       TEXT,
    creado_en   TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE norm_versions ADD COLUMN IF NOT EXISTS frame_dim INT;
ALTER TABLE norm_versions ADD COLUMN IF NOT EXISTS t_frames  INT;
ALTER TABLE norm_versions ADD COLUMN IF NOT EXISTS notas     TEXT;
ALTER TABLE norm_versions ADD COLUMN IF NOT EXISTS creado_en TIMESTAMPTZ NOT NULL DEFAULT now();

CREATE TABLE IF NOT EXISTS model_versions (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    nombre          TEXT NOT NULL,
    tipo            TEXT NOT NULL CHECK (tipo IN ('dtw', 'encoder')),
    norm_version    TEXT NOT NULL REFERENCES norm_versions(version),
    embedding_dim   INT,
    checksum        TEXT,
    activo          BOOLEAN NOT NULL DEFAULT false,
    creado_en       TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE model_versions ADD COLUMN IF NOT EXISTS embedding_dim INT;
ALTER TABLE model_versions ADD COLUMN IF NOT EXISTS checksum      TEXT;
ALTER TABLE model_versions ADD COLUMN IF NOT EXISTS activo        BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE model_versions ADD COLUMN IF NOT EXISTS creado_en     TIMESTAMPTZ NOT NULL DEFAULT now();

CREATE UNIQUE INDEX IF NOT EXISTS model_versions_uno_activo
    ON model_versions ((activo)) WHERE activo;

-- ---------------------------------------------------------------------------
-- Lexico
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS signs (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    gloss           TEXT NOT NULL UNIQUE,
    espanol         TEXT NOT NULL
);
ALTER TABLE signs ADD COLUMN IF NOT EXISTS categoria       TEXT;
ALTER TABLE signs ADD COLUMN IF NOT EXISTS es_estatica     BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE signs ADD COLUMN IF NOT EXISTS manos           SMALLINT NOT NULL DEFAULT 1;
ALTER TABLE signs ADD COLUMN IF NOT EXISTS usa_no_manuales BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE signs ADD COLUMN IF NOT EXISTS variante_de     UUID REFERENCES signs(id);
ALTER TABLE signs ADD COLUMN IF NOT EXISTS notas           TEXT;
ALTER TABLE signs ADD COLUMN IF NOT EXISTS creado_en       TIMESTAMPTZ NOT NULL DEFAULT now();

DO $$ BEGIN
    ALTER TABLE signs ADD CONSTRAINT signs_manos_check CHECK (manos IN (1, 2));
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

CREATE INDEX IF NOT EXISTS signs_categoria_idx ON signs (categoria);

-- ---------------------------------------------------------------------------
-- Muestras
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS sign_samples (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    sign_id         UUID NOT NULL REFERENCES signs(id) ON DELETE CASCADE,
    origen          TEXT NOT NULL CHECK (origen IN ('camara', 'video', 'espejo'))
);
ALTER TABLE sign_samples ADD COLUMN IF NOT EXISTS derivada_de      UUID REFERENCES sign_samples(id) ON DELETE CASCADE;
ALTER TABLE sign_samples ADD COLUMN IF NOT EXISTS signer_id        UUID;
ALTER TABLE sign_samples ADD COLUMN IF NOT EXISTS mano_dominante   TEXT;
ALTER TABLE sign_samples ADD COLUMN IF NOT EXISTS fps              REAL;
ALTER TABLE sign_samples ADD COLUMN IF NOT EXISTS duracion_ms      INT;
ALTER TABLE sign_samples ADD COLUMN IF NOT EXISTS n_frames_orig    INT;
ALTER TABLE sign_samples ADD COLUMN IF NOT EXISTS frames_invalidos INT NOT NULL DEFAULT 0;
ALTER TABLE sign_samples ADD COLUMN IF NOT EXISTS visibilidad_min  REAL;
ALTER TABLE sign_samples ADD COLUMN IF NOT EXISTS quality_score    REAL;
ALTER TABLE sign_samples ADD COLUMN IF NOT EXISTS estado           TEXT NOT NULL DEFAULT 'pendiente';
ALTER TABLE sign_samples ADD COLUMN IF NOT EXISTS revisada_por     UUID;
ALTER TABLE sign_samples ADD COLUMN IF NOT EXISTS video_uri        TEXT;
ALTER TABLE sign_samples ADD COLUMN IF NOT EXISTS creado_en        TIMESTAMPTZ NOT NULL DEFAULT now();

DO $$ BEGIN
    ALTER TABLE sign_samples ADD CONSTRAINT sign_samples_mano_check
        CHECK (mano_dominante IN ('izquierda', 'derecha'));
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
    ALTER TABLE sign_samples ADD CONSTRAINT sign_samples_estado_check
        CHECK (estado IN ('pendiente', 'aprobada', 'rechazada'));
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
    ALTER TABLE sign_samples ADD CONSTRAINT derivada_coherente
        CHECK ((origen = 'espejo') = (derivada_de IS NOT NULL));
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

CREATE INDEX IF NOT EXISTS sign_samples_sign_idx   ON sign_samples (sign_id, estado);
CREATE INDEX IF NOT EXISTS sign_samples_signer_idx ON sign_samples (signer_id);

CREATE TABLE IF NOT EXISTS sample_landmarks (
    sample_id    UUID PRIMARY KEY REFERENCES sign_samples(id) ON DELETE CASCADE,
    norm_version TEXT NOT NULL REFERENCES norm_versions(version),
    t_frames     INT  NOT NULL,
    frame_dim    INT  NOT NULL,
    data         BYTEA NOT NULL
);

DO $$ BEGIN
    ALTER TABLE sample_landmarks ADD CONSTRAINT data_del_tamano_correcto
        CHECK (octet_length(data) = t_frames * frame_dim * 2);
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- ---------------------------------------------------------------------------
-- Embeddings y prototipos (fase 2)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS sample_embeddings (
    sample_id    UUID NOT NULL REFERENCES sign_samples(id) ON DELETE CASCADE,
    model_id     UUID NOT NULL REFERENCES model_versions(id) ON DELETE CASCADE,
    sign_id      UUID NOT NULL REFERENCES signs(id) ON DELETE CASCADE,
    vec          VECTOR(128) NOT NULL,
    PRIMARY KEY (sample_id, model_id)
);

CREATE INDEX IF NOT EXISTS sample_embeddings_vec_idx
    ON sample_embeddings USING hnsw (vec vector_cosine_ops);

CREATE TABLE IF NOT EXISTS sign_prototypes (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    sign_id      UUID NOT NULL REFERENCES signs(id) ON DELETE CASCADE,
    model_id     UUID NOT NULL REFERENCES model_versions(id) ON DELETE CASCADE,
    vec          VECTOR(128) NOT NULL,
    n_muestras   INT NOT NULL,
    radio        REAL,
    etiqueta     TEXT,
    actualizado  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS sign_prototypes_vec_idx
    ON sign_prototypes USING hnsw (vec vector_cosine_ops);
CREATE INDEX IF NOT EXISTS sign_prototypes_model_idx ON sign_prototypes (model_id, sign_id);

-- ---------------------------------------------------------------------------
-- Sincronizacion al telefono
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_paquete_prototipos AS
SELECT p.sign_id,
       s.gloss,
       s.espanol,
       s.es_estatica,
       p.vec,
       p.radio,
       p.etiqueta,
       p.model_id,
       p.actualizado
FROM sign_prototypes p
JOIN signs s ON s.id = p.sign_id
JOIN model_versions m ON m.id = p.model_id
WHERE m.activo;

CREATE OR REPLACE VIEW v_cobertura AS
SELECT s.id,
       s.gloss,
       count(*) FILTER (WHERE ss.estado = 'aprobada'
                          AND ss.origen <> 'espejo')            AS muestras_reales,
       count(DISTINCT ss.signer_id) FILTER (WHERE ss.estado = 'aprobada') AS personas,
       avg(ss.quality_score) FILTER (WHERE ss.estado = 'aprobada')        AS calidad_media
FROM signs s
LEFT JOIN sign_samples ss ON ss.sign_id = s.id
GROUP BY s.id, s.gloss;

INSERT INTO norm_versions (version, frame_dim, t_frames, notas)
VALUES ('1.0.0', 138, 32, 'origen en punto medio de hombros, escala por ancho de hombros, correccion de inclinacion')
ON CONFLICT (version) DO NOTHING;
