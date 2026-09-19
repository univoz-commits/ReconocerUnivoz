"""Motor IA mínimo de ReconocerUnivoz.

Solo consume MotionSequenceV2 (32 x 152). No contiene frontend ni esquema
alternativo de base de datos.
"""

from .contract import FRAME_DIM, NORM_VERSION, T_FRAMES, MotionSequenceV2

__all__ = ['FRAME_DIM', 'NORM_VERSION', 'T_FRAMES', 'MotionSequenceV2']
