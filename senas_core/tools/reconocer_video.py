#!/usr/bin/env python3
"""Reconoce que sena aparece en un video nuevo, comparando (por DTW) contra
todas las muestras 'aprobada' que haya en la base de datos. No entrena
nada -- agregar una sena nueva es solo aprobar mas muestras con
ingest_video.py.

Uso:
    python reconocer_video.py --video videos/prueba.mp4

Requiere DATABASE_URL en tu .env y que haya al menos una muestra con
estado='aprobada' en la base (usa --aprobar en ingest_video.py, o aprueba
a mano con UPDATE sign_samples SET estado='aprobada' WHERE id=...).
"""

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import sign_norm as sn  # noqa: E402
import dtw as D  # noqa: E402
import db  # noqa: E402
from dotenv import load_dotenv  # noqa: E402
from extraer_landmarks import ExtractorLandmarks  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
ASSETS = os.path.join(HERE, "..", "android", "app", "src", "main", "assets")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--video", required=True)
    ap.add_argument("--espejo", action="store_true")
    ap.add_argument("--pose-model", default=os.path.join(ASSETS, "pose_landmarker_lite.task"))
    ap.add_argument("--hand-model", default=os.path.join(ASSETS, "hand_landmarker.task"))
    ap.add_argument("--max-distance", type=float, default=0.55, help="igual que DtwClassifier, ver README")
    ap.add_argument("--min-margin", type=float, default=0.12)
    ap.add_argument("--top", type=int, default=3, help="cuantas candidatas mostrar ademas de la ganadora")
    args = ap.parse_args()

    load_dotenv()

    print("Cargando plantillas aprobadas de la base de datos...")
    conn = db.conectar()
    try:
        filas = db.plantillas_aprobadas(conn, sn.NORM_VERSION)
    finally:
        conn.close()

    if not filas:
        sys.exit(
            "no hay ninguna muestra 'aprobada' todavia (norm_version="
            f"{sn.NORM_VERSION}). Sube senas con ingest_video.py --aprobar, "
            "o aprueba muestras pendientes a mano en la base."
        )

    clf = D.DtwClassifier(max_distance=args.max_distance, min_margin=args.min_margin)
    for sign_id, gloss, espanol, blob, t_frames, frame_dim in filas:
        seq = sn.unpack_f16(bytes(blob), dim=frame_dim)
        clf.add(sign_id, gloss, seq, espanol=espanol)
    n_senas = len(set(f[0] for f in filas))
    print(f"  {len(filas)} plantillas cargadas ({n_senas} senas distintas)")

    print(f"Extrayendo landmarks de {args.video} ...")
    extractor = ExtractorLandmarks(args.pose_model, args.hand_model)
    try:
        raw_frames, fps, n_frames = extractor.extraer(args.video)
    finally:
        extractor.cerrar()

    if args.espejo:
        raw_frames = [(p, r, l) for (p, l, r) in raw_frames]

    seq = sn.normalize_sequence(raw_frames, t=sn.T_FRAMES)
    if seq is None:
        sys.exit("no se pudo extraer una sena utilizable de ese video (revisa que se vea el torso).")

    ranking = clf.rank(seq)
    print()
    if not ranking:
        print("Sin ninguna candidata (nada paso el prefiltro/banda de DTW).")
        return

    pred = clf.classify(seq)
    if pred.aceptada:
        print(f"RECONOCIDA: {pred.gloss} ({pred.espanol})  "
              f"(distancia={pred.distance:.3f}, margen={pred.margin:.3f})")
    else:
        print("No reconocida con confianza suficiente.")
        print(f"  mejor candidata: {pred.gloss} ({pred.espanol})  "
              f"(distancia={pred.distance:.3f}, margen={pred.margin:.3f})")
        print(f"  umbrales: distancia <= {args.max_distance}  y  margen >= {args.min_margin}")

    if args.top > 0:
        vistos = set()
        print("\n  otras candidatas:")
        for d, t in ranking:
            if t.gloss in vistos:
                continue
            vistos.add(t.gloss)
            print(f"    {t.gloss:<20} distancia={d:.3f}")
            if len(vistos) > args.top:
                break


if __name__ == "__main__":
    main()