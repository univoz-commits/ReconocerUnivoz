# Tracking por fases y medición implementable

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fijar un contrato técnico sin ambigüedades y cerrar los riesgos vitales de tracking, orientación y medición sin romper `MotionFrameV2`.

**Architecture:** Mantener MediaPipe como detector. Separar `raw`, `validated`, `render` y `semantic`; reparar outliers únicamente en `render`; conservar captura/IA raw. Usar un marco canónico de palma con CMC para orientación y métricas numéricas acotadas para evaluar cada fase.

**Tech Stack:** Flutter/Dart, Kotlin/CameraX, MediaPipe Pose/Hand Landmarker, JavaScript/Three.js/VRM, Node test runner.

**Spec:** `/home/javier-karim/Descargas/informe_tecnico_avatar_vrm.pdf`, secciones 6, 7, 8, 9 y 11.

## Global Constraints

- `norm_version="2.0.0"` permanece sin cambios.
- `frame_dim=152` permanece sin cambios.
- `t_frames=32` permanece sin cambios.
- `MotionFrameV2` contiene números; capacidades y validez van fuera del vector.
- `raw`, grabación y entrada de IA no reciben reparación visual.
- Render usa último estado válido o predicción acotada; nunca aplica landmarks inválidos.
- Tracking de manos objetivo: `>=30 FPS`; pose puede ejecutarse a `~15 FPS` con cache temporal explícita.
- Render objetivo: `>=60 FPS`.
- Latencia final captura→avatar: `p95 <50 ms`; `p95 <=120 ms` solo es límite provisional de diagnóstico durante baseline.
- Cualquier orientación palma/dorso no verificable conserva último quaternion válido y genera código de auditoría.
- No guardar video ni imágenes persistentes.

---

### Task 1: Contrato documental único

**Files:**
- Modify: `docs/01-arquitectura-pipeline.md`
- Modify: `docs/03-estabilizacion-y-pulgar.md`
- Modify: `docs/05-tracking-y-oclusiones.md`
- Modify: `docs/07-roadmap.md`
- Modify: `docs/10-metricas-y-criterios.md`
- Modify: `docs/09-pruebas-camara.md`

**Interfaces:**
- Consumes: diagnóstico del PDF y estado comprobado de la rama.
- Produces: definiciones únicas para capas, FPS, latencia, MAD, orientación, identidad y máscaras de capacidad.

- [x] **Step 1: Definir capas y contrato 152D**

Documentar que `MotionFrameV2` sigue siendo vector numérico `32 × 152`; `CapabilityMask`, confianza, estado y auditoría son sidecars. Prohibir `null` y cero semántico para representar ausencia dentro del vector.

- [x] **Step 2: Fijar significado de FPS y latencia**

Definir `tracking_fps` como frames de manos aceptados por segundo, `pose_fps` por separado y `render_fps` como callbacks/render reales. Definir `L = rendered_at - captured_at`, reportando `p50/p95/p99`.

- [x] **Step 3: Fijar política de outlier y orientación**

Documentar `MAD` como detector; reparación solo en `Validated/Render`. Documentar `PalmFrameV2(W,I,M,P,C)`, conservación ante degeneración y rechazo de giro no verificable.

- [x] **Step 4: Actualizar estado real**

Marcar como parciales Kalman, perfil antropométrico, auditoría cross-layer y evidencia física. Marcar Hungarian como no requerido para dos tracks mientras matching 2×2 siga cubriendo el contrato.

- [x] **Step 5: Verificar términos ambiguos**

Ejecutar `rg -n "p95|120|50|MAD|152|30 FPS|Hungarian|Kalman|PalmFrame|CapabilityMask" docs` y eliminar contradicciones restantes.

### Task 2: Plan de medición por fases

**Files:**
- Modify: `docs/07-roadmap.md`
- Modify: `docs/10-metricas-y-criterios.md`
- Modify: `docs/09-pruebas-camara.md`

**Interfaces:**
- Consumes: timestamps monotónicos y estados numéricos del visor.
- Produces: evidencia mínima, gate y criterio de salida por fase.

- [ ] **Step 1: Fase 0 baseline**

Medir 300 frames por dispositivo: input, manos, pose, proceso, render, drops, inválidos, skew y latencia. Guardar solo JSON numérico.

- [ ] **Step 2: Fase 1 rendimiento**

Comparar cámara real con filtros apagados/encendidos. Salida: `tracking_fps >=30`, `render_fps >=60`, `latency_p95 <50 ms` o diagnóstico provisional `<=120 ms`.

- [ ] **Step 3: Fase 2 orientación/pulgar**

Probar izquierda/derecha, palma, dorso, giro, oclusión y recuperación. Salida: `inversion_rate <1%`, cero transformaciones inválidas aplicadas y cero saltos no explicados.

