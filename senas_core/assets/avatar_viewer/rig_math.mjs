const FRAME_DIM = 152;
const OFF_LOC_LEFT = 24;
const OFF_LOC_RIGHT = 27;
const OFF_PRES_LEFT = 30;
const OFF_PRES_RIGHT = 31;
const OFF_SHAPE_LEFT = 32;
const OFF_SHAPE_RIGHT = 92;

const clamp = (value, min = 0, max = 1) =>
  Math.max(min, Math.min(max, Number(value)));
const subtract = (a, b) => [a[0] - b[0], a[1] - b[1], a[2] - b[2]];
const length = (v) => Math.hypot(v[0], v[1], v[2]);
const unit = (v) => {
  const size = length(v);
  return size > 1e-8 ? v.map((x) => x / size) : null;
};
const dot = (a, b) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
const angle = (a, b) => {
  const ua = unit(a), ub = unit(b);
  if (!ua || !ub) return NaN;
  return Math.acos(clamp(dot(ua, ub), -1, 1));
};

export function measureThumbPose(points) {
  if (!Array.isArray(points) || points.length < 17) return null;
  const values = points.map((p) => Array.isArray(p)
    ? [Number(p[0]), Number(p[1]), Number(p[2])]
    : [Number(p?.x), Number(p?.y), Number(p?.z)]);
  if (values.some((p) => p.some((v) => !Number.isFinite(v)))) return null;
  const s0 = values[0];
  const s1 = subtract(values[1], values[0]);
  const s2 = subtract(values[2], values[1]);
  const s3 = subtract(values[3], values[2]);
  const angles = [angle(s0, s1), angle(s1, s2), angle(s2, s3)];
  const distance = length(subtract(values[3], values[8]));
  if (!Number.isFinite(distance) || angles.some((v) => !Number.isFinite(v))) {
    return null;
  }
  return {distance, angles};
}

export function createThumbCalibration(open, closed, updatedAtMs = Date.now()) {
  if (!open || !closed || !Array.isArray(open.angles) ||
      !Array.isArray(closed.angles) || open.angles.length !== 3 ||
      closed.angles.length !== 3) {
    throw new TypeError('thumb calibration requires open and closed measurements');
  }
  if (!Number.isFinite(open.distance) || !Number.isFinite(closed.distance) ||
      Math.abs(open.distance - closed.distance) < .04) {
    throw new RangeError('thumb calibration poses are not distinct');
  }
  return {
    calibrated: true,
    openDistance: Number(open.distance),
    closedDistance: Number(closed.distance),
    openAngles: open.angles.map(Number),
    closedAngles: closed.angles.map(Number),
    updatedAtMs: Number(updatedAtMs) || 0,
  };
}

function progress(value, open, closed) {
  const span = closed - open;
  return Math.abs(span) < .03 ? null : clamp((value - open) / span);
}

export function solveThumbPose(measurement, calibration) {
  if (!measurement || !calibration) {
    return {closure: 0, flexions: [0, 0, 0], calibrated: false};
  }
  const closure = progress(
    measurement.distance,
    Number(calibration.openDistance),
    Number(calibration.closedDistance),
  );
  const globalClosure = closure == null ? 0 : closure;
  const maxima = [.85, 1, .75];
  const flexions = maxima.map((maximum, index) => {
    const joint = progress(
      Number(measurement.angles?.[index]),
      Number(calibration.openAngles?.[index]),
      Number(calibration.closedAngles?.[index]),
    );
    const mixed = joint == null ? globalClosure :
      clamp(globalClosure * .65 + joint * .35);
    return mixed * maximum;
  });
  return {
    closure: globalClosure,
    flexions,
    calibrated: calibration.calibrated === true,
    distance: measurement.distance,
    angles: measurement.angles.slice(),
  };
}

export function chooseThumbBoneAxis(beforeDistance, probes) {
  const before = Number(beforeDistance);
  if (!Number.isFinite(before) || !Array.isArray(probes)) return null;
  let best = null;
  for (const probe of probes) {
    if (!['x', 'y', 'z'].includes(probe?.axis) ||
        ![-1, 1].includes(Number(probe?.sign)) ||
        !Number.isFinite(Number(probe?.distance))) continue;
    const improvement = before - Number(probe.distance);
    if (!best || improvement > best.improvement) {
      best = {axis: probe.axis, sign: Number(probe.sign), improvement};
    }
  }
  if (!best || best.improvement <= 1e-5) return null;
  return {...best, improvement: Number(best.improvement.toFixed(12))};
}

