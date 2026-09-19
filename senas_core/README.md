# Núcleo de reconocimiento de señas

Base compartida entre la app de Flutter y el pipeline de ingesta en Python.
Este núcleo contiene contrato de movimiento, RigBody cinemático, captura y
reconocimiento offline; define el formato de datos del que depende todo.

```
lib/sign_norm.dart          normalización, para la app
lib/dtw.dart                clasificador DTW, para la app
test/sign_norm_test.dart    valida Dart contra el golden
test/dtw_test.dart          valida el DTW contra el golden
test/golden/golden_cases.json   el contrato entre los dos lenguajes
tools/sign_norm.py          implementación canónica de la normalización
tools/dtw.py                implementación canónica del DTW
tools/gen_golden.py         genera el golden desde Python
tools/test_norm.py          invariancia, espejo, empaquetado
tools/test_dtw.py           clasificación, rechazo, prefiltro
sql/001_schema.sql          esquema de PostgreSQL con pgvector
sql/004_motion_v2.sql       contrato 2.0.0 (32 x 152) y vista estricta
sql/005_storage_raw.sql     Storage privado opcional de landmarks comprimidos
../backend/ai-engine/       SVM/kNN/centroide sobre MotionSequenceV2
```

## Cómo correrlo

Desde la raíz del proyecto, `scripts/univoz.sh` orquesta backend y Flutter:

```bash
cd /home/javier-karim/ReconocerUnivoz
./scripts/univoz.sh setup                 # primera vez
./scripts/univoz.sh doctor                # herramientas y dispositivos
./scripts/univoz.sh test                  # suite completa
./scripts/univoz.sh all -d emulator-5554  # AI Engine + app
./scripts/univoz.sh web                   # visor VRM/RigBody en navegador
```

`all` es el comando rápido: reutiliza dependencias ya instaladas, espera
`/health`, pasa URL backend a Flutter y detiene AI Engine al pulsar `Ctrl+C`.
`web` sirve visor standalone en
http://127.0.0.1:8080/assets/avatar_viewer/index.html?standalone=1; carga
univozM.vrm automáticamente. La raíz del servidor solo muestra archivos. Pulsa
Iniciar cámara para activar MediaPipe web, ver landmarks, alimentar RigBody y
obtener vectores 152D. Grabar 32 guarda una secuencia normalizada en memoria;
Repetir la reproduce y JSON descarga solo vectores, nunca video. `Espejar solo
vista` cambia únicamente preview; etiquetas I/D y huesos conservan lado físico.
`Suavizar movimiento` filtra solo avatar; JSON y datos IA conservan frames crudos.
Si Hand Landmarker omite etiqueta, el visor resuelve lado físico por muñeca
respecto al centro de hombros; si queda cruzada en el centro, no inventa lado.
En `Calibrar`, `Orientar muñeca 3D` usa el marco de palma del bind pose VRM;
desactivarlo sirve únicamente para comparar visualmente durante calibración.
El RigBody resuelve cada brazo con IK 3D de dos huesos hacia la muñeca
capturada, usando longitudes reales del avatar y el plano de codo observado.
El panel muestra `Q` como calidad estimada del frame. Una oclusión breve
conserva última pose; predice hasta 300 ms, mezcla reposo entre 300–500 ms y
libera el track después de 500 ms sin frame válido.
`rig_safety.mjs` bloquea transforms inválidos por unión, congela localmente y
recupera gradualmente. `rig_diagnostics.mjs` conserva `AuditSnapshotV1`
numéricos en memoria durante 45 s, sin video; `fingerLag` objetivo es p95
`≤66 ms` mediante `FingerRenderState` y filtro rápido de ángulos.
Límite de codo predeterminado: `2.60 rad`, suficiente para llevar mano a cara;
se puede reducir desde Ajustes si el rig produce pliegues excesivos.
Requiere permiso de cámara e internet para WASM de MediaPipe.
Para probar solo DTW offline: `./scripts/univoz.sh frontend --no-backend`.
En teléfono físico usa `UNIVOZ_BACKEND_HOST=0.0.0.0` y
`--backend-url http://IP_DE_LA_PC:8000`. Autocompletado Bash:
`source <(./scripts/univoz.sh completion bash)`.

