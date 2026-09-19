"""Tests del clasificador DTW.  Correr:  python3 tools/test_dtw.py

Se generan senas sinteticas: una "sena" es una trayectoria suave de
landmarks. Las plantillas son la misma trayectoria con ruido, y las consultas
llevan ruido distinto y otra duracion, para verificar que el DTW absorbe la
diferencia de velocidad.
"""

import math
import random
import sys

import sign_norm as sn
import dtw as D
import gen_golden as G

fallos = []


def check(cond, msg):
    if cond:
        print("  ok   ", msg)
    else:
        print("  FALLA", msg)
        fallos.append(msg)


def hacer_sena(semilla, n_frames, ruido=0.0, manos=2):
    """Trayectoria determinista por semilla, con ruido opcional."""
    rng = random.Random(semilla)
    fase = rng.uniform(0, 6.28)
    amp = rng.uniform(0.05, 0.12)
    dx = rng.uniform(-0.12, 0.12)
    dy = rng.uniform(-0.10, 0.10)
    forma = random.Random(semilla + 1000)
    dedos = [(forma.uniform(-0.07, 0.07), forma.uniform(-0.07, 0.07))
             for _ in range(21)]

    jitter = random.Random(semilla * 31 + int(ruido * 1e6))
    raw = []
    for k in range(n_frames):
        t = k / max(1, n_frames - 1)
        pose = G.make_pose(random.Random(7), 0.5, 0.45, 0.24)
        pose_mundo = G.make_pose_mundo(random.Random(17), 0.32, 0.10)
        ang = fase + t * 3.0

        def mano(base_x, base_y, signo):
            cx = base_x + dx * t + amp * math.cos(ang) * signo
            cy = base_y + dy * t + amp * math.sin(ang)
            h = []
            for i, (ox, oy) in enumerate(dedos):
                h.append([
                    cx + ox + jitter.gauss(0, ruido),
                    cy + oy + jitter.gauss(0, ruido),
                    jitter.gauss(0, ruido),
                ])
            h[sn.HAND_WRIST] = [cx, cy, 0.0]
            h[sn.HAND_MIDDLE_MCP] = [cx + 0.01, cy - 0.06, 0.0]
            return h

        izq = mano(0.38, 0.60, -1) if manos == 2 else None
        der = mano(0.63, 0.58, 1)
        raw.append((pose, pose_mundo, izq, der))

    return sn.normalize_sequence(raw)


def test_frame_distance():
    print("test_frame_distance")
    a = hacer_sena(1, 20)[0]
    check(D.frame_distance(a, a) == 0.0, "distancia de un frame consigo mismo es 0")

    b = list(a)
    b[sn.OFF_PRES_L] = 0.0
    d_pres = D.frame_distance(a, b)
    c = list(a)
    c[sn.OFF_SHAPE_L] += 0.01
    d_forma = D.frame_distance(a, c)
    check(d_pres > d_forma * 5,
          "perder una mano pesa mucho mas que mover un dedo (%.3f vs %.3f)"
          % (d_pres, d_forma))


def test_dtw_basico():
    print("test_dtw_basico")
    s = hacer_sena(2, 32)
    check(D.dtw_distance(s, s) == 0.0, "DTW de una secuencia consigo misma es 0")

    lenta = hacer_sena(2, 60)
    rapida = hacer_sena(2, 18)
    d_misma = D.dtw_distance(lenta, rapida)
    otra = hacer_sena(9, 32)
    d_otra = D.dtw_distance(lenta, otra)
    check(d_misma < d_otra,
          "la misma sena a otra velocidad se parece mas que una distinta (%.4f vs %.4f)"
          % (d_misma, d_otra))


def test_clasificacion():
    print("test_clasificacion")
    glosas = ["CASA", "AGUA", "GRACIAS", "HOLA", "COMER", "TRABAJO"]
    clf = D.DtwClassifier()
    for i, g in enumerate(glosas):
        for r in range(4):
            clf.add(i, g, hacer_sena(100 + i, 28 + r * 3, ruido=0.004))

    aciertos = 0
    for i, g in enumerate(glosas):
        for dur in (20, 32, 45):
            p = clf.classify(hacer_sena(100 + i, dur, ruido=0.006))
            if p.gloss == g and p.aceptada:
                aciertos += 1
    total = len(glosas) * 3
    check(aciertos == total, "clasifica %d/%d consultas conocidas" % (aciertos, total))


def test_rechazo():
    print("test_rechazo")
    clf = D.DtwClassifier()
    for i, g in enumerate(["CASA", "AGUA", "GRACIAS"]):
        for r in range(4):
            clf.add(i, g, hacer_sena(200 + i, 30, ruido=0.004))

    rechazadas = 0
    for s in range(900, 906):
        p = clf.classify(hacer_sena(s, 30, ruido=0.006))
        if not p.aceptada:
            rechazadas += 1
    check(rechazadas >= 5,
          "rechaza %d/6 senas que no estan en el lexico" % rechazadas)


def test_prefiltro():
    print("test_prefiltro")
    glosas = ["S%02d" % i for i in range(30)]
    completo = D.DtwClassifier(prefilter=0)
    filtrado = D.DtwClassifier(prefilter=8)
    for i, g in enumerate(glosas):
        for r in range(3):
            seq = hacer_sena(300 + i, 30, ruido=0.004)
            completo.add(i, g, seq)
            filtrado.add(i, g, seq)

    iguales = 0
    for i in range(10):
        q = hacer_sena(300 + i, 30, ruido=0.006)
        if completo.classify(q).gloss == filtrado.classify(q).gloss:
            iguales += 1
    check(iguales >= 9,
          "el prefiltro da el mismo resultado en %d/10 casos" % iguales)


def test_una_mano_vs_dos():
    print("test_una_mano_vs_dos")
    dos = hacer_sena(400, 30, manos=2)
    una = hacer_sena(400, 30, manos=1)
    d = D.dtw_distance(dos, una)
    check(d > 0.3,
          "la misma trayectoria con una o dos manos queda lejos (%.3f)" % d)


if __name__ == "__main__":
    test_frame_distance()
    test_dtw_basico()
    test_clasificacion()
    test_rechazo()
    test_prefiltro()
    test_una_mano_vs_dos()
    print()
    if fallos:
        print("FALLARON %d comprobaciones" % len(fallos))
        sys.exit(1)
    print("todo en orden")
