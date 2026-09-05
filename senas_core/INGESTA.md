# Subir videos, guardarlos y reconocer señas

Esta guía conecta tres cosas que ya existían en el proyecto pero no
estaban unidas: el esquema de PostgreSQL (`sql/001_schema.sql`), la
normalización canónica (`tools/sign_norm.py`) y el clasificador DTW
(`tools/dtw.py`). Lo que agrega esta ronda es la parte que faltaba: los
scripts que extraen landmarks de un video, los guardan en la base, y
después reconocen una seña nueva contra lo guardado.

## Por qué Supabase

La base de datos es una herramienta de **desarrollo**: la usan ustedes
para subir y curar el diccionario de señas. La app del usuario final nunca
la toca en vivo — descarga una copia local del diccionario una sola vez
(`v_paquete_prototipos`) y reconoce en el teléfono, sin red. Por eso elegir
un Postgres en la nube para el equipo no compromete que la app final
funcione sin internet.

Como van a subir videos entre varias personas, necesitan una base
**compartida**, no una en la PC de alguien. Supabase da Postgres +
pgvector ya instalado, gratis, con panel web, sin que nadie tenga que
mantener un servidor.

## 1. Crear el proyecto en Supabase

1. Andá a [supabase.com](https://supabase.com) y creá una cuenta (podés
   entrar con GitHub).
2. "New project" → elegí un nombre (ej. `univoz`), una región cercana, y
   una contraseña para la base de datos. **Guardá esa contraseña**, la vas
   a necesitar en el paso 3.
3. Esperá 1-2 minutos a que el proyecto termine de crearse.

## 2. Correr el esquema

1. En el panel de Supabase, andá a **SQL Editor** (menú izquierdo) → **New
   query**.
2. Abrí el archivo `sql/001_schema.sql` de este proyecto, copiá **todo**
   su contenido, y pegalo en el editor.
3. Click en **Run**. Debería terminar sin errores y crear:
   - `norm_versions`, `model_versions` — versionado del pipeline
   - `signs` — el diccionario (glosa, español, categoría)
   - `sign_samples` — cada grabación individual (video o cámara)
   - `sample_landmarks` — la secuencia normalizada de cada muestra (lo que
     usa el reconocedor)
   - `sample_embeddings`, `sign_prototypes` — para la fase 2 (encoder
     entrenado), no se usan todavía
   - las vistas `v_paquete_prototipos` y `v_cobertura`

   `pgvector` ya viene instalado en Supabase, así que la línea `CREATE
   EXTENSION IF NOT EXISTS vector;` va a funcionar sin que tengas que
   activar nada aparte. (Yo probé el resto del esquema completo contra un
   Postgres real para confirmar que no tiene errores — inserciones,
   constraints y vistas incluidas.)

No hace falta tocar ni una línea de `001_schema.sql` — ya tiene todo lo
necesario para esto.

## 3. (Opcional) Bucket para los videos originales

Si quieren poder abrir el video original de cada muestra para revisarla
antes de aprobarla (recomendado):

1. **Storage** (menú izquierdo) → **New bucket** → nombre `videos` →
   marcalo como **Public** (para un dataset de entrenamiento de un
   proyecto chico esto es razonable; si más adelante quieren restringirlo,
   se puede cambiar a privado y generar URLs firmadas).

Si se saltean este paso, todo el resto funciona igual — el video en sí no
queda accesible por link, pero la muestra y sus landmarks se guardan
igual.

## 4. Conseguir las credenciales

