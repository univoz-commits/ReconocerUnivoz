"""Lectura de sample_landmarks del esquema canónico de Supabase."""

import os
import struct
from collections import defaultdict

from .contract import FRAME_DIM, NORM_VERSION, T_FRAMES, ContractError, MotionSequenceV2


def decode_float16_sequence(blob: bytes, *, t_frames: int = T_FRAMES,
                            frame_dim: int = FRAME_DIM,
                            norm_version: str = NORM_VERSION) -> MotionSequenceV2:
    if norm_version != NORM_VERSION:
        raise ContractError(f'norm_version incompatible: {norm_version}')
    expected = t_frames * frame_dim * 2
    if t_frames != T_FRAMES or frame_dim != FRAME_DIM or len(blob) != expected:
        raise ContractError(
            f'BYTEA incompatible: {len(blob)} bytes; se esperaban {expected}'
        )
    values = struct.unpack('<%de' % (t_frames * frame_dim), blob)
    frames = [list(values[i:i + frame_dim])
              for i in range(0, len(values), frame_dim)]
    return MotionSequenceV2(frames, norm_version=norm_version)


def approved_sequences(conn):
    """Agrupa muestras aprobadas por glosa desde signs/sign_samples."""
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT s.id, s.gloss, s.espanol, sl.data, sl.t_frames,
                   sl.frame_dim, sl.norm_version
            FROM sign_samples ss
            JOIN signs s ON s.id = ss.sign_id
            JOIN sample_landmarks sl ON sl.sample_id = ss.id
            WHERE ss.estado = 'aprobada'
              AND sl.norm_version = %s
              AND sl.t_frames = %s
              AND sl.frame_dim = %s
            ORDER BY s.gloss, ss.creado_en
            """,
            (NORM_VERSION, T_FRAMES, FRAME_DIM),
        )
        grouped = defaultdict(list)
        metadata = {}
        for sign_id, gloss, espanol, blob, t_frames, frame_dim, version in cur.fetchall():
            sequence = decode_float16_sequence(
                bytes(blob), t_frames=t_frames, frame_dim=frame_dim,
                norm_version=version,
            )
            grouped[gloss].append(sequence)
            metadata[gloss] = {
                'sign_id': str(sign_id),
                'gloss': gloss,
                'espanol': espanol or '',
            }
        return dict(grouped), metadata


def connect_database():
    try:
        import psycopg2
    except ImportError as error:
        raise RuntimeError('Instala psycopg2-binary para leer Supabase') from error
    url = os.environ.get('DATABASE_URL')
    if not url:
        raise RuntimeError('Falta DATABASE_URL en entorno')
    return psycopg2.connect(url)
