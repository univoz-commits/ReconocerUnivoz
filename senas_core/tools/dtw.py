"""Reconocimiento de senas por Dynamic Time Warping sobre plantillas.

No entrena nada. Agregar una sena nueva es agregar plantillas, y funciona
con pocas muestras por sena. Es la fase 1: sirve para tener el sistema
completo de punta a punta antes de meter un encoder entrenado.

La distancia entre dos frames NO es euclidiana plana. Los 138 numeros no
valen lo mismo: la forma de la mano ocupa 120 dimensiones y la ubicacion
solo 4, asi que una euclidiana normal dejaria que la forma se comiera todo
el peso. Aqui cada bloque se promedia por su numero de dimensiones y luego
se pondera, para que la ubicacion pese lo que le corresponde.
"""

import math

from sign_norm import (
    FRAME_DIM, OFF_BODY, OFF_LOC_L, OFF_LOC_R,
    OFF_PRES_L, OFF_PRES_R, OFF_SHAPE_L, OFF_SHAPE_R,
)

N_BODY = 12
N_SHAPE = 60

# pesos por bloque
W_BODY = 0.5      # los brazos importan, pero menos que las manos
W_LOC = 1.5       # la ubicacion es parametro fonologico: pesa mas
W_PRES = 2.0      # usar una mano o dos distingue senas distintas
W_SHAPE = 1.0
SHAPE_PENALTY = 1.0   # castigo cuando una tiene la mano y la otra no

BAND = 4          # radio de la banda de Sakoe-Chiba, en frames

_HAND_BLOCKS = (
    (OFF_LOC_L, OFF_PRES_L, OFF_SHAPE_L),
    (OFF_LOC_R, OFF_PRES_R, OFF_SHAPE_R),
)


def frame_distance(a, b):
    """Distancia ponderada por bloques entre dos frames normalizados."""
    acc = 0.0

    s = 0.0
    for i in range(OFF_BODY, OFF_BODY + N_BODY):
        d = a[i] - b[i]
        s += d * d
    acc += W_BODY * s / N_BODY

    for off_loc, off_pres, off_shape in _HAND_BLOCKS:
        pa, pb = a[off_pres], b[off_pres]
        dp = pa - pb
        acc += W_PRES * dp * dp

        # el remuestreo puede dejar presencias fraccionarias cuando la mano
        # aparece a media sena, por eso el umbral en vez de comparar con 1.0
        ha, hb = pa >= 0.5, pb >= 0.5
        if ha and hb:
            d0 = a[off_loc] - b[off_loc]
            d1 = a[off_loc + 1] - b[off_loc + 1]
            acc += W_LOC * (d0 * d0 + d1 * d1) / 2.0
            s = 0.0
            for i in range(off_shape, off_shape + N_SHAPE):
                d = a[i] - b[i]
                s += d * d
            acc += W_SHAPE * s / N_SHAPE
        elif ha != hb:
            acc += W_SHAPE * SHAPE_PENALTY

    return math.sqrt(acc)


def dtw_distance(a, b, band=BAND, ceiling=None):
    """DTW con banda de Sakoe-Chiba, normalizado por la secuencia mas larga.

    band limita cuanto se puede deformar el tiempo. Sin banda, una sena lenta
    puede alinearse con cualquier cosa y todo se parece a todo.

    ceiling permite abandonar temprano: si toda la fila ya supera ese valor,
    esta plantilla no va a ganar y no vale la pena terminarla.
    """
    n, m = len(a), len(b)
    if n == 0 or m == 0:
        return float('inf')

    inf = float('inf')
    ratio = m / n
    prev = [inf] * (m + 1)
    prev[0] = 0.0

    for i in range(1, n + 1):
        center = (i - 1) * ratio
        lo = max(1, int(math.floor(center - band)) + 1)
        hi = min(m, int(math.ceil(center + band)) + 1)

        cur = [inf] * (m + 1)
        fila_min = inf
        for j in range(lo, hi + 1):
            best = prev[j - 1]
            if prev[j] < best:
                best = prev[j]
            if cur[j - 1] < best:
                best = cur[j - 1]
            if best == inf:
                continue
            cur[j] = best + frame_distance(a[i - 1], b[j - 1])
            if cur[j] < fila_min:
                fila_min = cur[j]

        if ceiling is not None and fila_min / max(n, m) > ceiling:
            return inf
        prev = cur

    d = prev[m]
    return d / max(n, m) if d != inf else inf


def signature(seq):
    """Vector promedio de la secuencia. Se usa como prefiltro barato:
    138 operaciones por plantilla en vez de los ~40 mil de un DTW completo."""
    n = len(seq)
    sig = [0.0] * FRAME_DIM
    for f in seq:
        for i in range(FRAME_DIM):
            sig[i] += f[i]
    return [x / n for x in sig]


class Template:
    __slots__ = ('sign_id', 'gloss', 'espanol', 'seq', 'sig')

    def __init__(self, sign_id, gloss, seq, espanol=''):
        self.sign_id = sign_id
        self.gloss = gloss
        self.espanol = espanol
        self.seq = seq
        self.sig = signature(seq)


class Prediction:
    def __init__(self, gloss, sign_id, espanol, distance, margin, aceptada):
        self.gloss = gloss
        self.sign_id = sign_id
        self.espanol = espanol
        self.distance = distance
        self.margin = margin
        self.aceptada = aceptada

    def __repr__(self):
        return ('Prediction(%s, d=%.4f, margen=%.3f, %s)'
                % (self.gloss, self.distance, self.margin,
                   'aceptada' if self.aceptada else 'rechazada'))


class DtwClassifier:
    """Plantillas en memoria. En la app estas se cargan del paquete que
    sincroniza PostgreSQL (ver v_paquete_prototipos)."""

    def __init__(self, max_distance=0.55, min_margin=0.12, prefilter=40, band=BAND):
        self.templates = []
        self.max_distance = max_distance
        self.min_margin = min_margin
        self.prefilter = prefilter
        self.band = band

    def add(self, sign_id, gloss, seq, espanol=''):
        self.templates.append(Template(sign_id, gloss, seq, espanol=espanol))

    def _candidatos(self, sig):
        if self.prefilter <= 0 or len(self.templates) <= self.prefilter:
            return self.templates
        puntuadas = [(frame_distance(sig, t.sig), t) for t in self.templates]
        puntuadas.sort(key=lambda x: x[0])
        return [t for _, t in puntuadas[:self.prefilter]]

    def rank(self, seq):
        """Todas las distancias, de menor a mayor."""
        cands = self._candidatos(signature(seq))
        out = []
        mejor = None
        for t in cands:
            d = dtw_distance(seq, t.seq, self.band,
                             ceiling=mejor * 1.5 if mejor is not None else None)
            if d == float('inf'):
                continue
            if mejor is None or d < mejor:
                mejor = d
            out.append((d, t))
        out.sort(key=lambda x: x[0])
        return out

    def classify(self, seq):
        r = self.rank(seq)
        if not r:
            return Prediction(None, None, None, float('inf'), 0.0, False)

        d1, t1 = r[0]
        d2 = next((d for d, t in r if t.gloss != t1.gloss), None)

        if d2 is None or d2 == 0:
            margin = 1.0
        else:
            margin = (d2 - d1) / d2

        aceptada = d1 <= self.max_distance and margin >= self.min_margin
        return Prediction(t1.gloss, t1.sign_id, t1.espanol, d1, margin, aceptada)