- **DATABASE_URL**: Settings → Database → **Connect** (o "Connection
  string"). Supabase puede mostrarte dos formatos distintos según cuándo se
  creó el proyecto — usá el que veas en tu panel, los dos funcionan para
  estos scripts:
  - **Formato directo** (proyectos viejos):
    `postgresql://postgres:[YOUR-PASSWORD]@db.xxxxx.supabase.co:5432/postgres`
  - **Formato pooler** (proyectos nuevos, pestaña "Transaction pooler"):
    `postgresql://postgres.xxxxx:[YOUR-PASSWORD]@aws-0-REGION.pooler.supabase.com:6543/postgres?pgbouncer=true`

  En cualquiera de los dos, reemplazá `[YOUR-PASSWORD]` por la contraseña
  del paso 1 **sin dejar los corchetes** — son solo para marcar dónde va,
  no son parte de la contraseña. Si el panel te muestra también una
  `DIRECT_URL` (para migraciones), no hace falta: estos scripts solo usan
  `DATABASE_URL`.
- **SUPABASE_URL** y **SUPABASE_SERVICE_KEY** (solo si hicieron el paso 3):
  Settings → API → **Project URL** y la clave secreta del proyecto. Según
  cuándo se creó el proyecto, Supabase la muestra con uno de estos dos
  nombres (son el mismo concepto, elegí la que veas en tu panel):
  - Proyectos nuevos: **Secret keys** → `sb_secret_...`
  - Proyectos viejos: **service_role secret**

  En ambos casos, **no** uses la otra clave que aparece al lado
  (`sb_publishable_...` o `anon` respectivamente) — esa es la clave
  pública, pensada para el cliente, y no tiene permiso de escritura en
  Storage. Si la pegás en `SUPABASE_SERVICE_KEY` por error, la subida del
  video va a fallar con un error de permisos.

Compartan estos valores con el equipo por un canal privado (no por commit
de git). Cada persona los pega en su propio `.env`.

## 5. Configurar tu máquina

```bash
cd senas_core
cp .env.example .env
# editar .env y pegar DATABASE_URL (y SUPABASE_URL/SUPABASE_SERVICE_KEY si aplica)

pip install -r tools/requirements.txt
```

Los modelos de MediaPipe (`hand_landmarker.task`,
`pose_landmarker_lite.task`) ya los tenés si seguiste `CORRER.md` para la
app — los scripts los buscan por defecto en
`android/app/src/main/assets/`. Si no están ahí, descargalos de los links
de `CORRER.md` o pasale `--pose-model` / `--hand-model` con la ruta
correcta.

## 6. Subir una seña

```bash
python tools/ingest_video.py \
  --video videos/casa_01.mp4 \
  --gloss CASA \
  --espanol casa \
  --categoria hogar \
  --signer TuNombre \
  --mano derecha
```

Esto: abre el video, corre los mismos dos modelos MediaPipe que usa la
app, normaliza cada frame con `sign_norm.py` (la misma implementación que
ya valida contra Dart), y guarda la muestra en `sign_samples` +
`sample_landmarks`. Queda con estado `pendiente` hasta que alguien la
revise.

**Flags importantes:**

- `--espejo`: si el video quedó como en un espejo (modo selfie de la
  cámara frontal). Si al reconocer más tarde las señas de una sola mano
  salen sistemáticamente confundidas o invertidas, es la primera cosa que
  hay que probar.
- `--signer`: usalo siempre que puedas. El esquema evita mezclar a la
  misma persona en entrenamiento y prueba — sin esto, el sistema puede
  "aprender a reconocerte a vos" en vez de la seña.
- `--aprobar`: salta la revisión y guarda la muestra como `aprobada` de
  una. Útil al principio cuando confían en lo que están subiendo; después
  conviene sacarlo y revisar antes.

**Consejo práctico:** si van a grabar con el celular para el dataset,
graben siempre con la **cámara trasera** (no la frontal) cuando puedan —
elimina la ambigüedad de si el archivo quedó espejeado o no, que varía
según el teléfono y la app de cámara.

## 7. Revisar y aprobar muestras pendientes

En el SQL Editor de Supabase:

```sql
-- ver que hay pendiente de revisar
SELECT ss.id, s.gloss, ss.video_uri, ss.quality_score, ss.creado_en
FROM sign_samples ss
JOIN signs s ON s.id = ss.sign_id
WHERE ss.estado = 'pendiente'
ORDER BY ss.creado_en;
```

Si subiste el bucket de videos (paso 3), `video_uri` es un link que se
puede abrir directo para mirar el video. Después de confirmar que la seña
en el video corresponde a la glosa:

```sql
UPDATE sign_samples SET estado = 'aprobada', revisada_por = NULL
WHERE id = 'el-id-de-la-muestra';
```

Para rechazar una que está mal etiquetada o es de mala calidad:

```sql
UPDATE sign_samples SET estado = 'rechazada'
WHERE id = 'el-id-de-la-muestra';
```

Cuántas muestras aprobadas y de cuántas personas distintas tiene cada
seña (con menos de 3 personas el reconocimiento tiende a aprender a
reconocer a una sola persona, no la seña en sí):

```sql
SELECT * FROM v_cobertura ORDER BY muestras_reales;
```

## 8. Reconocer una seña nueva

```bash
python tools/reconocer_video.py --video videos/prueba.mp4
```

Carga todas las muestras `aprobada` de la base, y compara el video nuevo
contra ellas con DTW (sin entrenar nada — funciona con pocas muestras por
seña, tal como ya documentaba `README.md`). Imprime la seña reconocida (si
pasa los umbrales de distancia y margen) o las mejores candidatas si no
está seguro.

## 9. Grabar muestras desde el celular

La app tiene un menú con cuatro entradas: **Reconocer seña**, **Agregar
muestras**, **Mis muestras** y **Ajustes**.

En **Agregar muestras** escribís la palabra ("cómo estás"), la app la
convierte a glosa (`COMO_ESTAS`, sin acentos ni espacios — la misma
convención que usa `--gloss`), y grabás la seña. La palabra queda fija
arriba, así que podés grabar diez repeticiones seguidas sin volver a
escribir nada. Cada muestra cuenta para el reconocimiento **al instante**,
sin pasar por la base.

### Subirlas a la base desde el propio teléfono

En **Sincronizar** hay dos botones independientes:

- **Subir mis muestras** → van directo a Supabase, en estado `pendiente`.
- **Bajar el diccionario** → trae todas las muestras `aprobada` y las guarda
  en el teléfono. Después de eso se reconoce **sin internet**, que es el
  punto del diseño: la app no consulta la base en vivo.

Requisito, una sola vez: correr **`sql/002_app_acceso.sql`** en el SQL Editor
de Supabase (después de `001_schema.sql`), y que `lib/config_supabase.dart`
tenga la URL del proyecto y la clave **publishable**.

**Sobre poner la clave en la app.** La clave publishable (`sb_publishable_…`,
antes "anon") está hecha para vivir en el cliente: por sí sola no da ningún
permiso — todo lo decide row level security del lado del servidor. Lo que
nunca puede ir en el APK es la clave **secreta** (`sb_secret_…` /
`service_role`), que ignora RLS y da acceso total; esa vive solo en el `.env`
de la PC.

`002_app_acceso.sql` es lo que hace segura esa exposición. Hoy las tablas
están **sin RLS**, y en Supabase eso significa que cualquiera con la clave
publishable puede leer, escribir *y borrar* todo. El script prende RLS y deja
pasar solo: leer, crear señas nuevas, y subir muestras **forzadas a
`pendiente`** (`WITH CHECK (estado = 'pendiente')`). Sin políticas de UPDATE
ni DELETE, o sea: prohibidas. En el peor caso, alguien que extraiga la clave
del APK puede ensuciar la cola de pendientes; no puede tocar el diccionario
aprobado ni borrar nada.

### Vía alternativa: exportar e importar desde la PC

Sirve cuando el teléfono no tiene internet, o para revisar el archivo antes
de que entre a la base:

1. En la app: **Mis muestras** → ícono de compartir → mandate el archivo
   (mail, WhatsApp, Drive) y bajalo a la PC.
2. En la PC:
   ```bash
   python tools/importar_muestras.py --archivo muestras_univoz_....json --generar-espejo
   ```
   Agregá `--seco` para ver qué importaría sin escribir nada, o `--aprobar`
   para saltarte la revisión.

### Aprobar lo que llegó

Suba como suba, las muestras entran `pendiente`. Para que entren al
diccionario, en el SQL Editor:

```sql
UPDATE sign_samples SET estado = 'aprobada' WHERE estado = 'pendiente';
```

Después, en la app: **Sincronizar → Bajar el diccionario**. (`exportar_paquete.py`
sigue sirviendo para dejar el diccionario adentro del APK, así una instalación
nueva ya viene con señas sin tener que sincronizar primero.)

## 10. Calibrar los umbrales

Los umbrales por defecto (distancia máxima 0.55, margen mínimo 0.12) están
calibrados contra datos **sintéticos**, no contra grabaciones reales. Es
esperable que al principio reconozcan mal.

En **Ajustes** se cambian sin recompilar. La pantalla de reconocimiento
muestra, además del resultado, la distancia y el margen que dio y las otras
candidatas — que es lo que hace posible calibrar con criterio en vez de a
ciegas:

- **Reconoce cosas que no hiciste** → bajá la distancia máxima, o subí el
  margen mínimo.
- **No reconoce nada** → subí la distancia máxima. Si la seña correcta
  aparece primera en las candidatas pero igual la rechaza, el problema es el
  margen: bajalo.
- **Confunde dos señas parecidas entre sí** → no es cuestión de umbrales:
  faltan muestras de esas dos.

Antes de tocar umbrales conviene tener ~5 muestras por seña. Con una sola
muestra por seña, ningún umbral funciona bien.

## Cómo encaja esto con lo que ya existía

- La normalización (`sign_norm.py`) es la misma que ya se valida contra
  Dart por el golden test — un video ingresado por acá y una seña
  capturada en vivo por la app producen vectores comparables.
- El DTW (`dtw.py`) es el mismo que ya estaba escrito, solo que antes no
  tenía de dónde sacar plantillas reales; ahora las saca de
  `sign_samples`/`sample_landmarks` aprobadas.
- `sample_embeddings` / `sign_prototypes` / `v_paquete_prototipos` siguen
  sin usarse — son para la fase 2, cuando entrenen un encoder. El DTW de
  ahora ya es un sistema de reconocimiento completo de punta a punta sin
  necesitar eso todavía.
