#!/usr/bin/env python3
"""Sube un video de una sena a la base de datos: extrae landmarks, los
normaliza igual que lo hace la app en vivo, y guarda tanto la muestra como
la secuencia normalizada (lista para el reconocedor DTW).

Uso basico:
    python ingest_video.py --video videos/casa_01.mp4 --gloss CASA --espanol casa

Con mas datos (recomendado para que el reconocimiento sea bueno):
    python ingest_video.py --video videos/casa_01.mp4 --gloss CASA --espanol casa \\
        --categoria hogar --manos 1 --signer maria --mano derecha

Si el video quedo espejeado (por ejemplo, grabado en modo "espejo" con la
camara frontal del celular, donde lo que se ve es como en un espejo):
    ... --espejo

Para subir una carpeta entera de una sola vez (una glosa por archivo, en vez
de llamar esto una vez por video) usa tools/ingest_carpeta.py -- comparte
toda la logica de este script, asi que un cambio aca aplica a los dos.

Requiere:
  - DATABASE_URL en tu .env (ver .env.example)
  - los modelos hand_landmarker.task y pose_landmarker_lite.task (por
    defecto busca los mismos que ya usa la app, en
    android/app/src/main/assets/)
"""

import argparse
import os
import sys
import uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import sign_norm as sn  # noqa: E402
import db  # noqa: E402
from dotenv import load_dotenv  # noqa: E402
from extraer_landmarks import ExtractorLandmarks  # noqa: E402
from storage import subir_video  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
ASSETS = os.path.join(HERE, "..", "android", "app", "src", "main", "assets")


def signer_uuid(nombre):
    """UUID estable a partir de un nombre, para no tener que llevar una
    tabla de usuarios aparte todavia. El mismo nombre siempre da el mismo
    id (respeta mayusculas/espacios de mas)."""
    return str(uuid.uuid5(uuid.NAMESPACE_DNS, "univoz-signer:" + nombre.strip().lower()))


def mano_opuesta(mano_dominante):
    if mano_dominante == "derecha":
        return "izquierda"
    if mano_dominante == "izquierda":
        return "derecha"
    return None


