"""Genera golden/golden_cases.json a partir de la implementacion de Python.
Ese archivo es el contrato que la implementacion de Dart debe cumplir.

Correr desde la raiz del proyecto:  python3 python/gen_golden.py
"""

import json
import os
import random

import sign_norm as sn
import dtw as D

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "test", "golden", "golden_cases.json")


def make_pose(rng, cx, cy, w):
    """Cuerpo sintetico pero plausible: hombros separados w, resto colgando."""
    pose = []
    for i in range(33):
        pose.append([
            round(cx + rng.uniform(-0.3, 0.3), 6),
            round(cy + rng.uniform(-0.3, 0.3), 6),
            round(rng.uniform(-0.1, 0.1), 6),
            round(rng.uniform(0.7, 1.0), 6),
        ])
    pose[sn.L_SHOULDER] = [round(cx - w / 2, 6), round(cy, 6), 0.0, 0.99]
    pose[sn.R_SHOULDER] = [round(cx + w / 2, 6), round(cy + 0.02, 6), 0.0, 0.98]
    return pose


def make_hand(rng, cx, cy):
    hand = []
    for i in range(21):
        hand.append([
            round(cx + rng.uniform(-0.08, 0.08), 6),
            round(cy + rng.uniform(-0.08, 0.08), 6),
            round(rng.uniform(-0.03, 0.03), 6),
        ])
    hand[sn.HAND_WRIST] = [round(cx, 6), round(cy, 6), 0.0]
    hand[sn.HAND_MIDDLE_MCP] = [round(cx + 0.01, 6), round(cy - 0.06, 6), 0.0]
    return hand


def build_cases():
    rng = random.Random(7)
    cases = []

    # caso 1: las dos manos presentes en los 3 frames
    frames = []
    for k in range(3):
        frames.append({
            "pose": make_pose(rng, 0.5, 0.45 + 0.01 * k, 0.24),
            "left": make_hand(rng, 0.38, 0.60 - 0.03 * k),
            "right": make_hand(rng, 0.63, 0.58 - 0.02 * k),
        })
    cases.append({"name": "dos_manos", "frames": frames})

    # caso 2: mano izquierda ausente, cuerpo mas chico y descentrado
    frames = []
    for k in range(3):
        frames.append({
            "pose": make_pose(rng, 0.32, 0.55 + 0.02 * k, 0.15),
            "left": None,
            "right": make_hand(rng, 0.40, 0.66 - 0.04 * k),
        })
    cases.append({"name": "una_mano", "frames": frames})

    for c in cases:
        raw = [(f["pose"], f["left"], f["right"]) for f in c["frames"]]
        norm = [sn.normalize_frame(p, l, r) for (p, l, r) in raw]
        assert all(f is not None for f in norm), c["name"]
        c["expected_frames"] = norm
        c["expected_mirror_frame0"] = sn.mirror_frame(norm[0])
        c["expected_resample_5"] = sn.resample(norm, 5)

    # Expectativas del DTW, calculadas sobre los frames ya normalizados de
    # los casos de arriba. Asi el golden no crece: reutiliza los mismos datos.
    a = cases[0]["expected_frames"]
    b = cases[1]["expected_frames"]
    dtw_block = {
        "frame_distances": [[D.frame_distance(fa, fb) for fb in b] for fa in a],
        "dtw_a_a": D.dtw_distance(a, a),
        "dtw_a_b": D.dtw_distance(a, b),
        "dtw_b_a": D.dtw_distance(b, a),
        "signature_a": D.signature(a),
        "pesos": {
            "body": D.W_BODY, "loc": D.W_LOC,
            "pres": D.W_PRES, "shape": D.W_SHAPE,
            "shape_penalty": D.SHAPE_PENALTY, "band": D.BAND,
        },
    }

    return {
        "norm_version": sn.NORM_VERSION,
        "frame_dim": sn.FRAME_DIM,
        "tolerance": 1e-5,
        "cases": cases,
        "dtw": dtw_block,
    }


if __name__ == "__main__":
    data = build_cases()
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w") as f:
        json.dump(data, f, indent=1)
    print("escrito:", os.path.normpath(OUT))
    print("casos:", len(data["cases"]), "| dim:", data["frame_dim"])
