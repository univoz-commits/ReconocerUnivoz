"""Normalizacion de referencia para reconocimiento de senas.

Esta es la implementacion CANONICA. La version de Dart debe producir
resultados identicos (tolerancia 1e-5) contra golden/golden_cases.json.

Entrada por frame:
  pose:  lista de 33 landmarks de MediaPipe Pose, cada uno (x, y, z, visibility)
  left:  lista de 21 landmarks de mano izquierda (x, y, z) o None
  right: lista de 21 landmarks de mano derecha (x, y, z) o None

Todas las coordenadas vienen normalizadas por MediaPipe al rango [0,1]
respecto al tamano de la imagen. Y crece hacia abajo.

Salida por frame: vector de 138 floats. Ver LAYOUT abajo.
"""

import math
import struct

NORM_VERSION = "1.0.0"
T_FRAMES = 32
FRAME_DIM = 138

# indices de MediaPipe Pose
L_SHOULDER, R_SHOULDER = 11, 12
POSE_BODY_IDX = [13, 14, 15, 16, 23, 24]  # codos, munecas, caderas
# pares izquierda/derecha dentro de POSE_BODY_IDX, para el espejeo
BODY_MIRROR_PAIRS = [(0, 1), (2, 3), (4, 5)]

# indices de MediaPipe Hand
HAND_WRIST, HAND_MIDDLE_MCP = 0, 9
N_HAND_PTS = 20  # 21 menos la muneca, que siempre queda en el origen

MIN_VISIBILITY = 0.5
EPS = 1e-6

# LAYOUT del vector de 138 dimensiones
OFF_BODY = 0        # 12 = 6 puntos x (x, y)
OFF_LOC_L = 12      # 2  = muneca izq en marco del cuerpo
OFF_LOC_R = 14      # 2  = muneca der en marco del cuerpo
OFF_PRES_L = 16     # 1  = 1.0 si la mano izq fue detectada
OFF_PRES_R = 17     # 1
OFF_SHAPE_L = 18    # 60 = 20 puntos x (x, y, z) relativos a la muneca
OFF_SHAPE_R = 78    # 60


def _rot(x, y, cos_t, sin_t):
    """Rota (x, y) por -theta, dado cos(theta) y sin(theta)."""
    return (x * cos_t + y * sin_t, -x * sin_t + y * cos_t)


def normalize_frame(pose, left=None, right=None, min_visibility=MIN_VISIBILITY):
    """Normaliza un frame. Devuelve lista de 138 floats, o None si el frame
    no es utilizable (hombros no visibles)."""
    if pose is None or len(pose) < 33:
        return None

    ls, rs = pose[L_SHOULDER], pose[R_SHOULDER]
    if len(ls) > 3 and (ls[3] < min_visibility or rs[3] < min_visibility):
        return None

    ox = (ls[0] + rs[0]) * 0.5
    oy = (ls[1] + rs[1]) * 0.5

    dx = rs[0] - ls[0]
    dy = rs[1] - ls[1]
    scale = math.sqrt(dx * dx + dy * dy)
    if scale < EPS:
        return None
    cos_t = dx / scale
    sin_t = dy / scale

    out = [0.0] * FRAME_DIM

    for i, idx in enumerate(POSE_BODY_IDX):
        p = pose[idx]
        rx, ry = _rot(p[0] - ox, p[1] - oy, cos_t, sin_t)
        out[OFF_BODY + i * 2] = rx / scale
        out[OFF_BODY + i * 2 + 1] = ry / scale

    for hand, off_loc, off_pres, off_shape in (
        (left, OFF_LOC_L, OFF_PRES_L, OFF_SHAPE_L),
        (right, OFF_LOC_R, OFF_PRES_R, OFF_SHAPE_R),
    ):
        if hand is None or len(hand) < 21:
            continue

        w = hand[HAND_WRIST]
        rx, ry = _rot(w[0] - ox, w[1] - oy, cos_t, sin_t)
        out[off_loc] = rx / scale
        out[off_loc + 1] = ry / scale
        out[off_pres] = 1.0

        m = hand[HAND_MIDDLE_MCP]
        hdx, hdy = m[0] - w[0], m[1] - w[1]
        hand_scale = math.sqrt(hdx * hdx + hdy * hdy)
        if hand_scale < EPS:
            hand_scale = scale * 0.25

        for j in range(1, 21):
            p = hand[j]
            qx, qy = _rot(p[0] - w[0], p[1] - w[1], cos_t, sin_t)
            k = off_shape + (j - 1) * 3
            out[k] = qx / hand_scale
            out[k + 1] = qy / hand_scale
            out[k + 2] = (p[2] - w[2]) / hand_scale

    return out