export function createHandAngleFilter(size = 15, options = {}) {
  const count = Math.max(3, Number(size) || 15);
  const settings = {
    minCutoff: Math.max(.1, Number(options.minCutoff ?? 5)),
    beta: Math.max(0, Number(options.beta ?? .25)),
    dCutoff: Math.max(.1, Number(options.dCutoff ?? 1)),
    intentionalAlpha: clamp(options.intentionalAlpha ?? .92),
    intentionalThreshold: Math.max(0, Number(
      options.intentionalThreshold ?? .08)),
    jumpLimit: Math.max(.1, Number(options.jumpLimit ?? 1.2)),
  };
  let previous = null;
  let previousRaw = null;
  let previousTime = 0;
  let filters = [];
  let histories = [];

  const reset = () => {
    previous = null;
    previousRaw = null;
    previousTime = 0;
    filters = [];
    histories = [];
  };

  const filter = (angles, timestampMs, quality = 1) => {
    if (!Array.isArray(angles) || angles.length !== count) return null;
    const input = angles.map((value) => Number(value));
    if (input.some((value) => !Number.isFinite(value))) return null;
    const t = Number(timestampMs);
    if (!previous || !Number.isFinite(t) || t < previousTime) {
      previous = input.slice();
      previousRaw = input.slice();
      previousTime = Number.isFinite(t) ? t : 0;
      filters = input.map(() => createOneEuroFilter(settings));
      histories = input.map((value) => [value]);
      return {angles: input.slice(), diagnostics: {
        madOutliers: [], jumpRejectedChains: [], delayMs: 0,
        rawToFilteredRms: 0,
      }};
    }
    if (t === previousTime) {
      return {angles: previous.slice(), diagnostics: {
        madOutliers: [], jumpRejectedChains: [], delayMs: 0,
        rawToFilteredRms: 0,
      }};
    }

    const dtMs = clamp(t - previousTime, 1, 200);
    const output = previous.slice();
    const madOutliers = [];
    const jumpRejectedChains = [];
    const delays = [];
    const chains = Math.ceil(count / 3);
    for (let chain = 0; chain < chains; chain++) {
      const start = chain * 3;
      const end = Math.min(count, start + 3);
      let maximumJump = 0;
      for (let i = start; i < end; i++) {
        maximumJump = Math.max(maximumJump, Math.abs(input[i] - previousRaw[i]));
      }
      if (maximumJump > settings.jumpLimit) {
        jumpRejectedChains.push(chain);
        continue;
      }
      for (let i = start; i < end; i++) {
        if (madState(histories[i], input[i])) madOutliers.push(i);
        histories[i].push(input[i]);
        if (histories[i].length > 5) histories[i].shift();
        const intentional = Math.abs(input[i] - previous[i]) >=
          settings.intentionalThreshold;
        output[i] = filters[i].filter(input[i], t, quality, intentional);
        const velocity = Math.abs(input[i] - previousRaw[i]) / (dtMs / 1000);
        if (velocity > .01) {
          delays.push(Math.min(500,
            Math.abs(input[i] - output[i]) / velocity * 1000));
        }
      }
    }
    const error = output.reduce((sum, value, index) =>
      sum + (value - input[index]) ** 2, 0);
    previous = output;
    previousRaw = input;
    previousTime = t;
    return {angles: output.slice(), diagnostics: {
      madOutliers,
      jumpRejectedChains,
      delayMs: median(delays),
      rawToFilteredRms: Math.sqrt(error / count),
    }};
  };
  return {filter, reset};
}

/** Low-latency route for articulated finger angles. Shape XYZ stays raw. */
export function createFastFingerAngleFilter(size = 15) {
  return createHandAngleFilter(size, {
    minCutoff: 11,
    beta: .35,
    dCutoff: 1.5,
    intentionalAlpha: .98,
    intentionalThreshold: .045,
    jumpLimit: 1.6,
  });
}

