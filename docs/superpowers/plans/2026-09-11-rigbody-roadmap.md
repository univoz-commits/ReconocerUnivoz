# RigBody y reconocimiento de señas Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Mejorar estabilidad, coherencia anatómica y validación de cámara manteniendo `MotionFrameV2` en 32 frames × 152 valores.

**Architecture:** Mantener MediaPipe y separar raw, validado, suavizado, semántico y render. Aplicar primero validación/filtros; después tracking, calibración y features, con metadatos fuera del vector canónico.

**Tech Stack:** Flutter/Dart, Kotlin/CameraX, MediaPipe Pose/Hand Landmarker, WebView/Three.js/VRM, Python, DTW, AI Engine opcional, Node test runner.

**Spec:** `docs/superpowers/specs/2026-09-11-rigbody-reconocimiento-design.md`

## Global Constraints

- `norm_version="2.0.0"` debe mantenerse.
- `frame_dim=152` debe mantenerse.
- `t_frames=32` debe mantenerse.
- Preview no alimenta captura ni IA.
- No guardar video.
- No revertir modificaciones previas del usuario.
- Validar cambios con tests automatizados y protocolo de cámara.

---

### Task 1: Baseline y contrato

**Files:**
- Create: `docs/10-metricas-y-criterios.md`
- Test: `senas_core/test/motion_contract_test.dart`
- Test: `senas_core/test/sign_norm_test.dart`

**Interfaces:**
- Consumes: `MotionSequenceV2.fromFrames`, `normalizeFrame`.
- Produces: evidencia de `32 × 152`, `2.0.0`, finitud y golden.

- [ ] **Step 1: Run baseline**

```bash
./scripts/univoz.sh test
```

Expected: Flutter tests, analyze, Python, AI Engine y RigBody JS pasan.

- [ ] **Step 2: Verify dimensions**

```bash
rg -n "kFrameDim|kTFrames|NORM_VERSION|FRAME_DIM" senas_core/lib senas_core/tools backend/ai-engine
```

Expected: producers and consumers agree on 152, 32 and `2.0.0`.

- [ ] **Step 3: Run focused contract tests**

```bash
cd senas_core
dart test test/motion_contract_test.dart test/sign_norm_test.dart
```

Expected: PASS; no dimension or version drift.

### Task 2: Robust outlier fixture

**Files:**
- Create: `senas_core/test/fixtures/landmark_noise_cases.json`
- Modify: `senas_core/assets/avatar_viewer/index.html`
- Test: `senas_core/tools/rig-tests/motion.test.mjs`

**Interfaces:**
- Consumes: frame arrays of 152 values and timestamp in milliseconds.
- Produces: deterministic outlier decision and render repair without changing capture vector.

- [ ] **Step 1: Add regression test**

```javascript
test('single-frame spike preserves presence and does not teleport rig', () => {
  const stable = Array(152).fill(0);
  stable[30] = 1;
  stable[31] = 1;
  const spike = stable.slice();
  spike[24] = 5;
  const c = smoothingRuntime();
  c.suavizarFrameWeb(stable, 0);
  const out = c.suavizarFrameWeb(spike, 33);
  assert.equal(out[30], 1);
  assert.equal(out[31], 1);
  assert.ok(out[24] < 1);
});
```

- [ ] **Step 2: Run focused test**

```bash
cd senas_core/tools/rig-tests
npm test -- --test-name-pattern="single-frame spike"
```

Expected: PASS with current low-pass; preserve as regression evidence.

- [ ] **Step 3: Add MAD**

Use window `N=5`, `epsilon=1e-6` and threshold `z>3.5`. Keep raw values for
diagnostics; repair render state only until feature-version impact is reviewed.

- [ ] **Step 4: Run all JS tests**

```bash
npm test
```

Expected: all tests pass.

### Task 3: One Euro comparison

**Files:**
- Modify: `senas_core/assets/avatar_viewer/index.html`
- Test: `senas_core/tools/rig-tests/motion.test.mjs`
- Modify: `docs/03-estabilizacion-y-pulgar.md`

**Interfaces:**
- Consumes: scalar/vector sample, timestamp ms and confidence `[0,1]`.
- Produces: render-only filtered value with bounded `dt`.

- [ ] **Step 1: Add failing filter test**

```javascript
test('low confidence lowers One Euro cutoff', () => {
  const low = new OneEuroFilter(1.0, 0.01, 1.0);
  const high = new OneEuroFilter(1.0, 0.01, 1.0);
  low.filter(0, 0, 0.2);
  high.filter(0, 0, 1.0);
  const lowValue = low.filter(1, 33, 0.2);
  const highValue = high.filter(1, 33, 1.0);
  assert.ok(lowValue < highValue);
});
```

- [ ] **Step 2: Confirm failure**

```bash
npm test -- --test-name-pattern="low confidence lowers"
```

Expected: FAIL until `OneEuroFilter` exists.

- [ ] **Step 3: Implement filter**

Clamp `dt` to `1–200 ms`, confidence to `0–1`, reset on session/replay and apply
only to scalar coordinates or local angles. Keep quaternions on shortest-path
continuity plus SLERP/NLERP.

