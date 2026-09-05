# Integración del puente de MediaPipe en un proyecto de Flutter

Esta guía te enseña a conectar el código nativo de Kotlin (CameraX + MediaPipe) con la app de Flutter.

## Estructura del proyecto

```
univoz_app/
  android/
    app/src/main/
      AndroidManifest.xml    (actualizar permisos)
      kotlin/com/univoz/senas_app/
        MainActivity.kt       (copiar y adaptar)
      kotlin/com/univoz/senas/  (copiar todo)
        LandmarkEngine.kt
        LandmarkPlugin.kt
    build.gradle             (agregar dependencias)
  lib/
    main.dart
    screens/
      translation_screen.dart  (usa PantallaDeTranslacion)
  pubspec.yaml               (referencia senas_core)
```

## Paso 1: configurar pubspec.yaml

```yaml
dependencies:
  flutter:
    sdk: flutter
  senas_core:
    path: ../senas_core
  permission_handler: ^11.4.0  # para pedir permiso de camara

dev_dependencies:
  flutter_test:
    sdk: flutter
```

Corre `flutter pub get`.

## Paso 2: permisos en AndroidManifest.xml

```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    package="com.univoz.senas_app">

    <uses-permission android:name="android.permission.CAMERA" />
    <uses-feature android:name="android.hardware.camera" />
    <uses-feature android:name="android.hardware.camera.front" />

    <application ...>
        ...
    </application>
</manifest>
```

## Paso 3: MainActivity en Kotlin

Copia `android/MainActivity.kt` a `android/app/src/main/kotlin/com/univoz/senas_app/MainActivity.kt` y cambia el package si es necesario.

Verifica que extienda `FlutterActivity` (la estructura default de Flutter lo hace).

## Paso 4: código nativo de MediaPipe

Copia estos archivos a `android/app/src/main/kotlin/com/univoz/senas/`:

- `LandmarkEngine.kt`
- `LandmarkPlugin.kt`

(Nota el package distinto: `com.univoz.senas`, no `com.univoz.senas_app`)

## Paso 5: modelos de MediaPipe

Descarga los modelos oficiales desde
https://developers.google.com/mediapipe/solutions/vision/hand_landmarker/android#download-models

Necesitas:
- `hand_landmarker.task`
- `pose_landmarker_lite.task`  (lite es más rápido, full es más preciso)

Ponlos en `android/app/src/main/assets/`.

Si assets/ no existe, créala.

## Paso 6: dependencias en build.gradle

Agrega a `android/app/build.gradle`, dentro de `dependencies`:

```gradle
dependencies {
    // Media Pipe
    implementation 'com.google.mediapipe:tasks-vision:0.10.9'
    
    // Camera
    implementation 'androidx.camera:camera-core:1.3.0'
    implementation 'androidx.camera:camera-camera2:1.3.0'
    implementation 'androidx.camera:camera-lifecycle:1.3.0'
}

// Minimo API 21 para mediaipe
android {
    defaultConfig {
        minSdkVersion 21
    }
}
```

Si la app ya usa `minSdkVersion` menor a 21, sube a 21 o MediaPipe no compila.

## Paso 7: pantalla de traducción en Dart

Copia `flutter/camera_bridge.dart` y `flutter/skeleton_painter.dart` a tu proyecto:

```
lib/
  bridge/
    camera_bridge.dart
    skeleton_painter.dart
  screens/
    translation_screen.dart
```

Ajusta los imports si cambias la ruta.

## Paso 8: usa la pantalla

En tu `main.dart` o donde navegues:

```dart
import 'bridge/skeleton_painter.dart';

// ...
MaterialPageRoute(builder: (_) => const PantallaDeTranslacion()),
```

## Paso 9: permisos en tiempo de ejecución

Antes de navegar a `PantallaDeTranslacion`, pide permiso de camara:

```dart
import 'package:permission_handler/permission_handler.dart';

Future<void> _pedirPermisos() async {
  final status = await Permission.camera.request();
  if (status.isDenied) {
    // Usuario denegó
  } else if (status.isDenied || status.isPermanentlyDenied) {
    openAppSettings();
  }
}
```

Corre esto en `initState()` de tu pantalla principal, o antes de mostrar la captura.

## Paso 10: compile y prueba

```bash
flutter clean
flutter pub get
flutter run
```

Si ves la camara con el esqueleto dibujado encima, ¡funcionó!

## Solución de problemas

### "No se encuentra hand_landmarker.task"
→ Verifica que estén en `android/app/src/main/assets/` exactamente.

### Error de compilación: `Unresolved reference: HandLandmarker`
→ `flutter pub get` no actualizó Gradle. Corre:
```bash
flutter clean
cd android && ./gradlew clean build && cd ..
flutter pub get
```

### La app crashea en el minuto 2 de usar la camara
→ Probablemente hay un leak de memoria en el análisis de frames. Verifica que `proxy.close()` se llama en `procesar()`.

### El esqueleto tiembla o tiene latencia
→ Normal con Dart puro. En la fase 2 el reconocimiento va en un `Isolate` para no bloquear la UI, o si latencia crítica, mueves el DTW a JNI.

### Camara muy lenta o baja calidad
→ Ajusta en `LandmarkEngine`:
   - `setMinHandDetectionConfidence(0.3f)` si pierdes manos
   - `setMinPoseDetectionConfidence(0.3f)` si pierdes el cuerpo
   - Baja confianza = más rápido pero menos preciso

### "Permission denied: CAMERA"
→ El usuario denegó el permiso en tiempo de ejecución. Llama a `openAppSettings()` para que lo cambie.

## Siguientes pasos

Con esto funcionando, lo que sigue es:

1. **Reconocimiento en vivo**: integra `DtwClassifier` para reconocer señas mientras se capturan.
2. **Grabación de muestras**: captura y guarda secuencias de landmarks para entrenar.
3. **PostgreSQL**: conecta el servidor para sincronizar plantillas y guardar sesiones.
4. **TTS**: convierte la glosa a voz (texto → voz en tiempo real).
