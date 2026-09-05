"""Convierte una palabra escrita por una persona en glosa canonica.

Espejo exacto de aGlosa() en lib/muestras_locales.dart: la misma palabra
tiene que dar la misma glosa sin importar si la escribiste en la app o si
viene de un nombre de archivo procesado por tools/ingest_carpeta.py -- si no,
la misma sena podria terminar partida en dos filas distintas de `signs`.
"""

import re

_ACENTOS = {
    "á": "a", "é": "e", "í": "i", "ó": "o", "ú": "u", "ü": "u",
    "ñ": "n",
}


def a_glosa(palabra):
    """"cómo estás" -> "COMO_ESTAS". Sin acentos, para que la misma palabra
    escrita de dos formas no cree dos senas distintas en la base."""
    minusculas = palabra.strip().lower()
    sin_acentos = "".join(_ACENTOS.get(c, c) for c in minusculas)
    sin_simbolos = re.sub(r"[^a-z0-9\s_]", "", sin_acentos).strip()
    con_guion_bajo = re.sub(r"[\s_]+", "_", sin_simbolos)
    return con_guion_bajo.upper()