```bash
python3 tools/gen_golden.py     # regenera el golden
python3 tools/test_norm.py
python3 tools/test_dtw.py

dart pub get
dart test
```

Los dos comandos de test van en CI. Si el de Dart falla, significa que la app
está normalizando distinto que el servidor y que los prototipos guardados ya
no son comparables con lo que ve la cámara. Es la falla más cara del sistema
y sin este test tarda meses en aparecer.

## RigBody y captura

`LandmarkFrameV1` fusiona pose de imagen, pose mundial, manos, timestamp,
visibilidad y validez. Solo ese stream alimenta grabación y normalización;
`frames_preview` queda para pintar UI. `MotionSequenceV2` exige exactamente
`norm_version=2.0.0`, `32` frames y `152` valores por frame.

La captura guarda secuencia normalizada, métricas, checksum y un sidecar gzip
de landmarks sin video. El sidecar solo sube a Storage al pulsar la acción
explícita en Sincronizar. El avatar reproduce la misma secuencia que usa DTW.

Después de aplicar SQL, regenerá `assets/plantillas.json`. El asset incluido
en checkout todavía es 138D y la app lo ignora por diseño; no se convierte
automáticamente.

## AI Engine opcional

```bash
cd ../backend/ai-engine
python3 -m venv .venv
. .venv/bin/activate
pip install -r requirements.txt
PYTHONPATH=. python -m ai_engine.server
```

`GET /health` publica contrato activo. `POST /v1/classify` recibe
`norm_version` y `frames` 32x152. DTW local no depende de este servicio; si
backend falla, la app conserva predicción local. Entrenamiento solo desde PC:

```bash
PYTHONPATH=. python -m ai_engine.train --output models
```

SVM entrenado se carga desde `AI_ENGINE_MODEL_DIR` (por defecto `models/`).
Sin SVM, servidor puede cargar muestras aprobadas desde `DATABASE_URL` y usar
kNN. Nunca pongas service key en APK.

## El vector de 152 dimensiones

Cada frame se convierte en un vector con esta estructura:

| Rango    | Dim | Contenido |
|----------|-----|-----------|
| 0–23     | 24  | hombros, codos, muñecas y caderas en marco del cuerpo (x, y, z) |
| 24–26    | 3   | muñeca izquierda respecto al cuerpo |
| 27–29    | 3   | muñeca derecha respecto al cuerpo |
| 30       | 1   | 1.0 si se detectó la mano izquierda |
| 31       | 1   | 1.0 si se detectó la mano derecha |
| 32–91    | 60  | forma de la mano izquierda: 20 puntos (x, y, z) |
| 92–151   | 60  | forma de la mano derecha: 20 puntos (x, y, z) |

Una seña completa son 32 frames × 152 floats. En float16 pesa **9.5 KB**,
que es lo que se guarda en `sample_landmarks.data`.

### Qué hace la normalización

1. **Origen** en el punto medio de los hombros. Da igual dónde esté la persona
   en el encuadre.
2. **Escala** dividiendo entre el ancho de hombros. Da igual la estatura ni la
   distancia a la cámara.
3. **Rotación** que endereza la línea de hombros. Absorbe cámara torcida y
   cuerpo inclinado.
4. **Manos en dos bloques**: la *forma* relativa a la muñeca y escalada por el
   tamaño de esa mano, y la *ubicación* de la muñeca respecto al cuerpo. La
   ubicación es un parámetro fonológico de la lengua de señas, no un detalle
   que se pueda descartar.

`test_norm.py` verifica esto empíricamente: trasladar, alejar, acercar e
inclinar a la misma persona produce el mismo vector con diferencia menor a
1e-14. Eso es lo que significa que la estructura siga a la persona.

### Lo que la normalización NO hace a propósito

**No canonicaliza la rotación de la mano.** Sería tentador rotar cada mano a
una orientación estándar, pero la orientación de la palma distingue señas
distintas. Se conserva.

**No usa la Z de la pose.** MediaPipe la estima por profundidad monocular y es
ruidosa. La Z de las manos sí se usa, relativa a la muñeca, donde es mucho más
estable.