/** t_avatar_90% - t_input_90%, deduplicated by source timestamp. */
export function measureFingerLag(samples, threshold = .9) {
  if (!Array.isArray(samples)) return 0;
  const unique = [];
  let lastTimestamp = null;
  for (const sample of samples) {
    const timestampMs = Number(sample?.timestampMs);
    if (!Number.isFinite(timestampMs) || timestampMs === lastTimestamp) continue;
    const input = Number(sample?.input);
    const avatar = Number(sample?.avatar);
    if (!Number.isFinite(input) || !Number.isFinite(avatar)) continue;
    unique.push({timestampMs, input, avatar});
    lastTimestamp = timestampMs;
  }
  const input90 = unique.find((sample) => sample.input >= threshold)?.timestampMs;
  const avatar90 = unique.find((sample) => sample.avatar >= threshold)?.timestampMs;
  return input90 == null || avatar90 == null ? 0 : avatar90 - input90;
}

function createOneEuroFilter({minCutoff, beta, dCutoff = 1, intentionalAlpha = 0}) {
  let initialized = false;
  let previous = 0;
  let previousRaw = 0;
  let previousVelocity = 0;
  let previousTime = 0;
  const alpha = (cutoff, dtMs) => {
    const dt = Math.max(1, dtMs) / 1000;
    const tau = 1 / (2 * Math.PI * Math.max(1e-6, cutoff));
    return 1 / (1 + tau / dt);
  };
  return {
    filter(value, timeMs, quality = 1, intentional = false) {
      const x = Number(value), t = Number(timeMs);
      if (!Number.isFinite(x) || !Number.isFinite(t)) return previous;
      if (!initialized) {
        initialized = true;
        previous = previousRaw = x;
        previousTime = t;
        return x;
      }
      const dtMs = clamp(t - previousTime, 1, 200);
      const rawVelocity = (x - previousRaw) / (dtMs / 1000);
      const derivativeAlpha = alpha(dCutoff, dtMs);
      const velocity = derivativeAlpha * rawVelocity +
        (1 - derivativeAlpha) * previousVelocity;
      const qualityFactor = .8 + .2 * clamp(quality);
      const cutoff = (minCutoff + beta * Math.abs(velocity)) * qualityFactor;
      const weight = Math.max(alpha(cutoff, dtMs),
        intentional ? intentionalAlpha : 0);
      const output = weight * x + (1 - weight) * previous;
      previous = output;
      previousRaw = x;
      previousVelocity = velocity;
      previousTime = t;
      return output;
    },
  };
}

function groupFor(index) {
  if (index === OFF_PRES_LEFT || index === OFF_PRES_RIGHT) return 'presence';
  if ((index >= OFF_LOC_LEFT && index < OFF_LOC_LEFT + 3) ||
      (index >= OFF_LOC_RIGHT && index < OFF_LOC_RIGHT + 3)) return 'wrist';
  if (index >= OFF_SHAPE_LEFT) return 'shape';
  return 'body';
}

function median(values) {
  if (!values.length) return 0;
  const sorted = values.slice().sort((a, b) => a - b);
  const middle = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[middle] :
    (sorted[middle - 1] + sorted[middle]) / 2;
}

function madState(history, value) {
  if (history.length < 4) return false;
  const center = median(history);
  const mad = median(history.map((x) => Math.abs(x - center)));
  const sigma = Math.max(1.4826 * mad, .005);
  return Math.abs(value - center) / sigma > 3.5;
}

