"""Normalizacion de referencia para reconocimiento de senas.

Esta es la implementacion CANONICA. La version de Dart debe producir
resultados identicos (tolerancia 1e-5) contra golden/golden_cases.json.

Entrada por frame:
  pose:      lista de 33 landmarks de MediaPipe Pose en coordenadas de imagen,
             cada uno (x, y, z, visibility)
  pose_mundo:lista de 33 landmarks METRICOS (worldLandmarks), cada uno
             (x, y, z) en metros, con origen en el punto medio de las caderas
  left:      lista de 21 landmarks de mano izquierda (x, y, z) o None
  right:     lista de 21 landmarks de mano derecha (x, y, z) o None

Las coordenadas de imagen vienen normalizadas por MediaPipe al rango [0,1]
respecto al tamano de la imagen. Y crece hacia abajo.

Salida por frame: vector de 152 floats. Ver LAYOUT abajo.

VERSION 2.0.0: el cuerpo pasa de 2D a 3D, calculado desde el esqueleto
METRICO y no desde las coordenadas de imagen.

Se intento primero usar la Z de los landmarks de imagen, y no sirve: sus
valores son incoherentes entre puntos vecinos. Medido en una captura real, un
antebrazo de 0.8 anchos de hombro daba 3.5 de recorrido en Z, y las caderas
quedaban dos anchos de hombro detras de los hombros. MediaPipe la documenta
como profundidad relativa aproximada y no da para reconstruir una postura.
Los mismos segmentos medidos con worldLandmarks dieron 0.73, 0.65, 0.67 y
0.83: coherentes entre si y con la anatomia.

El bloque de cuerpo ya no son coordenadas de imagen rotadas, sino
proyecciones sobre una base ortonormal sacada del propio esqueleto:
  +X  hacia la derecha de la persona (hombro izq -> hombro der)
  +Y  hacia arriba (caderas -> hombros, ortogonalizado)
  +Z  hacia el frente de la persona
todo dividido por la distancia entre hombros. Eso lo hace invariante a donde
este la persona, a que tan lejos, y a hacia donde este girada.
"""

import math
import struct

NORM_VERSION = "2.0.0"
T_FRAMES = 32
FRAME_DIM = 152

# indices de MediaPipe Pose
L_SHOULDER, R_SHOULDER = 11, 12
L_HIP, R_HIP = 23, 24
L_WRIST, R_WRIST = 15, 16
# hombros, codos, munecas, caderas
POSE_BODY_IDX = [11, 12, 13, 14, 15, 16, 23, 24]
# pares izquierda/derecha dentro de POSE_BODY_IDX, para el espejeo
BODY_MIRROR_PAIRS = [(0, 1), (2, 3), (4, 5), (6, 7)]

# indices de MediaPipe Hand
HAND_WRIST, HAND_MIDDLE_MCP = 0, 9
N_HAND_PTS = 20  # 21 menos la muneca, que siempre queda en el origen

MIN_VISIBILITY = 0.5
EPS = 1e-6

# LAYOUT del vector de 152 dimensiones
OFF_BODY = 0        # 24 = 8 puntos x (x, y, z)
OFF_LOC_L = 24      # 3  = muneca izq en marco del cuerpo
OFF_LOC_R = 27      # 3  = muneca der en marco del cuerpo
OFF_PRES_L = 30     # 1  = 1.0 si la mano izq fue detectada
OFF_PRES_R = 31     # 1
OFF_SHAPE_L = 32    # 60 = 20 puntos x (x, y, z) relativos a la muneca
OFF_SHAPE_R = 92    # 60

# Dimensiones que llevan profundidad del CUERPO. El clasificador las ignora
# (ver BODY_DIST_DIMS en dtw.py): aunque worldLandmarks es mucho mejor que la
# Z de imagen, sigue siendo una estimacion y al comparar aporta menos que lo
# que ensucia. La Z de la FORMA de las manos si se usa.
Z_BODY_DIMS = ([OFF_BODY + i * 3 + 2 for i in range(len(POSE_BODY_IDX))]
               + [OFF_LOC_L + 2, OFF_LOC_R + 2])


def _pto(a, b):
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]


def _resta(a, b):
    return [a[0] - b[0], a[1] - b[1], a[2] - b[2]]


def _cruz(a, b):
    return [a[1] * b[2] - a[2] * b[1],
            a[2] * b[0] - a[0] * b[2],
            a[0] * b[1] - a[1] * b[0]]


def _largo(a):
    return math.sqrt(_pto(a, a))


def _unitario(a):
    m = _largo(a)
    if m < EPS:
        return None
    return [a[0] / m, a[1] / m, a[2] / m]


def _base_cuerpo(w):
    """Base ortonormal sacada del esqueleto metrico.

    Devuelve (der, arr, fre, origen, escala) o None si esta degenerado."""
    hi, hd = w[L_SHOULDER], w[R_SHOULDER]
    ci, cd = w[L_HIP], w[R_HIP]

    der = _unitario(_resta(hd, hi))
    if der is None:
        return None
    escala = _largo(_resta(hd, hi))

    origen = [(hi[i] + hd[i]) * 0.5 for i in range(3)]
    centro_caderas = [(ci[i] + cd[i]) * 0.5 for i in range(3)]

    # Arriba = caderas -> hombros, ortogonalizado contra la linea de hombros
    # (Gram-Schmidt) para que la base sea ortonormal aunque la persona este
    # inclinada de lado.
    tronco = _resta(origen, centro_caderas)
    proy = _pto(tronco, der)
    arr = _unitario([tronco[i] - der[i] * proy for i in range(3)])
    if arr is None:
        return None

    # Frente = arriba x derecha. Con los ejes de MediaPipe (X a la derecha de
    # la imagen, Y hacia abajo, Z creciendo al alejarse de la camara) este
    # producto apunta hacia el pecho de la persona.
    fre = _unitario(_cruz(arr, der))
    if fre is None:
        return None

    return (der, arr, fre, origen, escala)


