"""Tests de la normalizacion.  Correr:  python3 tools/test_norm.py

test_golden          -> la implementacion coincide con el archivo golden
test_invariancia     -> mover, alejar o inclinar a la persona no cambia el vector
test_espejo_doble    -> espejear dos veces devuelve el original
test_empaquetado     -> el round trip float16 conserva precision suficiente
"""

import json
import math
import os
import random
import sys

import sign_norm as sn
import gen_golden

HERE = os.path.dirname(os.path.abspath(__file__))
GOLDEN = os.path.join(HERE, "..", "test", "golden", "golden_cases.json")
TOL = 1e-5

fallos = []


def check(cond, msg):
    if cond:
        print("  ok   ", msg)
    else:
        print("  FALLA", msg)
        fallos.append(msg)


def max_diff(a, b):
    return max(abs(x - y) for x, y in zip(a, b))


def test_golden():
    print("test_golden")
    if not os.path.exists(GOLDEN):
        check(False, "falta golden_cases.json, corre gen_golden.py")
        return
    data = json.load(open(GOLDEN))
    check(data["norm_version"] == sn.NORM_VERSION,
          "version %s coincide" % data["norm_version"])
    for c in data["cases"]:
        raw = [(f["pose"], f["left"], f["right"]) for f in c["frames"]]
        got = [sn.normalize_frame(p, l, r) for (p, l, r) in raw]
        d = max(max_diff(g, e) for g, e in zip(got, c["expected_frames"]))
        check(d < TOL, "%s: frames (max diff %.2e)" % (c["name"], d))
        d = max_diff(sn.mirror_frame(got[0]), c["expected_mirror_frame0"])
        check(d < TOL, "%s: espejo (max diff %.2e)" % (c["name"], d))
        rs = sn.resample(got, 5)
        d = max(max_diff(g, e) for g, e in zip(rs, c["expected_resample_5"]))
        check(d < TOL, "%s: remuestreo (max diff %.2e)" % (c["name"], d))


def _transformar(pts, dx, dy, s, ang, cx=0.5, cy=0.5):
    ca, sa = math.cos(ang), math.sin(ang)
    out = []
    for p in pts:
        x, y = p[0] - cx, p[1] - cy
        x, y = x * ca - y * sa, x * sa + y * ca
        q = [x * s + cx + dx, y * s + cy + dy, p[2] * s]
        if len(p) > 3:
            q.append(p[3])
        out.append(q)
    return out


def test_invariancia():
    print("test_invariancia")
    rng = random.Random(11)
    pose = gen_golden.make_pose(rng, 0.5, 0.45, 0.24)
    left = gen_golden.make_hand(rng, 0.38, 0.60)
    right = gen_golden.make_hand(rng, 0.63, 0.58)
    base = sn.normalize_frame(pose, left, right)

    for nombre, (dx, dy, s, ang) in {
        "trasladado":  (0.15, -0.10, 1.0, 0.0),
        "mas lejos":   (0.0, 0.0, 0.55, 0.0),
        "mas cerca":   (0.0, 0.0, 1.7, 0.0),
        "inclinado":   (0.0, 0.0, 1.0, 0.35),
        "todo junto":  (-0.12, 0.08, 0.7, -0.25),
    }.items():
        p2 = _transformar(pose, dx, dy, s, ang)
        l2 = _transformar(left, dx, dy, s, ang)
        r2 = _transformar(right, dx, dy, s, ang)
        got = sn.normalize_frame(p2, l2, r2)
        d = max_diff(got, base)
        check(d < 1e-4, "%s produce el mismo vector (max diff %.2e)" % (nombre, d))


def test_espejo_doble():
    print("test_espejo_doble")
    rng = random.Random(3)
    pose = gen_golden.make_pose(rng, 0.5, 0.45, 0.24)
    left = gen_golden.make_hand(rng, 0.38, 0.60)
    right = gen_golden.make_hand(rng, 0.63, 0.58)
    v = sn.normalize_frame(pose, left, right)
    d = max_diff(sn.mirror_frame(sn.mirror_frame(v)), v)
    check(d < 1e-9, "doble espejo devuelve el original (max diff %.2e)" % d)

    solo_der = sn.normalize_frame(pose, None, right)
    esp = sn.mirror_frame(solo_der)
    check(esp[sn.OFF_PRES_L] == 1.0 and esp[sn.OFF_PRES_R] == 0.0,
          "el espejo cruza la presencia de manos")


def test_empaquetado():
    print("test_empaquetado")
    rng = random.Random(5)
    pose = gen_golden.make_pose(rng, 0.5, 0.45, 0.24)
    left = gen_golden.make_hand(rng, 0.38, 0.60)
    right = gen_golden.make_hand(rng, 0.63, 0.58)
    seq = sn.normalize_sequence([(pose, left, right)] * 4)
    blob = sn.pack_f16(seq)
    back = sn.unpack_f16(blob)
    d = max(max_diff(a, b) for a, b in zip(seq, back))
    check(len(seq) == sn.T_FRAMES, "la secuencia quedo en %d frames" % sn.T_FRAMES)
    check(d < 2e-3, "round trip float16 (max diff %.2e)" % d)
    print("       peso de una seña: %.1f KB" % (len(blob) / 1024))


if __name__ == "__main__":
    test_golden()
    test_invariancia()
    test_espejo_doble()
    test_empaquetado()
    print()
    if fallos:
        print("FALLARON %d comprobaciones" % len(fallos))
        sys.exit(1)
    print("todo en orden")
