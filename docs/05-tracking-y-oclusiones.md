# Tracking, identidad y oclusiones

## Identidad de manos

No confiar únicamente en `handedness` ni en mitad izquierda/derecha de imagen.
Combinar:

1. muñeca de pose corporal;
2. trayectoria temporal;
3. orientación y dirección del pulgar;
4. etiqueta de MediaPipe solo como evidencia;
5. voto temporal antes de cambiar lado.

Una mano desconocida sin evidencia suficiente debe quedar sin asignar. Inventar
lado contamina avatar, muestras y clasificador.

## Estado de track

```text
TENTATIVE → TRACKING → OCCLUDED → LOST
```

Datos mínimos:

```text
id, side, posición, velocidad, orientación,
confianza, lastSeen, lostFrames, estado
```

## Asociación

La solución futura puede usar costo:

```text
C = 0.45 posición
  + 0.20 velocidad
  + 0.20 orientación
  + 0.10 lado anatómico
  + 0.05 confianza
```

Resolver asignación uno-a-uno y rechazar costos sobre umbral. Para dos manos
el código actual ya hace matching acotado y conserva identidad temporal; una
implementación Hungarian completa queda para cuando haya más tracks, detección
ruidosa o evidencia de regresión.

## Predicción

Para oclusión, un Kalman constante-velocidad puede usar:

```text
s = [posición, velocidad]
posición_t = posición_prev + velocidad_prev × dt
velocidad_t = velocidad_prev
```

La confianza debe aumentar el ruido de medición cuando cae. No usar Kalman
como único modelo de dedos en movimientos rápidos.

## Margen de gracia

Política inicial:

| Pérdida | Acción |
|---:|---|
| 0–100 ms | conservar última pose |
| 100–300 ms | predecir y bajar confianza |
| 300–500 ms | transición parcial a reposo |
| >500 ms | liberar track y reiniciar suavemente |

El visor actual usa un margen de reposo de aproximadamente 250 ms y estado
obsoleto de aproximadamente 450 ms. Ajustar con cámara, no por intuición.

## Reaparición

No teletransportar. Mezclar estado predicho y detección:

```text
estado = slerp(predicho, detectado, alpha_recovery)
alpha_recovery aumenta gradualmente
```

Validar longitud ósea y lado antes de aceptar plenamente.
