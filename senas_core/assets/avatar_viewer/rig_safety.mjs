const DEFAULT_MAX_AGE_MS = 200;
const DEFAULT_MAX_SKEW_MS = 120;
const DEFAULT_MAX_ANGULAR_VELOCITY = 18;

const finite = (value) => Number.isFinite(Number(value));
const clone = (value) => Array.isArray(value) ? value.slice() : value;
const cloneResult = (result) => ({
  ...result,
  value: clone(result.value),
  quaternion: clone(result.quaternion),
  anomalies: result.anomalies.slice(),
});

function finiteArray(value, length = null) {
  return Array.isArray(value) && (length == null || value.length === length) &&
    value.every(finite);
}

function normalizeQuaternion(value) {
  if (!finiteArray(value, 4)) return null;
  const norm = Math.hypot(...value.map(Number));
  if (!Number.isFinite(norm) || norm < 1e-8 || norm > 2) return null;
  return value.map((item) => Number(item) / norm);
}

export function quaternionFromEuler(rotation) {
  if (!finiteArray(rotation, 3)) return null;
  const [x, y, z] = rotation.map(Number);
  const cx = Math.cos(x / 2), sx = Math.sin(x / 2);
  const cy = Math.cos(y / 2), sy = Math.sin(y / 2);
  const cz = Math.cos(z / 2), sz = Math.sin(z / 2);
  return normalizeQuaternion([
    sx * cy * cz - cx * sy * sz,
    cx * sy * cz + sx * cy * sz,
    cx * cy * sz - sx * sy * cz,
    cx * cy * cz + sx * sy * sz,
  ]);
}

function quaternionDot(a, b) {
  return a && b ? a.reduce((sum, value, index) => sum + value * b[index], 0) : 1;
}

function quaternionAngle(a, b) {
  return 2 * Math.acos(Math.max(-1, Math.min(1, Math.abs(quaternionDot(a, b)))));
}

function interpolate(a, b, progress) {
  if (!Array.isArray(a) || !Array.isArray(b)) return clone(b);
  return a.map((value, index) => value + (b[index] - value) * progress);
}

function interpolateQuaternion(a, b, progress) {
  if (!Array.isArray(a) || !Array.isArray(b)) return b?.slice() ?? null;
  const output = a.map((value, index) =>
    value + (b[index] - value) * progress);
  const norm = Math.hypot(...output);
  return norm > 1e-8 ? output.map((value) => value / norm) : b.slice();
}

function defaultLimits(value) {
  return {
    min: Array(value.length).fill(-Math.PI),
    max: Array(value.length).fill(Math.PI),
  };
}

/**
 * Numeric guard between MotionFrame and VRM writes.
 * It never mutates a transform. Caller applies only returned `value` when
 * `accepted` is true; rejected data stays frozen at last valid state.
 */