**No decide qué hacer si faltan los hombros.** Devuelve `null` y `fillGaps`
sostiene el último frame válido. Si una toma trae demasiados frames nulos,
`sign_samples.frames_invalidos` lo registra para que la ingesta la rechace.

## Cambiar la normalización después

Si tocas la fórmula:

1. Sube `NORM_VERSION` en Python y `kNormVersion` en Dart.
2. Regenera el golden y corre los dos tests.
3. Inserta la nueva fila en `norm_versions`.
4. Re-extrae las muestras desde los videos originales — por eso se guarda
   `video_uri`. Las secuencias viejas no se convierten, se recalculan.

## El clasificador DTW

Compara la seña entrante contra plantillas guardadas usando Dynamic Time
Warping. No entrena nada: agregar una seña es agregar plantillas.

### La distancia entre frames no es euclidiana

Este es el detalle que decide si funciona o no. Los 152 números no valen lo
mismo: la forma de la mano ocupa 120 dimensiones y la ubicación solo 4. Una
euclidiana plana dejaría que la forma se comiera todo el peso y la ubicación
—que en lengua de señas distingue palabras— se volvería ruido.

Cada bloque se promedia por su número de dimensiones y luego se pondera:

| Bloque | Dims | Peso |
|---|---|---|
| Cuerpo (codos, muñecas, caderas) | 12 | 0.5 |
| Ubicación de cada muñeca | 2 | 1.5 |
| Presencia de cada mano | 1 | 2.0 |
| Forma de cada mano | 60 | 1.0 |

Cuando una muestra tiene una mano y la otra no, no se comparan las formas
—no hay nada que comparar— sino que se aplica una penalización fija.

### Banda de Sakoe-Chiba

El DTW sin restricción puede alinear cualquier cosa con cualquier cosa. La
banda de 4 frames limita cuánto se puede deformar el tiempo: absorbe que
alguien señe más rápido o más lento, pero no permite que una seña se estire
para parecerse a otra.

### Prefiltro

Un DTW completo contra 500 plantillas son ~20 millones de operaciones. El
prefiltro compara primero el vector promedio de la secuencia (152
operaciones por plantilla) y solo corre el DTW completo sobre las 40 mejores
candidatas. En los tests da el mismo resultado que la búsqueda exhaustiva.
Además hay abandono temprano: una plantilla cuya fila acumulada ya supera
1.5× la mejor distancia hasta el momento se descarta sin terminar.

### Aceptar o rechazar

`classify` no devuelve solo la mejor coincidencia, devuelve también un
margen: qué tan lejos quedó la mejor seña *distinta*. Una seña se acepta si
la distancia está por debajo de `maxDistance` **y** el margen supera
`minMargin`. Sin el margen, cualquier gesto aleatorio se clasificaría como
la seña menos lejana.

Los umbrales por defecto (0.55 y 0.12) están calibrados contra datos
sintéticos. **Vas a tener que recalibrarlos con grabaciones reales** — es lo
primero que hay que ajustar cuando tengas las primeras 20 señas grabadas.

## Estructura del proyecto completo

```
univoz/
  senas_core/          ← este paquete
    lib/
      sign_norm.dart      normalización
      dtw.dart            clasificador
    flutter/
      camera_bridge.dart  decodificación de canales
      skeleton_painter.dart UI del esqueleto
    android/
      LandmarkEngine.kt   MediaPipe en LIVE_STREAM
      LandmarkPlugin.kt   canales y CameraX
      MainActivity.kt     punto de entrada
    tools/               tests y golden en Python
    sql/                 esquema de PostgreSQL

  univoz_app/          ← tu app de Flutter
    lib/
      main.dart
      screens/
        translation_screen.dart
    android/            ← copiar MainActivity.kt y kotlin/com/univoz/senas/
    pubspec.yaml        ← referencia senas_core
```

## Siguientes pasos

**Prueba en vivo**: sigue [INTEGRACION.md](INTEGRACION.md) para conectar MediaPipe a una app de Flutter real.

**Reconocimiento continuo**: integra `DtwClassifier` en `translation_screen.dart` para clasificar señas mientras se capturan.

**Backend**: PostgreSQL + `sql/001_schema.sql` para guardar muestras, sincronizar plantillas y gestionar usuarios.
