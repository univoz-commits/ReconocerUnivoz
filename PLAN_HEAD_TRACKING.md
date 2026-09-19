# Plan: Avatar en Tiempo Real — Head Tracking con MediaPipe

## Veredicto

- **OpenSeeFace NO se usa.** Solo hace cara (66 landmarks), MediaPipe ya hace
  cara (468) + cuerpo (33) + manos (21). Agregarlo sería Python + UDP para
  repetir lo que ya existe.
- **No se construye sistema propio de detección.** MediaPipe ya detecta todo.
  Lo que falta es **usar** los datos faciales que ya están disponibles.
- **Licencia segura.** MediaPipe es Apache 2.0, sin problemas legales de uso
  público.

## Estado Actual

| Componente | Estado |
|------------|--------|
| Pose Landmarker (cuerpo 33pts) | Funcionando |
| Hand Landmarker (manos 21pts × 2) | Funcionando |
| Face Landmarker (cara 468pts) | **NO integrado** |
| Head rotation en avatar | **NO existe** |
| Brazos/manos en avatar | Funcionando (IK + dedos) |

## Qué se va a hacer

### Paso 1: Descargar face_landmarker.task (~4MB)

```
https://storage.googleapis.com/mediapipe-tasks/face_landmarker/face_landmarker.task
→ android/app/src/main/assets/
```

### Paso 2: LandmarkEngine.kt — agregar FaceLandmarker

- Agregar `FaceLandmarker` junto a `HandLandmarker` y `PoseLandmarker`
- Configurar en `LIVE_STREAM` mode, 1 rostro, confidence 0.4
- Callback que extrae los 48 puntos faciales relevantes (ojos, nariz, orejas,
  frente, mentón)
- Agregar `analizarCara(bitmap, timestampMs)` con su propia compuerta de
  backpresion

### Paso 3: LandmarkPlugin.kt — calcular head rotation

- De los 48 puntos, calcular yaw/pitch/roll usando 6 puntos ancla:
  - Nariz (punta)
  - Ojo izquierdo / derecho (centro)
  - Oreja izquierda / derecha
  - Frente
- Método: Medir vectores entre puntos, proyectar sobre planos del cráneo
- Salida: `FloatArray(3)` = [yaw, pitch, roll] en radianes
- Agregar campo `headRotation` a `FrameResult`

### Paso 4: Extender metadatos sin romper Motion V2

`MotionFrameV2` conserva `kFrameDim = 152`. La rotación de cabeza y
blendshapes deben viajar como bloque opcional de rostro, con su propio
`face_norm_version`; no se agregan tres números silenciosamente al vector
canónico. Solo una futura versión explícita (`MotionFrameV3`) podrá cambiar la
dimensión después de generar nuevos golden tests y migración de dataset.

### Paso 5: avatar_bridge.dart — pasar head rotation

- En `reproducir()` y `mostrarFrame()`, incluir bloque facial opcional
- El JS valida `norm_version` y no mezcla bloque facial con vector 152D

### Paso 6: index.html — aplicar head rotation en el avatar

```javascript
// ~30 líneas nuevas
function aplicarHeadRotation(yaw, pitch, roll) {
  const neck = bone(VRMHumanBoneName.Neck);
  const head = bone(VRMHumanBoneName.Head);
  if (neck) neck.rotation.set(pitch * 0.5, yaw, 0);
  if (head) head.rotation.set(pitch * 0.5, yaw, roll);
}
```

Llamar desde `aplicarFrame()` si el frame tiene bloque facial válido.

## Archivos a modificar

| Archivo | Cambio |
|---------|--------|
| `android/app/src/main/assets/face_landmarker.task` | NUEVO (descargar) |
| `LandmarkEngine.kt` | Agregar FaceLandmarker |
| `LandmarkPlugin.kt` | Calcular head rotation + enviar |
| `lib/sign_norm.dart` | kFrameDim 152→155, normalizar cabeza |
| `lib/camera_bridge.dart` | Recibir head rotation |
| `lib/avatar_bridge.dart` | Pasar head rotation al JS |
| `assets/avatar_viewer/index.html` | Función aplicarHeadRotation |

## Tiempo estimado: ~2-3 horas

## Riesgos

- **MediaPipe Face Mesh en Lite model**: puede ser menos preciso. Si falla,
  probar `face_landmarker_full.task` (~20MB)
- **Calibración**: los ángulos de head rotation pueden necesitar ajuste
  para que el avatar no gire de más. El panel de calibración existente
  sirve como base.
- **Performance**: 3 modelos corriendo (pose + hands + face) en un teléfono
  puede ser pesado. Medir FPS. Si no da, bajar resolución de análisis o
  correr face cada N frames como se hace con pose.

## Profundidad y “captura holográfica” — decisión técnica

No confundir seguimiento 3D con identificación biométrica. La cámara RGB y
MediaPipe entregan una pose estimada; no miden una superficie holográfica del
cuerpo. Apple consigue una malla facial con TrueDepth/ARKit en hardware
compatible, mientras que ARKit también expone un esqueleto corporal 3D. Esto no
se puede reproducir con una webcam común.

La ruta compatible con ReconocerUnivoz queda así:

1. **Ahora:** RGB + Pose/Hand Landmarker + pose mundial + asociación por
   muñeca + filtro temporal + IK. Es la ruta actual y funciona offline.
2. **Después:** ARCore Depth opcional en Android compatible. Fusionar depth
   solo para validar o corregir Z/oclusiones; no reemplazar landmarks de dedos.
   ARCore calcula depth desde movimiento y puede combinar ToF, pero no todos
   los teléfonos lo soportan.
3. **Mayor precisión:** dos cámaras calibradas (frontal + lateral) y
   triangulación de muñecas/falanges. Es la alternativa real a una captura
   volumétrica cuando se controla el entorno.
4. **Identidad:** mantener `track_id` de sesión para no cambiar de persona;
   no guardar rostro ni crear identificación persistente sin consentimiento.

La profundidad futura será metadato opcional (`depth_m`, intrínsecas,
timestamp, sensor y confianza), separado de `MotionFrameV2` 152D. No cambiar
`norm_version 2.0.0` por agregar sensores.