export function createRigSafetyGate(options = {}) {
  const maxAgeMs = Math.max(0, Number(options.maxAgeMs ?? DEFAULT_MAX_AGE_MS));
  const maxSourceSkewMs = Math.max(
    0, Number(options.maxSourceSkewMs ?? DEFAULT_MAX_SKEW_MS));
  const maxAngularVelocityRadS = Math.max(
    0, Number(options.maxAngularVelocityRadS ?? DEFAULT_MAX_ANGULAR_VELOCITY));
  const boneLengthTolerance = Math.max(
    0, Number(options.boneLengthTolerance ?? .15));
  const recoveryFrames = Math.max(1, Math.round(
    Number(options.recoveryFrames ?? 3)));
  const minConfidence = options.minConfidence == null
    ? null : Math.max(0, Math.min(1, Number(options.minConfidence)));
  const states = new Map();

  const stateFor = (jointId) => {
    if (!states.has(jointId)) {
      states.set(jointId, {
        state: 'VALID',
        value: null,
        quaternion: null,
        timestampMs: null,
        frameId: null,
        inputFrameId: null,
        inputTimestampMs: null,
        handId: null,
        parentId: null,
        recoveryStart: null,
        recoveryQuaternionStart: null,
        recoveryStep: 0,
        lastResult: null,
      });
    }
    return states.get(jointId);
  };

  const check = (candidate = {}) => {
    const jointId = String(candidate.jointId ?? 'unknown');
    const state = stateFor(jointId);
    const frameId = candidate.frameId;
    const timestampMs = Number(candidate.timestampMs);
    const nowMs = candidate.nowMs == null
      ? timestampMs : Number(candidate.nowMs);

    if (state.lastResult && state.inputFrameId === frameId &&
        state.inputTimestampMs === timestampMs) {
      return cloneResult(state.lastResult);
    }

    const fail = (code, details = {}) => {
      state.state = 'FROZEN';
      state.recoveryStart = clone(state.value);
      state.recoveryQuaternionStart = clone(state.quaternion);
      state.recoveryStep = 0;
      const result = {
        accepted: false,
        applied: false,
        transformValid: state.value != null,
        state: state.state,
        action: 'freeze_local',
        code,
        anomalies: [code],
        value: clone(state.value),
        quaternion: clone(state.quaternion),
        jointId,
        frameId,
        timestampMs,
        ...details,
      };
      state.inputFrameId = frameId;
      state.inputTimestampMs = timestampMs;
      state.lastResult = result;
      options.onAudit?.({
        frame: frameId,
        timestampMs,
        stage: 'safety_gate',
        joint: jointId,
        score: 0,
        severity: 'error',
        state: state.state,
        action: result.action,
        code,
      });
      return cloneResult(result);
    };

    if (!finite(timestampMs) || (state.timestampMs != null &&
        timestampMs < state.timestampMs) || (state.frameId != null &&
        finite(frameId) && finite(state.frameId) && frameId < state.frameId)) {
      return fail('stale_frame');
    }
    if (!finite(nowMs) || nowMs - timestampMs > maxAgeMs) {
      return fail('stale_frame');
    }
    if (finite(candidate.sourceSkewMs) &&
        Math.abs(Number(candidate.sourceSkewMs)) > maxSourceSkewMs) {
      return fail('stage_desync');
    }
    if (minConfidence != null && finite(candidate.confidence) &&
        Number(candidate.confidence) < minConfidence) {
      return fail('low_confidence');
    }
    if (candidate.expectedHandId != null &&
        String(candidate.handId ?? '') !== String(candidate.expectedHandId)) {
      return fail('hand_identity_swap');
    }
    if (state.handId != null && candidate.handId != null &&
        String(candidate.handId) !== state.handId) {
      return fail('hand_identity_swap');
    }
    if (state.parentId != null && candidate.parentId != null &&
        String(candidate.parentId) !== state.parentId) {
      return fail('parent_frame_mismatch');
    }

    const hasRotation = candidate.rotation != null;
    const value = hasRotation ? candidate.rotation.map(Number) : [0, 0, 0];
    if (hasRotation && !finiteArray(value, 3)) {
      return fail('non_finite_transform');
    }

    let quaternion = candidate.quaternion == null
      ? quaternionFromEuler(value)
      : normalizeQuaternion(candidate.quaternion);
    if (!quaternion) return fail('invalid_quaternion');

    const anomalies = [];
    if (state.quaternion && quaternionDot(state.quaternion, quaternion) < 0) {
      quaternion = quaternion.map((item) => -item);
      anomalies.push('quaternion_flip');
    }

    const limits = candidate.jointLimits ?? options.jointLimits;
    if (limits) {
      const resolved = {
        min: (limits.min ?? defaultLimits(value).min).map(Number),
        max: (limits.max ?? defaultLimits(value).max).map(Number),
      };
      if (value.some((item, index) => !finite(resolved.min[index]) ||
          !finite(resolved.max[index]) || item < resolved.min[index] ||
          item > resolved.max[index])) {
        return fail('joint_limit_violation', {anomalies});
      }
    }

    if (finite(candidate.referenceBoneLength) && finite(candidate.boneLength)) {
      const reference = Math.abs(Number(candidate.referenceBoneLength));
      const length = Math.abs(Number(candidate.boneLength));
      if (reference < 1e-8 || Math.abs(length - reference) / reference >
          boneLengthTolerance) {
        return fail('bone_length_drift', {anomalies});
      }
    }

    if (state.value != null && state.timestampMs != null &&
        timestampMs > state.timestampMs) {
      const dt = Math.max(.001, (timestampMs - state.timestampMs) / 1000);
      const delta = state.quaternion && quaternion
        ? quaternionAngle(state.quaternion, quaternion)
        : Math.max(...value.map((item, index) =>
          Math.abs(item - state.value[index])));
      if (delta > maxAngularVelocityRadS * dt + .02) {
        return fail('angular_velocity_exceeded', {anomalies});
      }
    }

    let output = value.slice();
    if (state.state === 'FROZEN' || state.state === 'RECOVERING') {
      if (state.state === 'FROZEN') {
        state.recoveryStart = clone(state.value) ?? value.slice();
        state.recoveryQuaternionStart = clone(state.quaternion) ?? quaternion.slice();
        state.recoveryStep = 0;
      }
      state.recoveryStep += 1;
      const progress = Math.min(1, state.recoveryStep / recoveryFrames);
      output = interpolate(state.recoveryStart, value, progress);
      quaternion = interpolateQuaternion(
        state.recoveryQuaternionStart, quaternion, progress);
      state.state = progress >= 1 ? 'VALID' : 'RECOVERING';
    } else {
      state.state = 'VALID';
    }
    state.value = output.slice();
    state.quaternion = quaternion.slice();
    state.timestampMs = timestampMs;
    state.frameId = frameId;
    state.inputFrameId = frameId;
    state.inputTimestampMs = timestampMs;
    if (candidate.handId != null) state.handId = String(candidate.handId);
    if (candidate.parentId != null) state.parentId = String(candidate.parentId);

    const result = {
      accepted: true,
      applied: true,
      transformValid: true,
      state: state.state,
      action: state.state === 'VALID' ? 'apply' : 'recover_gradual',
      code: null,
      anomalies,
      value: output.slice(),
      quaternion: quaternion.slice(),
      jointId,
      frameId,
      timestampMs,
    };
    state.lastResult = result;
    options.onAudit?.({
      frame: frameId,
      timestampMs,
      stage: 'safety_gate',
      joint: jointId,
      score: anomalies.length ? .8 : 1,
      severity: anomalies.length ? 'warn' : 'ok',
      state: state.state,
      action: result.action,
      code: anomalies[0] ?? null,
    });
    return cloneResult(result);
  };

  return {
    check,
    reset() {
      states.clear();
    },
    state(jointId) {
      const value = states.get(String(jointId));
      return value ? {
        state: value.state,
        value: clone(value.value),
        quaternion: clone(value.quaternion),
        timestampMs: value.timestampMs,
        frameId: value.frameId,
      } : null;
    },
  };
}
