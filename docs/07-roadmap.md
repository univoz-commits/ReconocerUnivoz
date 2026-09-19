# Roadmap por fases

## Principio

Estabilizar entrada antes de entrenar modelos. Cada fase debe producir
evidencia independiente y conservar `MotionFrameV2` 152D. Estado `hecho`
significa código + test + evidencia requerida; código sin evidencia queda
`parcial`.

## Contrato no negociable

- Manos: `tracking_fps >=30`; Pose se reporta aparte y puede ser `~15 FPS`.
- Render: `render_fps >=60`.
- Latencia final: `p95 <50 ms`; `p95 <=120 ms` solo diagnóstico provisional.
- `MotionFrameV2`: numérico, finito, `32×152`, sin cambios de dimensión.
- Reparación MAD: solo `Validated/Render`; raw, grabación e IA permanecen
  intactos.
- Ausencia anatómica: `CapabilityMask` externo; nunca cero o `null` semántico
  dentro de 152D.

## Estado de ejecución

| Fase | Código/test | Evidencia física | Estado operativo |
|---|---|---|---|
| 0 baseline | telemetría Web y auditoría numérica | 300 frames por dispositivo | parcial |
| 1 validación/filtro | validación, MAD render-only, One Euro y gates | FPS, jitter y latencia reales | parcial |
| 2 palma/pulgar | `PalmFrameV2`, CMC y pruebas geométricas | 7 maniobras por lado | parcial |
| 3 rig | IK, límites, quaternion y Safety Gate | prueba en dispositivo | parcial |
| 4 identidad/oclusión | matching 2×2, histéresis de 3 frames y gracia | cruce/oclusión reales | parcial |
| 5 perfil/capacidad | no implementado | no ejecutado | pendiente |
| 6 IA/equidad | baseline existente; comparación nueva pendiente | dataset por grupo | pendiente |
| 7 avanzada | no activar sin métrica fallida | benchmark | bloqueada por gate |

`hecho` exige código, test y evidencia física de su fase. Hasta completar Fases
0–4, ningún `>=30 FPS`, `>=60 FPS`, `p95 <50 ms` o tasa de inversión se trata
como garantía de cámara.

## Fase 0 — baseline y telemetría

**Salida:** métricas de cámara y diagnóstico reproducible.

- timestamps de captura, inferencia y render;
- confianza y estados de mano;
- frames inválidos, oclusiones y swaps;
- jitter y pérdida sin guardar video;
- fixture sintético para repetir casos.

Estado: `AuditSnapshotV1` y buffer numérico de 45 s ya están en el visor; falta
evidencia prolongada en Android. Gate: 300 frames por dispositivo con JSON
numérico, timestamps, drops, skew y baseline sin filtro.

## Fase 1 — validación y filtrado

**Salida:** menos saltos sin latencia excesiva.

- gating de confianza;
- longitudes óseas calibradas;
- MAD como detector y reparación render-only condicionada por salto/geometría;
- One Euro por posición/ángulo;
- límites de salto y métricas.

La rama ya tiene validación geométrica, MAD, One Euro, rate limit visual y
Safety Gate por unión. Falta medir con captura real cuánto reducen jitter y qué
latencia agregan frente al baseline. Gate: manos `>=30 FPS`, render `>=60 FPS`
y latencia final `p95 <50 ms`.

## Fase 2 — palma y pulgar

**Salida:** signo estable y movimiento del pulgar plausible.

- marco canónico `PalmFrameV2(W,I,M,P,C)`;
- signo radial por lado y CMC;
- neutral y rango calibrados;
- histéresis;
- eje local VRM.

La rama ya tiene marco/guardia funcional, CMC compartido para tracking y muñeca,
y tests geométricos. Cámara debe confirmar palma, dorso y giro.

La ruta rápida de dedos usa `FingerRenderState` separado, sin doble suavizado,
con `fingerLag` objetivo p95 `≤66 ms`. Prueba sintética pasa; cámara real queda
pendiente.

## Fase 3 — rig anatómico

**Salida:** brazos sin estiramiento ni inversión.

- IK two-bone;
- polo y continuidad de codo;
- cuaterniones;
- límites y twist clamp;
- recuperación sin teletransporte.

Gran parte ya está implementada en visor; mantener pruebas sintéticas y
demostrar cero transforms inválidos aplicados en dispositivo.

## Fase 4 — tracking y oclusión

**Salida:** identidad estable durante cruces y pérdidas.

- tracks explícitos;
- costo posición/velocidad/orientación;
- matching exhaustivo 2×2 actual; Hungarian solo si aparecen más tracks o una
  regresión medida;
- Kalman para predicción;
- cambio de identidad solo tras 3 frames consecutivos con ventaja `>=0.15`;
- gracia y recuperación progresiva.

Gate: cero swaps en fixture estándar, ningún duplicado y recuperación gradual.

## Fase 5 — calibración antropométrica

**Salida:** parámetros locales y adaptación de avatar.

- rutina guiada;
- medianas de longitudes;
- signos y rangos de pulgar;
- `HandCapabilityModel` y `CapabilityMask` externos al vector;
- mapeo usuario → VRM;
- perfil versionado, consentimiento y configuración local borrable.

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

La evidencia sintética no sustituye evidencia física. Cada gate reporta
dispositivo, resolución, condiciones de luz y tamaño de muestra.
