#!/usr/bin/env python3
"""Importa a la base las muestras grabadas desde la app del telefono.

En la app: "Mis muestras" -> icono de compartir -> mandate el archivo a vos
misma (mail, WhatsApp, Drive), bajalo a la PC, y corre este script con la
ruta de ese archivo.

Uso:
    python tools/importar_muestras.py --archivo muestras_univoz_2026-08-15.json

Opciones utiles:
    --aprobar          las deja 'aprobada' de una, sin revision
    --generar-espejo   guarda ademas la version espejada de cada muestra
    --signer NOMBRE    sobreescribe el nombre que venga en el archivo
    --categoria CAT    categoria para las senas que se creen nuevas

Las muestras entran con origen='camara' (a diferencia de ingest_video.py,
que usa 'video'), asi que despues se pueden distinguir en la base.

Requiere DATABASE_URL en tu .env.
"""

import argparse
import json
import os
import sys
import uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import sign_norm as sn  # noqa: E402
import db  # noqa: E402
from dotenv import load_dotenv  # noqa: E402


# Duplicados a proposito de ingest_video.py: importarlos de ahi arrastraria
# mediapipe y opencv, que este script no necesita para nada. Tienen que dar
# el MISMO uuid que alla, o la misma persona contaria como dos en
# v_cobertura.
def signer_uuid(nombre):
    return str(uuid.uuid5(uuid.NAMESPACE_DNS, "univoz-signer:" + nombre.strip().lower()))


def mano_opuesta(mano_dominante):
    if mano_dominante == "derecha":
        return "izquierda"
    if mano_dominante == "izquierda":
        return "derecha"
    return None


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--archivo", required=True, help="el JSON exportado desde la app")
    ap.add_argument("--signer", help="sobreescribe el nombre de quien grabo")
    ap.add_argument("--categoria", help="categoria para las senas nuevas")
    ap.add_argument("--mano", choices=["izquierda", "derecha"], dest="mano_dominante")
    ap.add_argument("--aprobar", action="store_true")
    ap.add_argument("--generar-espejo", action="store_true", dest="generar_espejo")
    ap.add_argument(
        "--seco", action="store_true",
        help="muestra que se importaria pero no escribe nada en la base",
    )
    args = ap.parse_args()

    load_dotenv()

    if not os.path.exists(args.archivo):
        sys.exit(f"no existe el archivo: {args.archivo}")

    with open(args.archivo, encoding="utf-8") as f:
        paquete = json.load(f)

    norm_version = paquete.get("norm_version")
    if norm_version and norm_version != sn.NORM_VERSION:
        sys.exit(
            f"el archivo fue grabado con norm_version {norm_version} pero este "
            f"pipeline usa {sn.NORM_VERSION}. Los vectores no son comparables: "
            "actualiza la app o re-graba las muestras."
        )

    muestras = paquete.get("muestras") or []
    if not muestras:
        sys.exit("el archivo no tiene ninguna muestra.")

    # Chequeo de forma ANTES de tocar la base: un archivo truncado o de otra
    # version rompe el CHECK de sample_landmarks y aborta a mitad de camino.
    for i, m in enumerate(muestras):
        seq = m.get("seq") or []
        if len(seq) != sn.T_FRAMES or any(len(f) != sn.FRAME_DIM for f in seq):
            sys.exit(
                f"la muestra #{i} ({m.get('gloss')}) tiene forma invalida: "
                f"se esperaba {sn.T_FRAMES}x{sn.FRAME_DIM}."
            )

    por_glosa = {}
    for m in muestras:
        por_glosa[m["gloss"]] = por_glosa.get(m["gloss"], 0) + 1
    print(f"{len(muestras)} muestras, {len(por_glosa)} palabras:")
    for g, n in sorted(por_glosa.items(), key=lambda kv: -kv[1]):
        print(f"  {g:<24} {n}")

    if args.seco:
        print("\n(--seco: no se escribio nada en la base)")
        return

    estado = "aprobada" if args.aprobar else "pendiente"
    insertadas = 0
    espejadas = 0

    conn = db.conectar()
    try:
        for m in muestras:
            gloss = m["gloss"]
            espanol = m.get("espanol") or gloss.lower().replace("_", " ")
            signer = args.signer or m.get("signer")

            sign_id = db.upsert_sign(
                conn, gloss, espanol,
                categoria=args.categoria or m.get("categoria"),
            )

            seq = m["seq"]
            packed = sn.pack_f16(seq)
            sample_id = db.insertar_muestra(
                conn, sign_id,
                origen="camara",
                video_uri=None,
                fps=None,
                duracion_ms=None,
                n_frames_orig=m.get("n_frames_orig"),
                frames_invalidos=0,
                visibilidad_min=None,
                quality_score=None,
                signer_id=signer_uuid(signer) if signer else None,
                mano_dominante=args.mano_dominante,
                estado=estado,
            )
            db.insertar_landmarks(
                conn, sample_id, sn.NORM_VERSION, sn.T_FRAMES, sn.FRAME_DIM, packed)
            insertadas += 1

            if args.generar_espejo:
                seq_espejo = sn.mirror_sequence(seq)
                sample_id_espejo = db.insertar_muestra(
                    conn, sign_id,
                    origen="espejo",
                    derivada_de=sample_id,
                    video_uri=None,
                    fps=None,
                    duracion_ms=None,
                    n_frames_orig=m.get("n_frames_orig"),
                    frames_invalidos=0,
                    visibilidad_min=None,
                    quality_score=None,
                    signer_id=signer_uuid(signer) if signer else None,
                    mano_dominante=mano_opuesta(args.mano_dominante),
                    estado=estado,
                )
                db.insertar_landmarks(
                    conn, sample_id_espejo, sn.NORM_VERSION, sn.T_FRAMES,
                    sn.FRAME_DIM, sn.pack_f16(seq_espejo))
                espejadas += 1

        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()

    print()
    print(f"Listo: {insertadas} muestras importadas como '{estado}'"
          + (f" (+{espejadas} espejadas)" if espejadas else ""))
    if not args.aprobar:
        print("Quedaron pendientes. Para aprobarlas todas, en el SQL Editor de Supabase:")
        print("  UPDATE sign_samples SET estado='aprobada' WHERE estado='pendiente';")
    print("Despues corre 'python tools/exportar_paquete.py' para que entren al paquete de la app.")


if __name__ == "__main__":
    main()