export function createResponsiveRigFilter(options = {}) {
  const configs = {
    body: {minCutoff: 1.5, beta: .05, jump: 1.0, intentional: .08, alpha: .72},
    wrist: {minCutoff: 3, beta: .12, jump: 1.0, intentional: .06, alpha: .85},
    shape: {minCutoff: 5, beta: .25, jump: 2.0, intentional: .08, alpha: .92},
  };
  const deadbands = {
    body: Math.max(0, Number(options.deadbands?.body ?? .003)),
    wrist: Math.max(0, Number(options.deadbands?.wrist ?? .004)),
    shape: Math.max(0, Number(options.deadbands?.shape ?? 0)),
    presence: 0,
  };
  let previous = null;
  let previousRaw = null;
  let previousTime = 0;
  let filters = [];
  let histories = [];
  let jumpStreak = [];

  const emptyMotion = () => ({
    motionScore: 0,
    fingerMotionScore: 0,
    motionByGroup: {body: 0, wrist: 0, shape: 0, presence: 0},
    intentionalMotion: false,
    quiet: true,
  });
  const motionDiagnostics = (frame) => {
    if (!previousRaw) return emptyMotion();
    const sums = {body: 0, wrist: 0, shape: 0, presence: 0};
    const thresholds = {
      body: Math.max(deadbands.body * 2, configs.body.intentional),
      wrist: Math.max(deadbands.wrist * 2, configs.wrist.intentional),
      shape: configs.shape.intentional,
      presence: .5,
    };
    for (let i = 0; i < FRAME_DIM; i++) {
      const group = groupFor(i);
      const delta = Math.abs(Number(frame[i]) - previousRaw[i]);
      sums[group] += delta ** 2;
    }
    const motionByGroup = Object.fromEntries(Object.keys(sums).map((group) => {
      // Vector norm avoids one noisy coordinate turning whole body into motion.
      return [group, clamp(Math.sqrt(sums[group]) / thresholds[group])];
    }));
    // Presence flags describe detector availability, not user motion. Shape
    // has its own fast path; body score controls torso/arm deadband.
    const motionScore = Math.max(motionByGroup.body, motionByGroup.wrist);
    return {
      motionScore,
      fingerMotionScore: motionByGroup.shape,
      motionByGroup,
      intentionalMotion: motionScore >= .8,
      quiet: motionScore < .25,
    };
  };

  const reset = () => {
    previous = null;
    previousRaw = null;
    previousTime = 0;
    filters = [];
    histories = [];
    jumpStreak = [];
  };

  const setDeadbands = (next = {}) => {
    for (const group of ['body', 'wrist', 'shape']) {
      const value = Number(next[group]);
      if (Number.isFinite(value) && value >= 0) deadbands[group] = value;
    }
    return {...deadbands};
  };

  const filter = (frame, timestampMs, quality = 1) => {
    if (!Array.isArray(frame) || frame.length !== FRAME_DIM ||
        frame.some((value) => !Number.isFinite(Number(value)))) return null;
    const t = Number(timestampMs);
    if (!previous) {
      previous = frame.map(Number);
      previousRaw = frame.map(Number);
      previousTime = Number.isFinite(t) ? t : 0;
      filters = Array.from({length: FRAME_DIM}, (_, index) => {
        const group = groupFor(index);
        return group === 'presence' ? null : createOneEuroFilter({
          minCutoff: configs[group].minCutoff,
          beta: configs[group].beta,
          intentionalAlpha: configs[group].alpha,
        });
      });
      histories = frame.map((value) => [Number(value)]);
      jumpStreak = Array(FRAME_DIM).fill(0);
      return {frame: previous.slice(), diagnostics: {
        madOutliers: [], madRepaired: [], jumpRejected: [], deadbandHeld: 0,
        delayMs: 0, rawToFilteredRms: 0, timestampRejected: false,
        ...emptyMotion(),
      }};
    }
    if (!Number.isFinite(t) || t <= previousTime) {
      return {frame: previous.slice(), diagnostics: {
        madOutliers: [], madRepaired: [], jumpRejected: [], deadbandHeld: 0,
        delayMs: 0, rawToFilteredRms: 0, timestampRejected: true,
        ...emptyMotion(),
      }};
    }

    const dtMs = clamp(t - previousTime, 1, 200);
    const motion = motionDiagnostics(frame);
    const output = previous.slice();
    const madOutliers = [];
    const madRepaired = [];
    const jumpRejected = [];
    let deadbandHeld = 0;
    const delays = [];
    const presentLeft = Number(frame[OFF_PRES_LEFT]) >= .5;
    const presentRight = Number(frame[OFF_PRES_RIGHT]) >= .5;
    for (let i = 0; i < FRAME_DIM; i++) {
      const group = groupFor(i);
      const value = Number(frame[i]);
      if (group === 'presence') {
        output[i] = value >= .5 ? 1 : 0;
        continue;
      }
      const belongsLeft = (i >= OFF_LOC_LEFT && i < OFF_LOC_LEFT + 3) ||
        (i >= OFF_SHAPE_LEFT && i < OFF_SHAPE_RIGHT);
      const belongsRight = (i >= OFF_LOC_RIGHT && i < OFF_LOC_RIGHT + 3) ||
        i >= OFF_SHAPE_RIGHT;
      if ((belongsLeft && !presentLeft) || (belongsRight && !presentRight)) continue;

      const history = histories[i];
      const madOutlier = madState(history, value);
      if (madOutlier) madOutliers.push(i);
      history.push(value);
      if (history.length > 5) history.shift();

      // A quiet group cannot move the avatar. This catches coordinated small
      // calibration drift while still letting MAD observe the sample first.
      if ((group === 'body' || group === 'wrist') &&
          motion.motionByGroup[group] < .25) {
        output[i] = previous[i];
        deadbandHeld++;
        continue;
      }

      // A quiet isolated deviation is more likely detector noise than user
      // motion. Keep raw untouched, but hold visual state before One Euro so
      // the spike cannot start a visible excursion. Intentional group motion
      // bypasses this repair and remains responsive.
      const groupIntentional = group === 'shape'
        ? motion.fingerMotionScore >= .8 : motion.motionScore >= .8;
      const repairThreshold = Math.max(deadbands[group] ?? 0, .005);
      if (madOutlier && !groupIntentional &&
          Math.abs(value - previous[i]) > repairThreshold) {
        output[i] = previous[i];
        madRepaired.push(i);
        continue;
      }

      // Finger shape stays raw here. Filtering XYZ before deriving joint
      // angles adds latency and bends chains. moverMano filters 15 angles.
      if (group === 'shape') {
        output[i] = value;
        continue;
      }

      const cfg = configs[group];
      const jump = Math.abs(value - previousRaw[i]) > cfg.jump;
      jumpStreak[i] = jump ? jumpStreak[i] + 1 : 0;
      if (jump && jumpStreak[i] === 1) {
        jumpRejected.push(i);
        continue;
      }
      const intentional = Math.abs(value - previous[i]) >= cfg.intentional;
      output[i] = filters[i].filter(value, t, quality, intentional);
      const deadband = deadbands[group] ?? 0;
      if (deadband > 0 &&
          Math.abs(output[i] - previous[i]) < deadband &&
          Math.abs(value - previous[i]) <= deadband * 2) {
        output[i] = previous[i];
        deadbandHeld++;
      }
      const rawVelocity = Math.abs(value - previousRaw[i]) / (dtMs / 1000);
      if (rawVelocity > .01) {
        delays.push(Math.min(500, Math.abs(value - output[i]) / rawVelocity * 1000));
      }
    }
    const error = output.reduce((sum, value, index) =>
      sum + (value - Number(frame[index])) ** 2, 0);
    previous = output;
    previousRaw = frame.map(Number);
    previousTime = t;
    return {frame: output.slice(), diagnostics: {
      madOutliers,
      madRepaired,
      jumpRejected,
      deadbandHeld,
      delayMs: median(delays),
      rawToFilteredRms: Math.sqrt(error / FRAME_DIM),
      timestampRejected: false,
      ...motion,
    }};
  };
  return {filter, reset, setDeadbands, getDeadbands: () => ({...deadbands})};
}

