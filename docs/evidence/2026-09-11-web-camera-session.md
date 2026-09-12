# Sesión asistida de cámara web — 2026-09-11

## Entorno

- visor: `avatar_viewer/index.html?standalone=1`
- navegador: Codex In-app Browser
- viewport observado: `1280×900`
- dispositivo y resolución de cámara: no registrados
- iluminación: interior; condición exacta no registrada
- video guardado: no

## Observaciones

| Prueba | Evidencia observada | Resultado |
|---|---|---|
| estática | ambas manos visibles durante 5 s; `Pose sí`, `I/D sí`, `Vector 152`, `Q 81%`, `16 FPS` | OK visual; sin jitter evidente en snapshot |
| pulgar | cambio de manos abiertas a configuración flexionada con pulgares; `Vector 152`, `Q 80–81%` | movimiento visible; lado individual no medido numéricamente |
| oclusión | una mano quedó visible; tracking y avatar continuaron | continuidad visual; oclusión estricta requiere mantener mano fuera de cuadro durante lectura |
| pérdida | después de sacar manos del tracking: `I/D no`, `Vector 152`, `Q 70%`; avatar pasó a reposo | OK |
| recuperación | ambas manos regresaron: `I/D sí`, `Vector 152`, `Q 74%` | OK |
| grabación | `Grabar 32` completó `32/32`; `secuencia lista`; `Q 80%` | OK |
| replay | `Repetir` ejecutó y cambió postura del avatar sin error visible | OK |
| exportación | botón `JSON` ejecutado con cámara todavía `Activa`, `Vector 152`, sin error JS | acción OK; ruta de descarga no registrada |

## Lectura

La ruta web funciona con cámara física en esta sesión: MediaPipe detectó pose,
produjo el contrato de `152` valores, perdió y recuperó manos sin detener el
visor, y completó grabación/replay. FPS observado varió entre `16` y `30`, por
lo que queda como métrica dependiente de equipo, no como garantía universal.

La prueba no demuestra todavía RMSE de pulgar, jitter RMS, latencia p95 ni
swap-rate. Esas métricas requieren captura de landmarks/timestamps y protocolo
repetido con dispositivo identificado.
