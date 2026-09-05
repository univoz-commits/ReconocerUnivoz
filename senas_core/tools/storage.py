"""Sube el video original a Supabase Storage (OPCIONAL).

Si no configuras SUPABASE_URL / SUPABASE_SERVICE_KEY en tu .env,
ingest_video.py sigue funcionando exactamente igual -- la muestra y sus
landmarks normalizados se guardan de todas formas. Lo unico que cambia es
que 'video_uri' en la base va a quedar como el nombre del archivo local en
vez de un link real, asi que tus companeros no van a poder abrir el video
original para revisarlo antes de aprobar la muestra (solo van a ver el
esqueleto/los numeros).

El service_role key tiene acceso total al proyecto de Supabase. NUNCA lo
pongas en la app de Flutter ni lo subas a git -- es solo para scripts que
corren en tu maquina.
"""

import os

import requests

BUCKET_DEFAULT = "videos"


def subir_video(local_path, nombre_remoto):
    url_base = os.environ.get("SUPABASE_URL")
    key = os.environ.get("SUPABASE_SERVICE_KEY")
    bucket = os.environ.get("SUPABASE_BUCKET", BUCKET_DEFAULT)
    if not url_base or not key:
        return None

    endpoint = f"{url_base}/storage/v1/object/{bucket}/{nombre_remoto}"
    with open(local_path, "rb") as f:
        data = f.read()

    try:
        resp = requests.put(
            endpoint,
            headers={
                "Authorization": f"Bearer {key}",
                "Content-Type": "video/mp4",
                "x-upsert": "true",
            },
            data=data,
            timeout=60,
        )
    except requests.RequestException as e:
        print(f"  aviso: no se pudo subir el video a Supabase Storage ({e})")
        return None

    if resp.status_code not in (200, 201):
        print(
            f"  aviso: no se pudo subir el video a Supabase Storage "
            f"({resp.status_code}: {resp.text[:200]})"
        )
        return None

    return f"{url_base}/storage/v1/object/public/{bucket}/{nombre_remoto}"