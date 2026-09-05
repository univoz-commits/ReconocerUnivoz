#!/usr/bin/env python3
"""Exporta las plantillas 'aprobada' de la base a un JSON que la app de
Flutter carga como asset local (assets/plantillas.json), para reconocer en
el telefono sin necesitar red en tiempo real.

Correlo cada vez que apruebes muestras nuevas en Supabase, y despues volve a
compilar/correr la app (flutter run) para que tome el archivo actualizado --
Flutter empaqueta los assets en el momento de compilar, no los lee en vivo
del disco.

Uso basico (guarda en <raiz del proyecto>/assets/plantillas.json):
    python tools/exportar_paquete.py

Con otra ruta de salida:
    python tools/exportar_paquete.py --salida otra/ruta/plantillas.json

Requiere DATABASE_URL en tu .env y que haya al menos una muestra con
estado='aprobada' en la base.
"""

import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import sign_norm as sn  # noqa: E402
import db  # noqa: E402
from dotenv import load_dotenv  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_SALIDA = os.path.join(HERE, "..", "assets", "plantillas.json")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--salida", default=DEFAULT_SALIDA, help="ruta del JSON de salida")
    args = ap.parse_args()

    load_dotenv()

    print("Conectando a la base...")
    conn = db.conectar()
    try:
        filas = db.plantillas_aprobadas(conn, sn.NORM_VERSION)
    finally:
        conn.close()

    if not filas:
        sys.exit(
            "no hay ninguna muestra 'aprobada' todavia (norm_version="
            f"{sn.NORM_VERSION}). Aproba muestras primero -- ver INGESTA.md "
            "paso 7, o corre: UPDATE sign_samples SET estado='aprobada' "
            "WHERE estado='pendiente'; en el SQL Editor de Supabase."
        )

    plantillas = []
    glosas = set()
    for sign_id, gloss, espanol, blob, t_frames, frame_dim in filas:
        seq = sn.unpack_f16(bytes(blob), dim=frame_dim)
        plantillas.append(
            {
                "sign_id": str(sign_id),
                "gloss": gloss,
                # La app la usa para el texto por voz (voz.dart / TTS): sin
                # esto solo tendria la glosa (COMO_ESTAS) para leer en vez de
                # la palabra real (como estas).
                "espanol": espanol,
                "seq": [[round(float(x), 6) for x in frame] for frame in seq],
            }
        )
        glosas.add(gloss)

    paquete = {
        "norm_version": sn.NORM_VERSION,
        "t_frames": sn.T_FRAMES,
        "frame_dim": sn.FRAME_DIM,
        "n_plantillas": len(plantillas),
        "n_senas": len(glosas),
        "plantillas": plantillas,
    }

    salida = os.path.abspath(args.salida)
    os.makedirs(os.path.dirname(salida), exist_ok=True)
    with open(salida, "w", encoding="utf-8") as f:
        json.dump(paquete, f)

    tam_kb = os.path.getsize(salida) / 1024
    print(
        f"Listo: {len(plantillas)} plantillas ({len(glosas)} senas distintas) "
        f"-> {salida} ({tam_kb:.0f} KB)"
    )
    print("Ahora corre 'flutter pub get' y 'flutter run' (o reinicia la app) para que tome el archivo nuevo.")


if __name__ == "__main__":
    main()