- [ ] **Step 4: Verify**

```bash
npm test
```

Expected: PASS; capture still emits 152D.

### Task 4: Palm frame and thumb

**Files:**
- Modify: `senas_core/assets/avatar_viewer/index.html`
- Test: `senas_core/tools/rig-tests/motion.test.mjs`
- Modify: `docs/09-pruebas-camara.md`

**Interfaces:**
- Consumes: 21 hand landmarks, side and previous palm frame.
- Produces: stable palm axes and local thumb angles.

- [ ] **Step 1: Add left/right synthetic cases**

```javascript
for (const side of ['left', 'right']) {
  test(side + ' palm frame points radial axis toward CMC', () => {
    const palm = buildPalmFrameForTest(side);
    assert.ok(Number.isFinite(palm.normal.length()));
    assert.ok(palm.cmc.clone().sub(palm.wrist).dot(palm.radial) > 0);
  });
}
```

- [ ] **Step 2: Run focused test**

```bash
npm test -- --test-name-pattern="palm frame"
```

Expected: FAIL if helper/sign logic is absent.

- [ ] **Step 3: Implement degeneracy and hysteresis**

Retain previous frame when the cross product is degenerate, require several
consistent side votes, clamp local thumb angle and preserve CMC/MCP/IP motion.

- [ ] **Step 4: Run all tests**

```bash
npm test
```

Expected: PASS for both sides and existing thumb cases.

### Task 5: IK and quaternion continuity

**Files:**
- Modify: `senas_core/assets/avatar_viewer/index.html`
- Test: `senas_core/tools/rig-tests/motion.test.mjs`
- Modify: `docs/04-rig-ik-y-avatar.md`

**Interfaces:**
- Consumes: shoulder, wrist target, elbow pole and avatar bone lengths.
- Produces: reachable elbow/wrist pose with bounded rotations.

- [ ] **Step 1: Add shortest-path test**

```javascript
test('quaternion continuity selects shortest representation', () => {
  const previous = new THREE.Quaternion(1, 0, 0, 0);
  const next = new THREE.Quaternion(-1, 0, 0, 0);
  const fixed = next.clone();
  if (previous.dot(fixed) < 0) fixed.multiplyScalar(-1);
  assert.ok(previous.dot(fixed) > 0);
});
```

- [ ] **Step 2: Run focused test**

```bash
npm test -- --test-name-pattern="shortest representation"
```

Expected: PASS after continuity is covered.

- [ ] **Step 3: Verify reachable targets**

Use targets inside, at and beyond reach. Assert upper/lower lengths remain
within tolerance and both solve against the same clamped wrist target.

- [ ] **Step 4: Run all tests**

```bash
npm test
```

Expected: PASS, no synthetic codo inversion or overextension.

### Task 6: Camera-assisted validation

**Files:**
- Modify: `docs/09-pruebas-camara.md`
- Create: `docs/evidence/README.md`

**Interfaces:**
- Consumes: live camera session and user observations.
- Produces: manual evidence log; no video by default.

- [ ] **Step 1: Start viewer**

```bash
./scripts/univoz.sh web
```

Expected: viewer at `http://127.0.0.1:8080`.

- [ ] **Step 2: Execute camera sequence**

Run static hold, thumb open/closed, palm/dorsum, fist, wrist rotation, hand
crossing, 200 ms and 500 ms occlusion, leave/re-enter and fast movement.

- [ ] **Step 3: Record facts**

Record device, browser, resolution, FPS, quality, perceived latency, losses,
swaps, thumb inversion and captured dimensions. Automated tests do not prove
camera behavior.

- [ ] **Step 4: Reproduce defects**

Add a minimal synthetic regression or precise evidence note before changing
production logic.

### Task 7: Final verification and branch handoff

**Files:**
- Modify: `docs/README.md`
- Modify: `docs/10-metricas-y-criterios.md`

**Interfaces:**
- Consumes: full test output, camera evidence and current git diff.
- Produces: truthful, navigable docs on `codex/rigbody-ai`.

- [ ] **Step 1: Run suite**

```bash
./scripts/univoz.sh test
```

Expected: all suites pass and Flutter analyze is clean.

- [ ] **Step 2: Check Markdown links**

```bash
python3 - <<'PY'
from pathlib import Path
import re

for path in Path("docs").rglob("*.md"):
    for target in re.findall(r"\]\(([^)#]+)(?:#[^)]+)?\)", path.read_text()):
        if "://" not in target and not target.startswith("mailto:"):
            assert (path.parent / target).resolve().exists(), (path, target)
print("markdown links: ok")
PY
```

Expected: `markdown links: ok`.

- [ ] **Step 3: Inspect scope**

```bash
git status --short
git diff -- docs
```

Expected: documentation changes stay under `docs/`; prior user changes remain intact.

- [ ] **Step 4: Commit docs**

```bash
git add docs
git commit -m "docs: map rigbody stabilization roadmap"
```

Expected: commit exists only on `codex/rigbody-ai`; no merge to main.