- [ ] **Step 4: Fase 3 identidad/oclusión**

Probar cruce, contacto, una mano, 200 ms y 500 ms de oclusión. Salida: cero swaps reproducibles en fixture estándar, recuperación gradual y ningún duplicado.

- [ ] **Step 5: Fase 4 perfil/capacidad**

Validar round-trip local, máscara de segmentos ausentes y avatar sin dedos fantasma. Salida: dataset sintético y sesión real por grupo.

- [ ] **Step 6: Fase 5 auditoría/IA**

Reportar accuracy, F1, loss, RMSE de pulgar, gap por subgrupo con `n` e intervalo de confianza. No activar modelos avanzados sin comparación contra baseline.

Estado: estas seis casillas describen ejecución física pendiente; el protocolo,
los campos y los gates ya quedaron documentados en `docs/07-roadmap.md`,
`docs/09-pruebas-camara.md` y `docs/10-metricas-y-criterios.md`.

### Task 3: Regresiones de orientación y MAD

**Files:**
- Modify: `senas_core/tools/rig-tests/rig_tracking.test.mjs`
- Modify: `senas_core/tools/rig-tests/rig_math.test.mjs`
- Modify: `senas_core/assets/avatar_viewer/rig_tracking.mjs`
- Modify: `senas_core/assets/avatar_viewer/rig_math.mjs`

**Interfaces:**
- Consumes: 21 landmarks MediaPipe y frames numéricos 152D.
- Produces: `palmFrameV2`, transición segura de superficie y reparación visual observable en diagnóstico.

- [x] **Step 1: Escribir test rojo de CMC**

Construir manos izquierda/derecha con `W=0`, `I=5`, `M=9`, `P=17`, `C=1`; exigir `dot(C-W, radial)>0` y normal finita.

- [x] **Step 2: Ejecutar test rojo**

Ejecutar `cd senas_core/tools/rig-tests && node --test rig_tracking.test.mjs`; confirmar fallo por ausencia de corrección CMC.

- [x] **Step 3: Escribir test rojo de MAD render-only**

Inyectar spike aislado en posición corporal; exigir raw intacto, render retenido/reparado y `madOutliers` registrado.

- [x] **Step 4: Ejecutar test rojo**

Ejecutar `node --test rig_math.test.mjs`; confirmar fallo en reparación observable.

- [x] **Step 5: Implementar mínimo**

Exportar marco canónico con CMC y usarlo para validar transición; agregar reparación solo a salida render cuando MAD y salto aislado coincidan, conservando raw.

- [x] **Step 6: Ejecutar tests verdes**

Ejecutar ambos archivos y luego `npm test` dentro de `senas_core/tools/rig-tests`.

### Task 4: Integrar métricas en loop vivo

**Files:**
- Modify: `senas_core/assets/avatar_viewer/index.html`
- Modify: `senas_core/assets/avatar_viewer/rig_metrics.mjs`
- Test: `senas_core/tools/rig-tests/rig_metrics.test.mjs`

**Interfaces:**
- Consumes: timestamp de captura, inicio/fin de proceso y timestamp del frame aplicado al render.
- Produces: `RigPerformanceMetricsV1` visible/exportable con etapas y `latency_ms` p50/p95/p99.

- [x] **Step 1: Agregar test de frame aplicado una sola vez**

Registrar el mismo source timestamp en dos callbacks de render y exigir una sola muestra de latencia.

- [x] **Step 2: Ejecutar test rojo**

Ejecutar `node --test rig_metrics.test.mjs`; confirmar que la API actual no deduplica por source timestamp.

- [x] **Step 3: Implementar deduplicación e integración**

Instanciar métricas al iniciar cámara; registrar `capture`, `pose`, `hands`, `process`, `render`; marcar frame aplicado al primer render posterior a cada `frameVivoSourceFrameId`; mostrar resumen junto al panel actual.

- [x] **Step 4: Ejecutar test verde**

Ejecutar `node --test rig_metrics.test.mjs` y verificar que la UI no duplica frames a 60 FPS.

### Task 5: Verificación de entrega

**Files:**
- No crear cambios adicionales.

**Interfaces:**
- Consumes: documentación, tests, diff y salida de comandos.
- Produces: estado de cada fase, riesgos pendientes y evidencia reproducible.

- [x] **Step 1: Ejecutar suite completa**

Ejecutar `./scripts/univoz.sh test` desde la raíz del repositorio.

- [x] **Step 2: Auditar diff**

Ejecutar `git diff --check`, `git status --short` y revisar que no se hayan revertido cambios previos.

- [x] **Step 3: Reportar límites**

Separar tests sintéticos de cámara real. No afirmar 30/60 FPS, latencia ni orientación perfecta sin evidencia física.