def ingest_un_video(
    conn,
    extractor,
    *,
    video_path,
    gloss,
    espanol,
    categoria=None,
    manos=1,
    es_estatica=False,
    usa_no_manuales=False,
    signer=None,
    mano_dominante=None,
    espejo=False,
    generar_espejo=False,
    aprobar=False,
):
    """El procesamiento real de un video: extraer, normalizar y guardar.

    Reusa un `extractor` (ExtractorLandmarks) y una `conn` ya abiertos --
    pensado para que tools/ingest_carpeta.py pueda subir muchos videos sin
    reabrir los modelos de MediaPipe en cada uno, que es lo que tarda. Este
    script (un solo video por corrida) tambien pasa por aca, para que las
    dos formas de subir nunca queden con reglas distintas.

    No hace conn.commit() ni conn.close(): esa decision es de quien llama.
    El CLI de un solo video comitea una vez al final; el de una carpeta
    comitea uno por archivo, para que un video que falla no tire abajo los
    que ya se subieron bien en la misma corrida.

    Levanta ValueError (con un mensaje pensado para mostrarse tal cual al
    usuario) si el video no tiene frames o nunca se le vieron los hombros.
    Devuelve un dict: sample_id, sample_id_espejo (o None), quality_score,
    n_frames, frames_invalidos, fps, video_uri, video_subido (bool), estado.
    """
    raw_frames, fps, n_frames = extractor.extraer(video_path)
    if n_frames == 0:
        raise ValueError("el video no tiene frames legibles.")

    if espejo:
        raw_frames = [(p, r, l) for (p, l, r) in raw_frames]

    # Normaliza frame por frame (igual que hace normalize_sequence), pero
    # por separado para poder reportar metricas de calidad reales antes de
    # guardar.
    norm = [sn.normalize_frame(p, l, r) for (p, l, r) in raw_frames]
    frames_invalidos = sum(1 for f in norm if f is None)

    visibilidades = []
    for (p, _l, _r) in raw_frames:
        if p is not None and len(p) > max(sn.L_SHOULDER, sn.R_SHOULDER):
            ls, rs = p[sn.L_SHOULDER], p[sn.R_SHOULDER]
            if len(ls) > 3 and len(rs) > 3:
                visibilidades.append(min(ls[3], rs[3]))
    visibilidad_min = min(visibilidades) if visibilidades else None

    filled = sn.fill_gaps(norm)
    if filled is None:
        raise ValueError(
            "el video no dio NINGUN frame utilizable (los hombros nunca se vieron). "
            "Revisa que la persona este de frente, con torso visible, y bien iluminada."
        )
    seq = sn.resample(filled, sn.T_FRAMES)
    packed = sn.pack_f16(seq)
    quality_score = 1.0 - (frames_invalidos / n_frames)

    # Sube el video original a Supabase Storage si esta configurado (ver
    # storage.py). Si no, video_uri queda como el nombre del archivo local.
    nombre_remoto = f"{gloss.strip().upper()}/{uuid.uuid4().hex}_{os.path.basename(video_path)}"
    video_uri = subir_video(video_path, nombre_remoto)
    video_subido = video_uri is not None
    if not video_subido:
        video_uri = os.path.basename(video_path)

    sign_id = db.upsert_sign(
        conn, gloss, espanol,
        categoria=categoria, manos=manos,
        es_estatica=es_estatica, usa_no_manuales=usa_no_manuales,
    )
    estado = "aprobada" if aprobar else "pendiente"
    sample_id = db.insertar_muestra(
        conn, sign_id,
        origen="video",
        video_uri=video_uri,
        fps=fps,
        duracion_ms=int(n_frames / fps * 1000) if fps else None,
        n_frames_orig=n_frames,
        frames_invalidos=frames_invalidos,
        visibilidad_min=visibilidad_min,
        quality_score=quality_score,
        signer_id=signer_uuid(signer) if signer else None,
        mano_dominante=mano_dominante,
        estado=estado,
    )
    db.insertar_landmarks(conn, sample_id, sn.NORM_VERSION, sn.T_FRAMES, sn.FRAME_DIM, packed)

    sample_id_espejo = None
    if generar_espejo:
        seq_espejo = sn.mirror_sequence(seq)
        packed_espejo = sn.pack_f16(seq_espejo)
        sample_id_espejo = db.insertar_muestra(
            conn, sign_id,
            origen="espejo",
            derivada_de=sample_id,
            video_uri=None,
            fps=fps,
            duracion_ms=int(n_frames / fps * 1000) if fps else None,
            n_frames_orig=n_frames,
            frames_invalidos=frames_invalidos,
            visibilidad_min=visibilidad_min,
            quality_score=quality_score,
            signer_id=signer_uuid(signer) if signer else None,
            mano_dominante=mano_opuesta(mano_dominante),
            estado=estado,
        )
        db.insertar_landmarks(conn, sample_id_espejo, sn.NORM_VERSION, sn.T_FRAMES, sn.FRAME_DIM, packed_espejo)

    return {
        "sample_id": sample_id,
        "sample_id_espejo": sample_id_espejo,
        "quality_score": quality_score,
        "n_frames": n_frames,
        "frames_invalidos": frames_invalidos,
        "fps": fps,
        "video_uri": video_uri,
        "video_subido": video_subido,
        "estado": estado,
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--video", required=True, help="ruta al archivo de video")
    ap.add_argument("--gloss", required=True, help="palabra/frase en glosa, ej. CASA (mayusculas)")
    ap.add_argument("--espanol", required=True, help="texto en espanol, ej. casa")
    ap.add_argument("--categoria", help="ej. saludos, familia, hogar")
    ap.add_argument("--manos", type=int, choices=[1, 2], default=1)
    ap.add_argument("--es-estatica", action="store_true", help="la sena no tiene movimiento (una sola postura)")
    ap.add_argument("--usa-no-manuales", action="store_true", help="usa expresion facial/cuerpo ademas de manos")
    ap.add_argument("--signer", help="tu nombre (o el de quien graba), para no mezclar la misma persona en train/test")
    ap.add_argument("--mano", choices=["izquierda", "derecha"], dest="mano_dominante")
    ap.add_argument(
        "--espejo", action="store_true",
        help="si el video quedo espejeado (modo selfie/espejo), cruza izquierda y derecha",
    )
    ap.add_argument(
        "--aprobar", action="store_true",
        help="marca la muestra como 'aprobada' de una. Si no, queda 'pendiente' para revisarla despues",
    )
    ap.add_argument(
        "--generar-espejo", action="store_true", dest="generar_espejo",
        help=(
            "ademas de guardar la muestra real, genera y guarda una segunda "
            "version espejada (invierte X y cruza mano izq/der) como augmentation "
            "-- cubre al reconocedor para el lado opuesto sin grabar de nuevo. "
            "No usar en senas donde izquierda/derecha es parte del significado."
        ),
    )
    ap.add_argument("--pose-model", default=os.path.join(ASSETS, "pose_landmarker_lite.task"))
    ap.add_argument("--hand-model", default=os.path.join(ASSETS, "hand_landmarker.task"))
    args = ap.parse_args()

    load_dotenv()

    if not os.path.exists(args.video):
        sys.exit(f"no existe el video: {args.video}")
    if not os.path.exists(args.pose_model):
        sys.exit(
            f"no encuentro el modelo de pose en {args.pose_model}\n"
            "Descargalo (ver CORRER.md del proyecto) o pasa --pose-model con la ruta correcta."
        )
    if not os.path.exists(args.hand_model):
        sys.exit(
            f"no encuentro el modelo de manos en {args.hand_model}\n"
            "Descargalo (ver CORRER.md del proyecto) o pasa --hand-model con la ruta correcta."
        )

    print(f"Extrayendo landmarks de {args.video} ...")
    extractor = ExtractorLandmarks(args.pose_model, args.hand_model)
    conn = db.conectar()
    try:
        try:
            r = ingest_un_video(
                conn, extractor,
                video_path=args.video, gloss=args.gloss, espanol=args.espanol,
                categoria=args.categoria, manos=args.manos,
                es_estatica=args.es_estatica, usa_no_manuales=args.usa_no_manuales,
                signer=args.signer, mano_dominante=args.mano_dominante,
                espejo=args.espejo, generar_espejo=args.generar_espejo,
                aprobar=args.aprobar,
            )
        except ValueError as e:
            sys.exit(str(e))

        print(f"  {r['n_frames']} frames leidos a {r['fps']:.1f} fps, {r['frames_invalidos']} sin hombros visibles")
        if r["video_subido"]:
            print(f"  video subido: {r['video_uri']}")
        else:
            print("  (Supabase Storage no configurado: se guarda solo el nombre del archivo)")

        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        extractor.cerrar()
        conn.close()

    estado = "aprobada" if args.aprobar else "pendiente (falta revisarla)"
    print()
    print(f"Listo: sena '{args.gloss}' ({args.espanol})")
    print(f"  muestra: {r['sample_id']}")
    print(f"  calidad: {r['quality_score']:.0%}  |  estado: {estado}")
    if r["sample_id_espejo"]:
        print(f"  + muestra espejada (augmentation): {r['sample_id_espejo']}  (no cuenta como persona real en v_cobertura)")


if __name__ == "__main__":
    main()
