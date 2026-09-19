"""Conexion a Postgres (Supabase) y las operaciones que usan
ingest_video.py y reconocer_video.py.

Requiere DATABASE_URL en el entorno (ver .env.example en la raiz del
paquete). Nunca pongas la connection string ni el service key en el codigo
ni los subas a git -- van solo en tu .env local, que esta en .gitignore.
"""

import os

import psycopg2


def conectar():
    url = os.environ.get("DATABASE_URL")
    if not url:
        raise RuntimeError(
            "Falta DATABASE_URL en el entorno. Copia .env.example a .env "
            "(en la raiz de senas_core) y pega ahi la connection string de "
            "Supabase: Settings -> Database -> Connection string -> URI."
        )
    return psycopg2.connect(url)


def upsert_sign(
    conn,
    gloss,
    espanol,
    categoria=None,
    manos=1,
    es_estatica=False,
    usa_no_manuales=False,
):
    """Crea la sena si no existe (por glosa); si ya existe, actualiza el
    texto en espanol y devuelve el mismo id de siempre."""
    gloss = gloss.strip().upper()
    with conn.cursor() as cur:
        cur.execute(
            """
            INSERT INTO signs (gloss, espanol, categoria, manos, es_estatica, usa_no_manuales)
            VALUES (%s, %s, %s, %s, %s, %s)
            ON CONFLICT (gloss) DO UPDATE SET espanol = EXCLUDED.espanol
            RETURNING id
            """,
            (gloss, espanol, categoria, manos, es_estatica, usa_no_manuales),
        )
        return cur.fetchone()[0]


def insertar_muestra(
    conn,
    sign_id,
    *,
    origen,
    video_uri,
    fps,
    duracion_ms,
    n_frames_orig,
    frames_invalidos,
    visibilidad_min,
    quality_score,
    signer_id=None,
    mano_dominante=None,
    estado="pendiente",
    derivada_de=None,
    raw_landmarks_uri=None,
    raw_landmarks_format=None,
    checksum_sha256=None,
):
    with conn.cursor() as cur:
        cur.execute(
            """
            INSERT INTO sign_samples
              (sign_id, origen, derivada_de, signer_id, mano_dominante, fps, duracion_ms,
               n_frames_orig, frames_invalidos, visibilidad_min, quality_score,
              estado, video_uri, raw_landmarks_uri, raw_landmarks_format,
              checksum_sha256)
            VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)
            RETURNING id
            """,
            (
                sign_id, origen, derivada_de, signer_id, mano_dominante, fps, duracion_ms,
                n_frames_orig, frames_invalidos, visibilidad_min, quality_score,
                estado, video_uri, raw_landmarks_uri, raw_landmarks_format,
                checksum_sha256,
            ),
        )
        return cur.fetchone()[0]


def insertar_landmarks(conn, sample_id, norm_version, t_frames, frame_dim, data):
    with conn.cursor() as cur:
        cur.execute(
            """
            INSERT INTO sample_landmarks (sample_id, norm_version, t_frames, frame_dim, data)
            VALUES (%s,%s,%s,%s,%s)
            """,
            (sample_id, norm_version, t_frames, frame_dim, psycopg2.Binary(data)),
        )


def plantillas_aprobadas(conn, norm_version):
    """Todas las muestras con estado='aprobada' para esa version de
    normalizacion. Devuelve tuplas (sign_id, gloss, espanol, data, t_frames,
    frame_dim) listas para pasarle a dtw.DtwClassifier.add(...) despues de
    unpack_f16. El espanol viaja junto a la glosa para que quien reconozca
    (la app o reconocer_video.py) pueda decir la palabra en voz alta en vez
    de leer el codigo interno de la sena."""
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT s.id, s.gloss, s.espanol, sl.data, sl.t_frames, sl.frame_dim
            FROM sign_samples ss
            JOIN signs s ON s.id = ss.sign_id
            JOIN sample_landmarks sl ON sl.sample_id = ss.id
            WHERE ss.estado = 'aprobada' AND sl.norm_version = %s
            """,
            (norm_version,),
        )
        return cur.fetchall()


def muestras_pendientes(conn):
    """Para revisar antes de aprobar: lista (id, gloss, video_uri, creado_en)."""
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT ss.id, s.gloss, ss.video_uri, ss.creado_en
            FROM sign_samples ss
            JOIN signs s ON s.id = ss.sign_id
            WHERE ss.estado = 'pendiente'
            ORDER BY ss.creado_en
            """
        )
        return cur.fetchall()
