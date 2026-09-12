# Métricas y criterios de aceptación

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

Reportar `p50`, `p95`, `p99`. Objetivo: `p95 < 50 ms`; si WebView no cumple,
evaluar mover inferencia a capa nativa.

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

| Fase | Evidencia mínima |
|---|---|
| 0 | log de timestamps y baseline |
| 1 | fixture con ruido/outliers + comparación jitter |
| 2 | pruebas izquierda/derecha y giro de mano |
| 3 | tests IK + límites y captura real |
| 4 | cruces/oclusiones reproducibles |
| 5 | JSON de calibración local round-trip |
| 6 | dataset separado, métricas y golden |
| 7 | benchmark que justifique complejidad |
