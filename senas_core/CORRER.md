# Cómo correr la app de traducción de señas

## Requisitos previos

1. **Flutter 3.13+** y **Dart 3.0+**
   ```bash
   flutter --version
   dart --version
   ```

2. **Android SDK 34** con soporte para API 21+
   ```bash
   flutter doctor
   ```

3. **Emulador o dispositivo Android** (API 21+)
   - Si usas emulador, activa GPU acceleration en las opciones

## Paso 1: Descargar modelos de MediaPipe

Necesitas dos archivos `.task`:

1. **hand_landmarker.task** (~235 MB)
   https://storage.googleapis.com/mediapipe-tasks/hand_landmarker/hand_landmarker.task

2. **pose_landmarker_lite.task** (~4 MB, recomendado) o pose_landmarker_full.task (~30 MB)
   https://storage.googleapis.com/mediapipe-tasks/pose_landmarker/pose_landmarker_lite.task

Colócalos en:
```
senas_core/android/app/src/main/assets/
```

Si la carpeta `assets` no existe, créala.

## Paso 2: Preparar Flutter

```bash
cd C:\Users\PC\Desktop\univoz\senas_core
flutter clean
flutter pub get
```

## Paso 3: Correr la app

```bash
flutter run
```

Si tienes múltiples dispositivos conectados:
```bash
flutter run -d <device_id>
```

Para ver qué dispositivos tienes:
```bash
flutter devices
```

## Qué esperar

1. Verás la app pedir permiso de cámara → TAP en "Permitir"
2. Aparece la cámara frontal con:
   - Líneas azules dibujando el esqueleto del cuerpo
   - Líneas rojas dibujando las manos
   - Texto en la esquina inferior izquierda mostrando qué se detectó

3. Si todo funciona:
   - El timestamp sube continuamente
   - Verás ✓ Cuerpo, ✓ Mano izq, ✓ Mano der (cuando estén visibles)

## Solución de problemas

### "No se encuentra hand_landmarker.task"
→ Descargaste los archivos pero no los colocaste en `android/app/src/main/assets/`

**Solución:**
```bash
# Verifica que existan
dir android\app\src\main\assets\*.task
```

Si no están, descárgalos y colócalos ahí.

### "Unresolved reference: HandLandmarker"
→ Gradle no sincronizó las dependencias

**Solución:**
```bash
flutter clean
cd android
./gradlew clean build
cd ..
flutter pub get
flutter run
```

### La app inicia pero no sale cámara
→ Permisos de cámara denegados

**Solución:**
- En el emulador o dispositivo, ve a Configuración > Aplicaciones > UNIVOZ > Permisos > Cámara
- Activa "Permitir todo el tiempo"
- O presiona "Permitir" cuando la app lo pida

### Error: "Gradle build failed"
→ Probablemente minSdkVersion < 21

**Solución:** El proyecto ya está configurado para minSdkVersion 21. Si sigue errando, corre:
```bash
flutter clean
```

### Cámara muy lenta o solo algunos frames
→ GPU acceleration no está activa

**Solución:**
- Si usas emulador, verifica que GPU acceleration esté ON en sus opciones
- Si usas dispositivo físico, comprueba que tenga Vulkan o Metal (MediaPipe lo necesita)
- Como último recurso, cambia en `android/app/src/main/kotlin/com/univoz/senas/LandmarkEngine.kt`:
  ```kotlin
  .setDelegate(Delegate.CPU)  // de GPU a CPU (más lento)
  ```

### "Permission denied (CAMERA)"
→ Pide permiso pero sigue rechazando

**Solución:**
```bash
flutter run --release  # intenta en release mode
# o abre Settings > Apps > UNIVOZ > Permissions > Camera > Allow all the time
```

## Siguientes pasos

Una vez que ves el esqueleto funcionando:

1. **Grabar señas**: integra un botón "Grabar" que capture 32 frames y los guarde
2. **Reconocimiento**: usa `DtwClassifier` para clasificar señas en tiempo real
3. **Base de datos**: conecta PostgreSQL para sincronizar plantillas
4. **TTS**: convierte la glosa a voz

## Notas técnicas

- Los landmarks crudos se normalizan a 138 dimensiones en Dart
- El DTW calcula similitud sin entrenar (funciona con ~5 muestras por seña)
- El preview se pinta con textura nativa (GPU), no con bitmaps (eficiencia)
- Los landmarks se emiten a ~30 fps (un frame cada ~33 ms)

## Estructura del código

```
lib/
  main.dart              → punto de entrada y permisos
  lib/sign_norm.dart     → normalización (138 dims)
  lib/dtw.dart           → clasificador
  flutter/
    camera_bridge.dart   → canales nativo ↔ Dart
    skeleton_painter.dart→ UI del esqueleto

android/
  app/src/main/
    AndroidManifest.xml  → permisos
    kotlin/
      com/univoz/senas_app/MainActivity.kt  → entrada de Android
      com/univoz/senas/
        LandmarkEngine.kt    → MediaPipe
        LandmarkPlugin.kt    → CameraX + canales
    assets/
      hand_landmarker.task  → modelo de manos
      pose_landmarker_lite.task → modelo de cuerpo
```