const calibrationGroups = {
  bodyLeft: [0, 1, 2, 6, 7, 8, 12, 13, 14, 18, 19, 20],
  bodyRight: [3, 4, 5, 9, 10, 11, 15, 16, 17, 21, 22, 23],
  wristLeft: [24, 25, 26],
  wristRight: [27, 28, 29],
};

function robustSigma(values) {
  if (!values.length) return 0;
  const center = median(values);
  return 1.4826 * median(values.map((value) => Math.abs(value - center)));
}

/** Automatic quiet-state calibration for body/wrist deadbands. */
export function createAdaptiveMotionCalibrator(options = {}) {
  const warmupMs = Math.max(0, Number(options.warmupMs) || 1500);
  const minSamples = Math.max(1, Math.floor(Number(options.minSamples) || 15));
  const base = {
    body: Math.max(0, Number(options.deadbands?.body ?? .003)),
    wrist: Math.max(0, Number(options.deadbands?.wrist ?? .004)),
  };
  const samples = {bodyLeft: [], bodyRight: [], wristLeft: [], wristRight: []};
  let previous = null;
  let previousTime = null;
  let startedAt = null;
  let locked = false;
  let state = 'WARMUP';
  let deadbands = {...base};

  const reset = () => {
    for (const values of Object.values(samples)) values.length = 0;
    previous = null;
    previousTime = null;
    startedAt = null;
    locked = false;
    state = 'WARMUP';
    deadbands = {...base};
  };

  const snapshot = () => {
    const noise = {
      bodyLeft: robustSigma(samples.bodyLeft),
      bodyRight: robustSigma(samples.bodyRight),
      wristLeft: robustSigma(samples.wristLeft),
      wristRight: robustSigma(samples.wristRight),
    };
    noise.body = Math.max(noise.bodyLeft, noise.bodyRight);
    noise.wrist = Math.max(noise.wristLeft, noise.wristRight);
    return {
      state,
      locked,
      deadbands: {...deadbands},
      noise,
      samples: {
        body: samples.bodyLeft.length + samples.bodyRight.length,
        wrist: samples.wristLeft.length + samples.wristRight.length,
      },
    };
  };

  const update = (frame, timestampMs, motionScore = 0) => {
    const values = Array.isArray(frame) ? frame.map(Number) : null;
    const t = Number(timestampMs);
    if (!values || values.length !== FRAME_DIM ||
        values.some((value) => !Number.isFinite(value)) || !Number.isFinite(t) ||
        (previousTime != null && t <= previousTime)) return snapshot();
    if (startedAt == null) startedAt = t;
    const score = Number.isFinite(Number(motionScore)) ? Number(motionScore) : 0;
    if (previous) {
      const delta = (indices) => Math.sqrt(indices.reduce((sum, index) =>
        sum + (values[index] - previous[index]) ** 2, 0) / indices.length);
      if (score < .25) {
        for (const [name, indices] of Object.entries(calibrationGroups)) {
          const value = delta(indices);
          const list = samples[name];
          list.push(value);
          if (list.length > 120) list.shift();
        }
      }
    }
    previous = values;
    previousTime = t;
    const quiet = score < .25;
    state = quiet ? (locked ? 'LOCKED' : 'WARMUP') : 'MOTION';
    const elapsed = t - startedAt;
    const enough = samples.bodyLeft.length >= minSamples &&
      samples.bodyRight.length >= minSamples &&
      samples.wristLeft.length >= minSamples &&
      samples.wristRight.length >= minSamples;
    if (!locked && quiet && elapsed >= warmupMs && enough) locked = true;
    if (locked && quiet) {
      const current = snapshot().noise;
      deadbands = {
        body: Math.max(base.body, current.body * 4),
        wrist: Math.max(base.wrist, current.wrist * 4),
      };
      state = 'LOCKED';
    }
    return snapshot();
  };
  return {update, reset, snapshot};
}

