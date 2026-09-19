# Métricas y criterios de aceptación

## Definiciones obligatorias

- `tracking_fps`: frames de manos completos y aceptados por segundo. No incluye
  callbacks de render ni frames Pose cacheados.
- `pose_fps`: frames Pose aceptados por segundo.
- `render_fps`: frames realmente renderizados por `requestAnimationFrame` o
  equivalente.
- `captured_at`: reloj monotónico al aceptar frame de cámara.
- `rendered_at`: primer render que aplica ese `source_frame_id`.
- `L = rendered_at - captured_at`. Reportar `p50`, `p95` y `p99`; no confundir
  tiempo de inferencia con latencia extremo a extremo.
- Cada reporte identifica dispositivo, resolución, navegador/Android,
  iluminación, configuración de filtro y tamaño de muestra.

## Métricas de tracking

### Jitter

En pose estática:

```text
J = RMS(θ_t - lowpass_2Hz(θ_t))
```

Referencia inicial: `<1°–2° RMS` en estado estático, sujeto a dispositivo.

### Latencia

```text
L = t_render - t_capture
```

Reportar `p50`, `p95`, `p99`. Objetivo final: `p95 < 50 ms`. Durante Fase 0,
`p95 <=120 ms` es solo límite provisional de diagnóstico; no habilita
producción. Si WebView supera 50 ms después de medir, evaluar worker o capa
nativa.

### Respuesta de dedos

```text
fingerLag = t_avatar_90% - t_input_90%
```

Objetivo: `p95 ≤ 66 ms`. Medir apertura y cierre rápido/lento de palma, cada
dedo y pulgar; deduplicar muestras con mismo timestamp para no confundir
render a 60 FPS con nueva inferencia.

### Pérdida

```text
loss_rate = frames con mano perdida / frames totales
```

Separar oclusión, salida de cuadro, iluminación y fallo de modelo.

### Swaps

Contar cambios incorrectos de track izquierda/derecha. Objetivo controlado:
cero en secuencias estándar; cualquier swap debe reproducirse y quedar
explicado.

### Pulgar

- `RMSE_thumb`;
- exactitud flexionado/extendido;
- `inversion_rate`.

Objetivo inicial: inversión `<1%` y clasificación controlada `>90%`, después
de medir baseline.

## Métricas del avatar

- longitud de huesos constante;
- velocidad angular en reposo cercana a cero;
- ausencia de teletransporte al reaparecer;
- codo dentro de límites;
- orientación de palma continua;
- replay visual equivalente a captura.

## Métricas de reconocimiento

- Accuracy;
- precision;
- recall;
- F1 macro;
- matriz de confusión;
- distribución de distancia DTW;
- tasa de rechazo de gestos fuera de vocabulario.

No usar objetivos sintéticos como garantía de cámara real.

## Evidencia requerida por fase

| Fase | Muestra mínima | Evidencia de salida | Gate |
|---|---:|---|---|
| 0 baseline | 300 frames/dispositivo | JSON numérico con timestamps, drops, skew y FPS | contrato 32×152 intacto |
| 1 rendimiento | 300 frames con filtro off/on | p50/p95/p99 por etapa y captura→avatar | manos `>=30 FPS`, render `>=60 FPS`; p95 final `<50 ms` |
| 2 orientación/pulgar | 7 maniobras × 2 lados | normal, CMC, RMSE, inversión y códigos | inversión `<1%`; cero orientación no verificada aplicada |
| 3 rig | 5 poses × 2 lados | IK, límites, quaternion y recuperación | transforms inválidos `0`; teletransporte `0` |
| 4 identidad | cruce + contacto + 200/500 ms oclusión | asignaciones, costo, estados y swaps | cero swaps en fixture estándar; recuperación gradual |
| 5 perfil/capacidad | perfil válido + segmentos ausentes | round-trip, máscara y avatar | cero dedos fantasma; borrado verificable |
| 6 IA/equidad | dataset separado por grupo | accuracy, F1, loss, RMSE y gap con `n`/IC | comparación contra baseline; gap objetivo `<=5%` |
| 7 avanzada | benchmark reproducible | coste/beneficio contra baseline | complejidad justificada por métrica fallida |

## Safety Gate y auditoría

| Criterio | Aceptación |
|---|---|
| Transform inválido aplicado | 0 |
| Teletransporte | 0 |
| Unión inválida | congelamiento aislado |
| Recuperación | gradual, sin salto |
| Jitter estático | `<1–2° RMS` |
| Tracking / render | `≥30 / ≥60 FPS` |
| Detección | todo evento mediante números/códigos, sin revisión visual obligatoria |

La implementación registra `AuditSnapshotV1` con frame, etapa, unión, score,
severidad, estado, acción y código. La auditoría por reglas es primera fase;
Mahalanobis y autoencoder quedan posteriores. Los resultados sintéticos no se
presentan como prueba de cámara real.

## Regla de capas

MAD puede marcar y reparar `ValidatedFrame`/`RenderState`; nunca modifica
`RawFrame`, grabación ni `MotionFrameV2` de captura. Segmentos ausentes se
representan mediante `CapabilityMask` externo; el vector 152D conserva forma
numérica fija y el clasificador ignora características enmascaradas.
