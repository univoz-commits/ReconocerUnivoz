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

La transición de superficie palma/dorso y el cambio de identidad son reglas
distintas: la superficie puede confirmarse con dos muestras consistentes; el
lado físico requiere tres frames consecutivos con ventaja de costo `>=0.15`.
Durante cualquier ambigüedad se conserva último estado válido.

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

Resolver asignación uno-a-uno y rechazar costos sobre umbral. Para dos manos,
el matching exhaustivo 2×2 actual es suficiente y tiene el mismo resultado que
Hungarian. No agregar Hungarian mientras no existan más tracks o una regresión
medida. Un cambio de identidad requiere tres frames consecutivos con ventaja de
costo `>=0.15`; una detección ambigua no se asigna.

## Predicción

Para oclusión, un Kalman lineal de velocidad constante puede usar:

```text
s = [posición, velocidad]
posición_t = posición_prev + velocidad_prev × dt
velocidad_t = velocidad_prev
```

La confianza debe aumentar el ruido de medición cuando cae. Aplicarlo primero a
muñeca/track y a predicción de oclusión; no usarlo como único filtro de dedos en
movimientos rápidos. Guardar estado y covarianza solo en memoria.

## Margen de gracia

Política inicial:

| Pérdida | Acción |
|---:|---|
| 0–100 ms | conservar última pose |
| 100–300 ms | predecir y bajar confianza |
| 300–500 ms | transición parcial a reposo |
| >500 ms | liberar track y reiniciar suavemente |

Implementación actual predice hasta 300 ms, mezcla hacia reposo entre 300 y
500 ms y libera el track después de 500 ms. Esta es también la política objetivo
del baseline; ajustar solo con medición de cámara y registrar cada transición.

## Reaparición

No teletransportar. Mezclar estado predicho y detección:

```text
estado = slerp(predicho, detectado, alpha_recovery)
alpha_recovery aumenta gradualmente
```

Validar longitud ósea y lado antes de aceptar plenamente.