def fill_gaps(frames):
    """Sustituye frames None por el ultimo valido. Devuelve None si no hay
    ningun frame utilizable en toda la secuencia."""
    valid = [f for f in frames if f is not None]
    if not valid:
        return None
    out, last = [], valid[0]
    for f in frames:
        if f is not None:
            last = f
        out.append(last)
    return out


def resample(frames, t=T_FRAMES):
    """Remuestrea linealmente a t frames. Cada seña queda con la misma forma
    sin importar cuanto duro."""
    n = len(frames)
    if n == 0:
        return None
    if n == 1:
        return [list(frames[0]) for _ in range(t)]

    out = []
    for i in range(t):
        pos = i * (n - 1) / (t - 1)
        lo = int(math.floor(pos))
        hi = min(lo + 1, n - 1)
        w = pos - lo
        a, b = frames[lo], frames[hi]
        out.append([a[d] + (b[d] - a[d]) * w for d in range(FRAME_DIM)])
    return out


def normalize_sequence(raw_frames, t=T_FRAMES):
    """raw_frames: lista de tuplas (pose, left, right).
    Devuelve una matriz t x 138, o None si la toma no sirve."""
    norm = [normalize_frame(p, l, r) for (p, l, r) in raw_frames]
    filled = fill_gaps(norm)
    if filled is None:
        return None
    return resample(filled, t)


def mirror_frame(v):
    """Espejea un frame ya normalizado: invierte X y cruza izquierda/derecha.
    Sirve como augmentation para cubrir personas zurdas."""
    out = [0.0] * FRAME_DIM

    for a, b in BODY_MIRROR_PAIRS:
        out[OFF_BODY + a * 2] = -v[OFF_BODY + b * 2]
        out[OFF_BODY + a * 2 + 1] = v[OFF_BODY + b * 2 + 1]
        out[OFF_BODY + b * 2] = -v[OFF_BODY + a * 2]
        out[OFF_BODY + b * 2 + 1] = v[OFF_BODY + a * 2 + 1]

    out[OFF_LOC_L] = -v[OFF_LOC_R]
    out[OFF_LOC_L + 1] = v[OFF_LOC_R + 1]
    out[OFF_LOC_R] = -v[OFF_LOC_L]
    out[OFF_LOC_R + 1] = v[OFF_LOC_L + 1]

    out[OFF_PRES_L] = v[OFF_PRES_R]
    out[OFF_PRES_R] = v[OFF_PRES_L]

    for j in range(N_HAND_PTS):
        sl, sr = OFF_SHAPE_L + j * 3, OFF_SHAPE_R + j * 3
        out[sl], out[sl + 1], out[sl + 2] = -v[sr], v[sr + 1], v[sr + 2]
        out[sr], out[sr + 1], out[sr + 2] = -v[sl], v[sl + 1], v[sl + 2]

    return out


def mirror_sequence(seq):
    return [mirror_frame(f) for f in seq]


def pack_f16(seq):
    """Empaqueta t x 138 floats a bytes float16, para la columna BYTEA.
    Una seña de 32 frames pesa ~8.8 KB."""
    flat = [x for row in seq for x in row]
    return struct.pack("<%de" % len(flat), *flat)


def unpack_f16(blob, dim=FRAME_DIM):
    n = len(blob) // 2
    flat = struct.unpack("<%de" % n, blob)
    return [list(flat[i:i + dim]) for i in range(0, n, dim)]
