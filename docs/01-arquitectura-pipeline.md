# Arquitectura y pipeline

## Flujo de extremo a extremo

```text
Cámara RGB
  ↓
CameraX / getUserMedia
  ↓
MediaPipe Pose + Hand Landmarker
  ↓
RawFrame / LandmarkFrameV1
  ├─→ preview inmediato para UI
  └─→ frame fusionado para datos y reconocimiento
        ↓
  validación de confianza y geometría
        ↓
  identidad izquierda/derecha
        ↓
  suavizado, límites y predicción
        ↓
  marco de palma + ángulos semánticos
        ↓
  IK / retargeting a VRM
        ├─→ RenderState a 60 FPS
        └─→ MotionFrameV2 de 152D
                ↓
             DTW local / AI Engine opcional
```

## Capas de datos

| Capa | Contenido | Uso | Persistencia |
|---|---|---|---|
| `RawFrame` | landmarks originales, timestamp y confianza disponible | diagnóstico y auditoría | efímera por defecto |
| `ValidatedFrame` | puntos válidos, huecos y outliers marcados | entrada de filtros | efímera |
| `SmoothedFrame` | posiciones/ángulos estabilizados | avatar e IK | efímera |
| `SemanticFrame` | ángulos, orientación y posiciones normalizadas | IA | convertida a 152D |
| `RenderState` | estado interpolado del rig | VRM | efímera |

No usar preview para guardar muestras: preview prioriza respuesta visual y puede
mezclar resultados de instantes cercanos. El stream fusionado es la fuente de
normalización y captura.

## Relojes y colas

- Detección objetivo: aproximadamente 30 FPS.
- Render objetivo: 60 FPS.
- Cola viva: último frame válido; descartar frames viejos.
- Una pérdida breve conserva o predice el último estado.
- Un estado obsoleto prolongado libera suavemente el rig.

La separación evita que una cola creciente agregue latencia y evita que el
clasificador reciba frames distintos de los usados por el avatar.

## Estado presente frente a objetivo

| Capacidad | Estado en rama |
|---|---|
| Pose y manos MediaPipe | implementada |
| Preview separado de stream fusionado | implementada |
| Vectores canónicos 32 × 152 | implementada |
| Asociación por muñecas/pose y lado anatómico | implementada |
| Validación de rango y geometría | implementada |
| Marco de mano y pulgar calibrable | implementada |
| IK 3D de dos huesos | implementada |
| Low-pass visual y rate limit | implementada |
| MAD formal con ventana robusta | pendiente |
| One Euro adaptativo | pendiente |
| Kalman por track | pendiente |
| Hungarian general | pendiente; hoy hay asignación uno-a-uno acotada |
| Calibración antropométrica persistible | parcial: calibración de rig |
| Face ID, profundidad o multicámara | fuera de Fase 1 |

## Presupuesto de latencia

Objetivo de referencia: `p95 < 50 ms` desde captura hasta render. Medir por
etapa antes de optimizar:

| Etapa | Rango inicial |
|---|---:|
| cámara | 5–16 ms |
| MediaPipe | 8–20 ms |
| validación | 1–3 ms |
| filtro/asociación | 2–5 ms |
| IK/retargeting | 1–4 ms |
| render | 8–16 ms |

Los rangos son objetivos, no resultados medidos. El protocolo de cámara debe
registrar `p50`, `p95` y pérdida de frames.