/** Pose stride controller; hands/fingers remain on every input frame. */
export function createAdaptivePoseScheduler(options = {}) {
  const minStride = Math.max(1, Math.floor(Number(options.minStride) || 2));
  const maxStride = Math.max(minStride, Math.floor(Number(options.maxStride) || 4));
  const degradeAfterMs = Math.max(250, Number(options.degradeAfterMs) || 1500);
  const recoverAfterMs = Math.max(250, Number(options.recoverAfterMs) || 2000);
  const processLimitMs = Math.max(1, Number(options.processLimitMs) || 50);
  let stride = minStride;
  let badSince = null;
  let goodSince = null;

  const reset = () => {
    stride = minStride;
    badSince = null;
    goodSince = null;
  };
  const update = (timestampMs, metrics = {}) => {
    const t = Number(timestampMs);
    if (!Number.isFinite(t)) return {stride, degraded: stride > minStride};
    const processP95 = Number(metrics.processP95Ms);
    const inputFps = Number(metrics.inputFps);
    const bad = (Number.isFinite(processP95) && processP95 > processLimitMs) ||
      (Number.isFinite(inputFps) && inputFps > 0 && inputFps < 30);
    if (bad) {
      goodSince = null;
      if (badSince == null) badSince = t;
      if (t - badSince >= degradeAfterMs) {
        if (stride < maxStride) stride++;
        badSince = t;
      }
    } else {
      badSince = null;
      if (goodSince == null) goodSince = t;
      if (t - goodSince >= recoverAfterMs) {
        if (stride > minStride) stride--;
        goodSince = t;
      }
    }
    return {stride, degraded: stride > minStride};
  };
  const shouldRun = (frameIndex, hasPose) => {
    const index = Math.max(0, Math.floor(Number(frameIndex) || 0));
    return hasPose !== true || index % stride === 0;
  };
  return {update, shouldRun, reset, getStride: () => stride};
}
