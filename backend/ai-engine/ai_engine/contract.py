"""Validación del contrato MotionSequenceV2."""

import math
from typing import Iterable, List

NORM_VERSION = '2.0.0'
T_FRAMES = 32
FRAME_DIM = 152


class ContractError(ValueError):
    """Entrada incompatible con pipeline canónico."""


class MotionSequenceV2:
    """Secuencia inmutable validada: 32 frames por 152 valores."""

    def __init__(self, frames: Iterable[Iterable[float]],
                 *, norm_version: str = NORM_VERSION):
        if norm_version != NORM_VERSION:
            raise ContractError(
                f'norm_version incompatible: {norm_version}; '
                f'se esperaba {NORM_VERSION}'
            )

        rows: List[List[float]] = []
        for frame_index, frame in enumerate(frames):
            row = [float(value) for value in frame]
            if len(row) != FRAME_DIM:
                raise ContractError(
                    f'frame {frame_index} requiere {FRAME_DIM} dimensiones; '
                    f'recibió {len(row)}'
                )
            if not all(math.isfinite(value) for value in row):
                raise ContractError(f'frame {frame_index} contiene NaN o infinito')
            rows.append(row)

        if len(rows) != T_FRAMES:
            raise ContractError(
                f'MotionSequenceV2 requiere {T_FRAMES} frames; recibió {len(rows)}'
            )
        self.frames = tuple(tuple(row) for row in rows)
        self.norm_version = norm_version

    def to_json(self):
        return {
            'norm_version': self.norm_version,
            't_frames': T_FRAMES,
            'frame_dim': FRAME_DIM,
            'frames': [list(row) for row in self.frames],
        }
