# Roadmap por fases

## Principio

Estabilizar entrada antes de entrenar modelos. Cada fase debe producir
evidencia independiente y conservar `MotionFrameV2` 152D.

## Fase 0 — baseline y telemetría

**Salida:** métricas de cámara y diagnóstico reproducible.

- timestamps de captura, inferencia y render;
- confianza y estados de mano;
- frames inválidos, oclusiones y swaps;
- jitter y pérdida sin guardar video;
- fixture sintético para repetir casos.

## Fase 1 — validación y filtrado

**Salida:** menos saltos sin latencia excesiva.

- gating de confianza;
- longitudes óseas calibradas;
- MAD y reparación robusta;
- One Euro por posición/ángulo;
- límites de salto y métricas.

La rama ya tiene validación geométrica, MAD, One Euro y rate limit visual.
Falta medir con grabaciones reales cuánto reducen jitter y qué latencia agregan
frente al baseline.

## Fase 2 — palma y pulgar

**Salida:** signo estable y movimiento del pulgar plausible.

- marco `W,5,9,17`;
- signo por lado y CMC;
- neutral y rango calibrados;
- histéresis;
- eje local VRM.

La rama ya tiene una implementación parcial/funcional y tests geométricos;
cámara debe confirmar que no falla con palma, dorso y giro.

## Fase 3 — rig anatómico

**Salida:** brazos sin estiramiento ni inversión.

- IK two-bone;
- polo y continuidad de codo;
- cuaterniones;
- límites y twist clamp;
- recuperación sin teletransporte.

Gran parte ya está implementada en visor; mantener pruebas sintéticas.

## Fase 4 — tracking y oclusión

**Salida:** identidad estable durante cruces y pérdidas.

- tracks explícitos;
- costo posición/velocidad/orientación;
- Hungarian solo si matching actual no basta;
- Kalman para predicción;
- gracia y recuperación progresiva.

## Fase 5 — calibración antropométrica

**Salida:** parámetros locales y adaptación de avatar.

- rutina guiada;
- medianas de longitudes;
- signos y rangos de pulgar;
- mapeo usuario → VRM;
- configuración local borrable.

## Fase 6 — features e IA

**Salida:** mejora medida de clasificación.

- `SemanticFrame`;
- ángulos, distancias y velocidades normalizadas;
- DTW/SVM/kNN con dataset real;
- umbrales recalibrados;
- comparación con baseline y matriz de confusión.

## Fase 7 — módulos avanzados

Activar solo si métricas justifican coste:

- Huber/RANSAC para optimización;
- EKF/UKF;
- pose lifting;
- TCN/LSTM/Transformer;
- MANO;
- profundidad o cámaras múltiples.

## Gates

No avanzar si:

- contrato 32×152 se rompe;
- tests de golden fallan;
- cámara aún muestra swaps no diagnosticados;
- no hay baseline de comparación;
- una mejora reduce jitter pero agrega latencia inaceptable.
