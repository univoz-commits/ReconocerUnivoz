#!/usr/bin/env python3
"""Sube TODOS los videos de una carpeta de una sola vez: extrae landmarks,
normaliza y guarda cada uno en la base -- lo mismo que hace ingest_video.py,
pero sin tener que llamarlo un video a la vez. Comparte toda la logica de
extraccion/normalizacion/guardado con ingest_video.py (ingest_un_video), asi
que un cambio en como se sube un video aplica a los dos por igual.

La glosa de cada video sale de su propio nombre de archivo, con la misma
conversion que usa la app (aGlosa en lib/muestras_locales.dart / a_glosa en
tools/glosa.py): sin acentos, en mayusculas, espacios y guiones bajos se
normalizan igual. Podes nombrar los archivos como quieras -- "como estas.mp4",
"COMO_ESTAS.mp4", "Cómo Estás.mov" -- las tres terminan siendo la seña
COMO_ESTAS.

Varias tomas de la misma sena: si el nombre termina en un numero de toma
("hola_01.mp4", "hola (2).mp4", "hola-3.mp4"), ese numero se saca antes de
armar la glosa, asi las tres quedan como HOLA en vez de tres senas distintas.
Ojo: esto NO aplica si el nombre entero es un numero (por ejemplo "5.mp4"
para la sena del numero 5 en NUMEROS) -- ahi el numero ES la sena, no una
repeticion, y se deja tal cual.

Uso basico:
    python tools/ingest_carpeta.py --carpeta videos/

Con mas contexto (recomendado -- mismos flags que ingest_video.py, se
aplican a TODOS los videos de la carpeta por igual):
    python tools/ingest_carpeta.py --carpeta videos/ --signer maria --mano derecha

Si tenes un Excel con la lista de palabras -- como videos/palabras_sm.xlsx,
con una columna de palabra en español y opcionalmente una de categoria --
pasalo con --excel para que el texto en español (con acentos y todo) y la
categoria salgan de ahi en vez de improvisarse a partir del nombre del
archivo. Si un video no matchea ninguna fila del Excel, se usa el nombre del
archivo "humanizado" (guiones bajos -> espacios) como texto en español:
    python tools/ingest_carpeta.py --carpeta videos/ --excel videos/palabras_sm.xlsx

Antes de subir nada de verdad, revisa con --seco que a cada archivo le vaya
a asignar la glosa/palabra/categoria correcta -- no toca la base ni corre
MediaPipe, solo imprime el plan:
    python tools/ingest_carpeta.py --carpeta videos/ --excel videos/palabras_sm.xlsx --seco

Un video que falla (sin torso visible, formato no soportado) no aborta el
resto de la carpeta -- queda anotado en el resumen final y sigue con el
siguiente.
"""

import argparse
import csv
import glob
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import db  # noqa: E402
from dotenv import load_dotenv  # noqa: E402
from extraer_landmarks import ExtractorLandmarks  # noqa: E402
from glosa import a_glosa  # noqa: E402
from ingest_video import ingest_un_video  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
ASSETS = os.path.join(HERE, "..", "android", "app", "src", "main", "assets")

EXTENSIONES_DEFAULT = {".mp4", ".mov", ".avi", ".mkv", ".webm"}


def base_sin_toma(nombre):
    """Saca un numero de toma al final del nombre ("hola_01" -> "hola",
    "hola (2)" -> "hola", "hola-3" -> "hola"), pero NO si el nombre entero
    es ese numero: "5" se queda "5" -- es la sena del numero 5, no una
    repeticion de otra cosa."""
    m = re.match(r"^(.*?)[\s_-]*\(?(\d+)\)?$", nombre)
    if m and m.group(1).strip(" _-"):
        return m.group(1)
    return nombre


def humanizar(gloss):
    return gloss.lower().replace("_", " ")


