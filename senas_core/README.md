# Núcleo de reconocimiento de señas

Base compartida entre la app de Flutter y el pipeline de ingesta en Python.
Esto es la fase 0: todavía no reconoce nada, pero define el formato de datos
del que va a depender todo lo demás.

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
```

## Cómo correrlo

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

## El vector de 138 dimensiones

Cada frame se convierte en un vector con esta estructura:

| Rango    | Dim | Contenido |
|----------|-----|-----------|
| 0–11     | 12  | codos, muñecas y caderas en marco del cuerpo (x, y) |
| 12–13    | 2   | muñeca izquierda respecto al cuerpo |
| 14–15    | 2   | muñeca derecha respecto al cuerpo |
| 16       | 1   | 1.0 si se detectó la mano izquierda |
| 17       | 1   | 1.0 si se detectó la mano derecha |
| 18–77    | 60  | forma de la mano izquierda: 20 puntos (x, y, z) |
| 78–137   | 60  | forma de la mano derecha |

Una seña completa son 32 frames × 138 floats. En float16 pesa **8.6 KB**,
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

Este es el detalle que decide si funciona o no. Los 138 números no valen lo
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
prefiltro compara primero el vector promedio de la secuencia (138
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