def _proyectar(base, p):
    der, arr, fre, origen, escala = base
    q = _resta(p, origen)
    return [_pto(q, der) / escala, _pto(q, arr) / escala, _pto(q, fre) / escala]


def _rot(x, y, cos_t, sin_t):
    """Rota (x, y) por -theta, dado cos(theta) y sin(theta)."""
    return (x * cos_t + y * sin_t, -x * sin_t + y * cos_t)


def normalize_frame(pose, pose_mundo=None, left=None, right=None,
                    min_visibility=MIN_VISIBILITY):
    """Normaliza un frame. Devuelve lista de 152 floats, o None si el frame
    no es utilizable (hombros no visibles, o sin esqueleto metrico)."""
    if pose is None or len(pose) < 33:
        return None
    if pose_mundo is None or len(pose_mundo) < 33:
        return None

    ls, rs = pose[L_SHOULDER], pose[R_SHOULDER]
    if len(ls) < 4 or len(rs) < 4:
        return None
    if ls[3] < min_visibility or rs[3] < min_visibility:
        return None

    for idx in POSE_BODY_IDX:
        if (len(pose_mundo[idx]) < 3 or
                not all(math.isfinite(v) for v in pose_mundo[idx][:3])):
            return None

    base = _base_cuerpo(pose_mundo)
    if base is None:
        return None

    # Marco 2D de imagen: se sigue usando para la FORMA de las manos, que solo
    # existe en coordenadas de imagen. Alinea la linea de hombros con la
    # horizontal para que inclinar el cuerpo no cambie la forma detectada.
    dx = rs[0] - ls[0]
    dy = rs[1] - ls[1]
    escala_img = math.sqrt(dx * dx + dy * dy)
    if escala_img < EPS:
        return None
    cos_t = dx / escala_img
    sin_t = dy / escala_img

    out = [0.0] * FRAME_DIM

    for i, idx in enumerate(POSE_BODY_IDX):
        q = _proyectar(base, pose_mundo[idx])
        out[OFF_BODY + i * 3] = q[0]
        out[OFF_BODY + i * 3 + 1] = q[1]
        out[OFF_BODY + i * 3 + 2] = q[2]

    for hand, off_loc, off_pres, off_shape, idx_muneca in (
        (left, OFF_LOC_L, OFF_PRES_L, OFF_SHAPE_L, L_WRIST),
        (right, OFF_LOC_R, OFF_PRES_R, OFF_SHAPE_R, R_WRIST),
    ):
        if hand is None or len(hand) < 21:
            continue

        # Ubicacion: la muneca del modelo de POSE, no la del detector de
        # manos, para que quede en el mismo espacio metrico que el cuerpo.
        # Son practicamente el mismo punto anatomico.
        q = _proyectar(base, pose_mundo[idx_muneca])
        out[off_loc] = q[0]
        out[off_loc + 1] = q[1]
        out[off_loc + 2] = q[2]
        out[off_pres] = 1.0

        # La FORMA si viene del detector de manos: relativa a su propia
        # muneca y escalada por el tamano de la mano, asi que no depende de
        # donde este el brazo.
        w = hand[HAND_WRIST]
        m = hand[HAND_MIDDLE_MCP]
        hdx, hdy = m[0] - w[0], m[1] - w[1]
        hand_scale = math.sqrt(hdx * hdx + hdy * hdy)
        if hand_scale < EPS:
            hand_scale = escala_img * 0.25

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
    """raw_frames: lista de tuplas (pose, pose_mundo, left, right).
    Devuelve una matriz t x 152, o None si la toma no sirve."""
    norm = [normalize_frame(p, pm, l, r) for (p, pm, l, r) in raw_frames]
    filled = fill_gaps(norm)
    if filled is None:
        return None
    return resample(filled, t)


def mirror_frame(v):
    """Espejea un frame ya normalizado: invierte X y cruza izquierda/derecha.
    Sirve como augmentation para cubrir personas zurdas.

    La Z no se toca: espejear a alguien de lado a lado no cambia que tan
    cerca esta de la camara."""
    out = [0.0] * FRAME_DIM

    for a, b in BODY_MIRROR_PAIRS:
        for (src, dst) in ((b, a), (a, b)):
            out[OFF_BODY + dst * 3] = -v[OFF_BODY + src * 3]
            out[OFF_BODY + dst * 3 + 1] = v[OFF_BODY + src * 3 + 1]
            out[OFF_BODY + dst * 3 + 2] = v[OFF_BODY + src * 3 + 2]

    out[OFF_LOC_L] = -v[OFF_LOC_R]
    out[OFF_LOC_L + 1] = v[OFF_LOC_R + 1]
    out[OFF_LOC_L + 2] = v[OFF_LOC_R + 2]
    out[OFF_LOC_R] = -v[OFF_LOC_L]
    out[OFF_LOC_R + 1] = v[OFF_LOC_L + 1]
    out[OFF_LOC_R + 2] = v[OFF_LOC_L + 2]

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
    """Empaqueta t x 152 floats a bytes float16, para la columna BYTEA.
    Una seña de 32 frames pesa ~8.8 KB."""
    flat = [x for row in seq for x in row]
    return struct.pack("<%de" % len(flat), *flat)


def unpack_f16(blob, dim=FRAME_DIM):
    n = len(blob) // 2
    flat = struct.unpack("<%de" % n, blob)
    return [list(flat[i:i + dim]) for i in range(0, n, dim)]