def leer_excel(ruta):
    """{glosa: (espanol, categoria)} a partir de un Excel con una columna
    de palabra en español (busca 'palabra'/'seña'/'sena' en el encabezado)
    y, si existe, una de categoria ('categor'). No asume que el encabezado
    este en la fila 1 -- plantillas como palabras_sm.xlsx traen un titulo
    arriba, asi que se busca la fila que de verdad tiene esos encabezados."""
    try:
        import openpyxl
    except ImportError:
        sys.exit("para usar --excel hace falta el paquete openpyxl: pip install openpyxl")

    wb = openpyxl.load_workbook(ruta, data_only=True)
    ws = wb.active
    filas = list(ws.iter_rows(values_only=True))

    col_palabra = col_categoria = fila_encabezado = None
    for i, fila in enumerate(filas):
        # Una fila de titulo/subtitulo (como "Listado de las 30 Palabras
        # Mas Usadas en LSM") normalmente tiene UN solo texto, ocupando
        # visualmente varias columnas combinadas -- pero un encabezado de
        # verdad tiene varias columnas de texto una al lado de la otra
        # ("#", "Palabra / Seña", "Categoria", ...). Si la fila no tiene al
        # menos 2 celdas de texto, no puede ser el encabezado real, aunque
        # una de sus palabras contenga "palabra" o "seña".
        con_texto = sum(1 for c in fila if isinstance(c, str) and c.strip())
        if con_texto < 2:
            continue
        for j, celda in enumerate(fila):
            if not isinstance(celda, str):
                continue
            baja = celda.lower()
            if any(p in baja for p in ("palabra", "seña", "sena")):
                col_palabra, fila_encabezado = j, i
            elif "categor" in baja:
                col_categoria = j
        if col_palabra is not None:
            break

    if col_palabra is None:
        sys.exit(f"no encontre una columna con 'palabra'/'seña' en el encabezado de {ruta}.")

    mapa = {}
    for fila in filas[fila_encabezado + 1:]:
        if col_palabra >= len(fila):
            continue
        texto = fila[col_palabra]
        if not texto or not isinstance(texto, str):
            continue
        categoria = None
        if col_categoria is not None and col_categoria < len(fila):
            valor = fila[col_categoria]
            categoria = valor.strip() if isinstance(valor, str) else None
        gloss = a_glosa(texto)
        if gloss:
            mapa[gloss] = (texto.strip(), categoria)
    return mapa


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--carpeta", required=True, help="carpeta con los videos a subir")
    ap.add_argument("--excel", help="Excel con la lista de palabras (columna 'palabra'/'seña' y opcional 'categoria')")
    ap.add_argument("--categoria", help="categoria por defecto si un video no matchea el Excel")
    ap.add_argument("--manos", type=int, choices=[1, 2], default=1)
    ap.add_argument("--es-estatica", action="store_true", help="las señas de esta carpeta no tienen movimiento")
    ap.add_argument("--usa-no-manuales", action="store_true")
    ap.add_argument("--signer", help="tu nombre, igual que en ingest_video.py -- aplica a TODOS los videos de la carpeta")
    ap.add_argument("--mano", choices=["izquierda", "derecha"], dest="mano_dominante")
    ap.add_argument("--espejo", action="store_true", help="si TODOS los videos quedaron espejeados (modo selfie)")
    ap.add_argument("--aprobar", action="store_true")
    ap.add_argument("--generar-espejo", action="store_true", dest="generar_espejo")
    ap.add_argument("--extensiones", help="lista separada por comas, ej. mp4,mov (default: mp4,mov,avi,mkv,webm)")
    ap.add_argument("--seco", action="store_true", help="muestra que se subiria, sin tocar la base ni correr MediaPipe")
    ap.add_argument("--csv-resumen", help="ademas de imprimir el resumen, lo escribe en este CSV")
    ap.add_argument("--pose-model", default=os.path.join(ASSETS, "pose_landmarker_lite.task"))
    ap.add_argument("--hand-model", default=os.path.join(ASSETS, "hand_landmarker.task"))
    args = ap.parse_args()

    if not os.path.isdir(args.carpeta):
        sys.exit(f"no existe la carpeta: {args.carpeta}")

    extensiones = (
        {"." + e.strip(". ").lower() for e in args.extensiones.split(",")}
        if args.extensiones else EXTENSIONES_DEFAULT
    )
    videos = sorted(
        f for f in glob.glob(os.path.join(args.carpeta, "*"))
        if os.path.isfile(f) and os.path.splitext(f)[1].lower() in extensiones
    )
    if not videos:
        sys.exit(f"no encontre videos ({', '.join(sorted(extensiones))}) en {args.carpeta}")

    mapa_excel = leer_excel(args.excel) if args.excel else {}

    planeados = []
    for video in videos:
        nombre = os.path.splitext(os.path.basename(video))[0]
        gloss = a_glosa(base_sin_toma(nombre))
        if not gloss:
            planeados.append((video, None, None, None))
            continue
        espanol, categoria = mapa_excel.get(gloss, (humanizar(gloss), None))
        categoria = categoria or args.categoria
        planeados.append((video, gloss, espanol, categoria))

    print(f"{len(videos)} video(s) en {args.carpeta}:")
    for video, gloss, espanol, categoria in planeados:
        etiqueta = f"{gloss} ({espanol})" if gloss else "** no se pudo armar una glosa del nombre **"
        cat_txt = f"  ·  {categoria}" if categoria else ""
        print(f"  {os.path.basename(video):<30} -> {etiqueta}{cat_txt}")

    if args.seco:
        print("\n(--seco: no se proceso ningun video)")
        return

    if not os.path.exists(args.pose_model):
        sys.exit(f"no encuentro el modelo de pose en {args.pose_model} (ver CORRER.md)")
    if not os.path.exists(args.hand_model):
        sys.exit(f"no encuentro el modelo de manos en {args.hand_model} (ver CORRER.md)")

    load_dotenv()
    print("\nConectando a la base y cargando MediaPipe (una sola vez para toda la carpeta)...")
    conn = db.conectar()
    extractor = ExtractorLandmarks(args.pose_model, args.hand_model)
    resultados = []
    try:
        for i, (video, gloss, espanol, categoria) in enumerate(planeados, start=1):
            nombre_archivo = os.path.basename(video)
            print(f"\n[{i}/{len(planeados)}] {nombre_archivo}")
            if not gloss:
                print("  SALTEADO: no se pudo armar una glosa del nombre de archivo")
                resultados.append({"archivo": nombre_archivo, "gloss": "", "ok": False, "error": "sin glosa"})
                continue
            try:
                r = ingest_un_video(
                    conn, extractor,
                    video_path=video, gloss=gloss, espanol=espanol,
                    categoria=categoria, manos=args.manos,
                    es_estatica=args.es_estatica, usa_no_manuales=args.usa_no_manuales,
                    signer=args.signer, mano_dominante=args.mano_dominante,
                    espejo=args.espejo, generar_espejo=args.generar_espejo,
                    aprobar=args.aprobar,
                )
                conn.commit()
                print(f"  ok - {r['n_frames']} frames, calidad {r['quality_score']:.0%}, {r['estado']}")
                resultados.append({
                    "archivo": nombre_archivo, "gloss": gloss, "espanol": espanol,
                    "ok": True, "sample_id": r["sample_id"], "calidad": round(r["quality_score"], 3),
                    "estado": r["estado"],
                })
            except Exception as e:
                conn.rollback()
                print(f"  FALLO: {e}")
                resultados.append({"archivo": nombre_archivo, "gloss": gloss, "ok": False, "error": str(e)})
    finally:
        extractor.cerrar()
        conn.close()

    ok = [r for r in resultados if r["ok"]]
    fallidos = [r for r in resultados if not r["ok"]]
    print(f"\nListo: {len(ok)}/{len(resultados)} subidos.")
    if fallidos:
        print(f"{len(fallidos)} no se subieron:")
        for r in fallidos:
            print(f"  {r['archivo']}: {r['error']}")
    print(
        "\nQuedaron 'pendiente' (salvo que hayas usado --aprobar). Revisalas y "
        "aprobalas (INGESTA.md paso 7) y despues corre "
        "'python tools/exportar_paquete.py' para que entren al paquete de la app."
    )

    if args.csv_resumen:
        campos = ["archivo", "gloss", "espanol", "ok", "sample_id", "calidad", "estado", "error"]
        with open(args.csv_resumen, "w", newline="", encoding="utf-8") as f:
            w = csv.DictWriter(f, fieldnames=campos, extrasaction="ignore")
            w.writeheader()
            w.writerows(resultados)
        print(f"Resumen escrito en {args.csv_resumen}")


if __name__ == "__main__":
    main()
