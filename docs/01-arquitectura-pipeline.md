# Arquitectura y pipeline

## Contrato rector

- `MotionFrameV2` conserva `norm_version="2.0.0"`, `frame_dim=152` y
  `t_frames=32`.
- Sus 152 valores son numéricos y finitos. No usar `null` ni cero para
  representar un segmento anatómico ausente.
- `CapabilityMask`, confianza, estado de track, timestamps y auditoría son
  metadatos externos al vector. El clasificador aplica la máscara al calcular
  distancias.
- `raw` es evidencia de captura. `render` puede retener, predecir o reparar
  para continuidad visual. Reparar `render` nunca modifica `raw`, grabación ni
  entrada de IA.
- Orientación no verificable conserva último estado válido y emite auditoría;
  no se invierte automáticamente.

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
  ↓
  Safety Gate por unión
    ├─→ RenderState a 60 FPS
    └─→ MotionFrameV2 de 152D
                ↓
             DTW local / AI Engine opcional

Auditoría numérica observa todas las etapas y conserva AuditSnapshot efímeros.
```

## Capas de datos

| Capa | Contenido | Uso | Persistencia |
|---|---|---|---|
| `RawFrame` | landmarks originales, timestamp y confianza disponible | diagnóstico y auditoría | efímera por defecto |
| `ValidatedFrame` | puntos válidos, huecos y outliers marcados; reparación visual separada | entrada de filtros | efímera |
| `SmoothedFrame` | posiciones/ángulos estabilizados | avatar e IK | efímera |
| `SemanticFrame` | ángulos, orientación y posiciones normalizadas | IA | convertida a 152D |
| `FingerRenderState` | ángulos de falanges filtrados una sola vez | dedos del avatar | efímera |
| `RenderState` | estado interpolado del rig | VRM | efímera |
| `CapabilityMask` | segmento presente, limitado, parcial, ausente o incierto | avatar y clasificador | local, borrable |
| `AuditSnapshot` | frame, etapa, unión, score, severidad, estado, acción y código | diagnóstico numérico | buffer local 45 s |

No usar preview para guardar muestras: preview prioriza respuesta visual y puede
mezclar resultados de instantes cercanos. El stream fusionado es la fuente de
normalización y captura.

## Relojes, FPS y colas

- `tracking_fps`: frames de manos aceptados por segundo. Objetivo `>=30`.
- `pose_fps`: frames Pose aceptados por segundo. Puede ser `~15` con cache
  temporal explícita; no se mezcla con `tracking_fps`.
- `render_fps`: callbacks que aplican estado y renderizan avatar. Objetivo
  `>=60`.
- Cada métrica separa frames entregados, inválidos y descartados.
- Cola viva: último frame válido; descartar frames viejos.
- Ruta de dedos: no encolar ni volver a suavizar XYZ; medir `fingerLag`.
- Una pérdida breve conserva o predice el último estado.
- Un estado obsoleto prolongado libera suavemente el rig.
- Un candidato inválido congela solo su unión; nunca se aplica a VRM.

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
| MAD formal con ventana robusta | detecta y repara spikes silenciosos solo en RenderState; cámara pendiente |
| One Euro adaptativo | implementada para RenderState con calidad de frame |
| Safety Gate por unión | implementada en visor; evidencia de dispositivo pendiente |
| FingerRenderState rápido | implementada en visor; p95 real pendiente |
| Auditoría numérica y códigos | implementada en visor; cobertura real pendiente |
| Métricas de etapas | integradas en loop Web y panel/export; Android y evidencia física pendientes |
| Buffer numérico efímero 45 s | implementada en memoria; prueba prolongada pendiente |
| Kalman por track | pendiente; usar para muñeca/oclusión, no como filtro principal de dedos |
| Hungarian general | no requerido para dos tracks; matching 2×2 actual es suficiente |
| Calibración antropométrica persistible | parcial: calibración de rig; perfil/capacidad pendientes |
| HandCapabilityModel y máscara | pendiente |
| Perfil biométrico-cinemático versionado | pendiente |
| Face ID, profundidad o multicámara | fuera de Fase 1 |

## Presupuesto de latencia

Objetivo final: `p95 < 50 ms` desde captura hasta avatar. Durante baseline,
`p95 <=120 ms` es solo límite provisional para diagnosticar equipos lentos; no
es criterio de producción. Medir por etapa antes de optimizar:

| Etapa | Rango inicial |
|---|---:|
| cámara | 5–16 ms |
| MediaPipe | 8–20 ms |
| validación | 1–3 ms |
| filtro/asociación | 2–5 ms |
| IK/retargeting | 1–4 ms |
| render | 8–16 ms |

Los rangos son objetivos, no resultados medidos. Registrar `p50`, `p95`, `p99`,
frames descartados y skew Pose–Hand. La calidad del frame modula filtro visual;
no altera secuencia raw de captura.

Métrica adicional de dedos: `fingerLag = t_avatar_90% - t_input_90%`, objetivo
`p95 ≤ 66 ms`. El resultado sintético no sustituye medición de cámara real.
