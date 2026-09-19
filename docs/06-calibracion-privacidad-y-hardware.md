# Calibración, privacidad y hardware

## Calibración por usuario

Rutina inicial de 10–20 segundos:

1. postura neutra;
2. brazos visibles;
3. palmas hacia cámara;
4. abrir/cerrar manos lentamente;
5. oposición de pulgar;
6. pronación/supinación suave, si aplica.

Estimar mediante mediana después de descartar outliers:

```text
shoulder_width
upper_arm_length
forearm_length
hand_length
palm_width
finger_lengths[5][3]
thumb_lengths[3]
```

Precomputar: pose de reposo VRM, longitudes, ejes, límites, signos y
transformaciones constantes. Calcular por frame: landmarks, confianza,
outliers, tracking, IK, cuaterniones y features.

La calibración actual de `RigCalibration` ya persiste escala, inversión Z,
ganancias de brazos, límites, sensibilidad, compensación de muñeca y conducta
ante pérdida. Eso es calibración de rig; todavía no es un pasaporte
antropométrico completo.

## Privacidad

- No guardar video.
- No crear identidad persistente a partir del rostro.
- Mantener calibración local, borrable y sin identificadores innecesarios.
- Guardar landmarks crudos solo por acción explícita.
- Separar diagnóstico de datos usados para entrenar.

“Embedding cinemático” significa parámetros agregados de movimiento y
proporción; no debe venderse como autenticación biométrica.

## Opciones futuras

| Tecnología | Beneficio | Coste/riesgo | Decisión |
|---|---|---|---|
| RGB + MediaPipe | multiplataforma y disponible | profundidad ambigua | base |
| ARCore Depth | profundidad auxiliar Android | compatibilidad variable | módulo opcional |
| ARKit/TrueDepth | precisión en dispositivos compatibles | no multiplataforma/WebView | profesional |
| RGB-D | volumen y profundidad | hardware e integración | avanzada |
| multicámara/estéreo | oclusiones y 3D | calibración compleja | profesional |
| MANO/pose lifting | coherencia y recuperación | modelo/licencia/coste | solo tras medir |

La prioridad es eliminar ruido y ambigüedad con geometría antes de sumar
hardware o modelos.
