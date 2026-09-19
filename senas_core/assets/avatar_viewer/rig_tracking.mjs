const clamp = (value, min = 0, max = 1) =>
  Math.max(min, Math.min(max, Number(value)));
const xyz = (point) => ({
  x: Number(point?.x ?? point?.[0]),
  y: Number(point?.y ?? point?.[1]),
  z: Number(point?.z ?? point?.[2] ?? 0),
});
const finite = (point) =>
  Number.isFinite(point?.x) && Number.isFinite(point?.y) && Number.isFinite(point?.z);
const distance = (a, b) => Math.hypot(a.x - b.x, a.y - b.y, a.z - b.z);
const cloneLandmarks = (landmarks) => landmarks.map((point) => {
  const value = xyz(point);
  return {
    ...point,
    x: value.x,
    y: value.y,
    z: value.z,
  };
});

/** Hand contract: detector must provide all 21 finite landmarks. */
export function validHandLandmarks(landmarks) {
  return Array.isArray(landmarks) && landmarks.length === 21 &&
    landmarks.every((point) => {
      const z = Array.isArray(point) ? point[2] : point?.z;
      return finite(xyz(point)) && Number.isFinite(Number(z));
    });
}

/**
 * Canonical palm frame. The CMC landmark fixes radial-axis sign so the same
 * physical hand does not silently reverse when detector coordinates mirror.
 */
export function palmFrameV2(landmarks, side = null) {
  if (!Array.isArray(landmarks) || landmarks.length < 18) return null;
  const wrist = xyz(landmarks[0]);
  const cmc = xyz(landmarks[1]);
  const index = xyz(landmarks[5]);
  const middle = xyz(landmarks[9]);
  const little = xyz(landmarks[17]);
  if (![wrist, cmc, index, middle, little].every(finite)) return null;
  const normalize = (v) => {
    const n = Math.hypot(v.x, v.y, v.z);
    return n > 1e-8 ? {x: v.x / n, y: v.y / n, z: v.z / n} : null;
  };
  const forward = normalize({
    x: middle.x - wrist.x, y: middle.y - wrist.y, z: middle.z - wrist.z,
  });
  const normalBase = normalize({
    x: (index.y - wrist.y) * (little.z - wrist.z) -
      (index.z - wrist.z) * (little.y - wrist.y),
    y: (index.z - wrist.z) * (little.x - wrist.x) -
      (index.x - wrist.x) * (little.z - wrist.z),
    z: (index.x - wrist.x) * (little.y - wrist.y) -
      (index.y - wrist.y) * (little.x - wrist.x),
  });
  if (!forward || !normalBase) return null;
  let normal = normalBase;
  let radial = normalize({
    x: normal.y * forward.z - normal.z * forward.y,
    y: normal.z * forward.x - normal.x * forward.z,
    z: normal.x * forward.y - normal.y * forward.x,
  });
  if (!radial) return null;
  const cmcVector = {x: cmc.x - wrist.x, y: cmc.y - wrist.y,
    z: cmc.z - wrist.z};
  const radialDot = cmcVector.x * radial.x + cmcVector.y * radial.y +
    cmcVector.z * radial.z;
  if (!Number.isFinite(radialDot) || Math.abs(radialDot) <= 1e-8) return null;
  if (radialDot < 0) {
    normal = {x: -normal.x, y: -normal.y, z: -normal.z};
    radial = {x: -radial.x, y: -radial.y, z: -radial.z};
  }
  const correctedDot = cmcVector.x * radial.x + cmcVector.y * radial.y +
    cmcVector.z * radial.z;
  return {
    across: radial,
    radial,
    forward,
    normal,
    side: side == null ? null : String(side),
    cmcRadialDot: correctedDot,
  };
}

function orientationDistance(a, b) {
  if (!a || !b) return .5;
  const dot = (u, v) => clamp((u.x * v.x + u.y * v.y + u.z * v.z + 1) / 2);
  const frames = [
    [a.across, b.across], [a.forward, b.forward], [a.normal, b.normal],
  ].filter(([left, right]) => left && right);
  if (!frames.length) return .5;
  return 1 - frames.reduce((sum, [left, right]) => sum + dot(left, right), 0) /
    frames.length;
}

/** Stable hand frame used by association and wrist rendering guards. */
export function handOrientationFrame(landmarks) {
  return palmFrameV2(landmarks);
}

/**
 * Holds one suspicious palm/dorsum orientation jump and accepts it only when
 * the same orientation arrives on the next frame. This blocks a one-frame
 * landmark inversion without freezing a hand permanently during a real turn.
 */
export function handSurfaceTransition(previous, current, options = {}) {
  const orientation = orientationDistance(previous, current);
  const width = Math.max(.05, Number(options.shoulderWidth) || .4);
  const displacement = Math.max(0, Number(options.wristDisplacement) || 0) / width;
  const suspicious = !!previous && !!current && orientation >= .60 &&
    displacement <= .40;
  if (!suspicious) {
    return {
      accepted: true,
      flipped: false,
      action: 'accept',
      orientationDistance: orientation,
      pendingCount: 0,
      pendingFrame: null,
    };
  }
  const pendingFrame = options.pendingFrame ?? null;
  const pendingCount = Math.max(0, Math.floor(Number(options.pendingCount) || 0));
  const repeatsPending = pendingFrame &&
    orientationDistance(pendingFrame, current) < .25;
  const nextCount = repeatsPending ? pendingCount + 1 : 1;
  const accepted = nextCount >= 2;
  return {
    accepted,
    flipped: true,
    action: accepted ? 'accept_surface_change' : 'hold_previous',
    orientationDistance: orientation,
    pendingCount: accepted ? 0 : nextCount,
    pendingFrame: accepted ? null : current,
  };
}

/**
 * Classifies palm/dorsum from geometry, never from detector handedness.
 * Camera depth sign is normalized anatomically: left +1, right -1.
 */
export function classifyHandSurface(landmarks, side, options = {}) {
  const fallback = {
    surface: 'ambiguous', confidence: 0, score: 0,
    normal: {x: 0, y: 0, z: 0},
  };
  if (!validHandLandmarks(landmarks) || !['left', 'right'].includes(side)) {
    return fallback;
  }
  const frame = palmFrameV2(landmarks, side);
  if (!frame || !finite(frame.normal)) return fallback;
  const sign = side === 'left' ? 1 : -1;
  const score = Number(frame.normal.z) * sign;
  const margin = Math.max(.05, Number(options.margin) || .20);
  const confidence = clamp((Math.abs(score) - margin) / Math.max(.01, 1 - margin));
  return {
    surface: score > margin ? 'palm' : score < -margin ? 'dorsum' : 'ambiguous',
    confidence,
    score,
    normal: {...frame.normal},
  };
}

function bounds(landmarks) {
  const points = landmarks?.map(xyz).filter(finite) ?? [];
  if (!points.length) return null;
  return {
    minX: Math.min(...points.map((p) => p.x)),
    maxX: Math.max(...points.map((p) => p.x)),
    minY: Math.min(...points.map((p) => p.y)),
    maxY: Math.max(...points.map((p) => p.y)),
  };
}

function overlapRatio(a, b) {
  const aa = bounds(a), bb = bounds(b);
  if (!aa || !bb) return 0;
  const width = Math.max(0, Math.min(aa.maxX, bb.maxX) - Math.max(aa.minX, bb.minX));
  const height = Math.max(0, Math.min(aa.maxY, bb.maxY) - Math.max(aa.minY, bb.minY));
  const intersection = width * height;
  const areaA = Math.max(1e-8, (aa.maxX - aa.minX) * (aa.maxY - aa.minY));
  const areaB = Math.max(1e-8, (bb.maxX - bb.minX) * (bb.maxY - bb.minY));
  return clamp(intersection / Math.min(areaA, areaB));
}

export function detectHandContact(left, right, shoulderWidth) {
  const lw = xyz(left?.[0]), rw = xyz(right?.[0]);
  const width = Math.max(.05, Number(shoulderWidth) || .4);
  const wristRatio = finite(lw) && finite(rw) ? distance(lw, rw) / width : Infinity;
  const overlap = overlapRatio(left, right);
  return {
    active: wristRatio < .22 || overlap > .25,
    wristDistanceShoulders: Number.isFinite(wristRatio) ? wristRatio : null,
    boxOverlap: overlap,
  };
}

export function classifySourceSkew(sourceSkewMs) {
  const skewMs = Math.abs(Number(sourceSkewMs));
  if (!Number.isFinite(skewMs)) return {mode: 'reject', skewMs: null};
  if (skewMs <= 50) return {mode: 'direct', skewMs};
  if (skewMs <= 120) return {mode: 'project', skewMs};
  return {mode: 'reject', skewMs};
}

function posePoint(pose, side, part, index) {
  return pose?.[`${side}${part}`] ?? pose?.[index] ?? null;
}

function normalizedVector(from, to) {
  const vector = {
    x: to.x - from.x, y: to.y - from.y, z: to.z - from.z,
  };
  const length = Math.hypot(vector.x, vector.y, vector.z);
  return length > 1e-8 ? {
    x: vector.x / length, y: vector.y / length, z: vector.z / length,
  } : null;
}

function armChainCost(candidate, side, pose, shoulderWidth) {
  const sideIndexes = side === 'left'
    ? {shoulder: 11, elbow: 13, wrist: 15}
    : {shoulder: 12, elbow: 14, wrist: 16};
  const shoulder = xyz(posePoint(pose, side, 'Shoulder', sideIndexes.shoulder));
  const elbow = xyz(posePoint(pose, side, 'Elbow', sideIndexes.elbow));
  const expectedWrist = xyz(posePoint(pose, side, 'Wrist', sideIndexes.wrist));
  const wrist = xyz(candidate?.landmarks?.[0]);
  if (![shoulder, elbow, expectedWrist, wrist].every(finite)) return Infinity;

  const endpoint = distance(wrist, expectedWrist) / shoulderWidth;
  const expectedDirection = normalizedVector(shoulder, expectedWrist);
  const observedDirection = normalizedVector(shoulder, wrist);
  const direction = expectedDirection && observedDirection
    ? 1 - clamp((expectedDirection.x * observedDirection.x +
        expectedDirection.y * observedDirection.y +
        expectedDirection.z * observedDirection.z + 1) / 2)
    : .5;
  const expectedLower = distance(elbow, expectedWrist);
  const observedLower = distance(elbow, wrist);
  const chain = Math.abs(observedLower - expectedLower) / shoulderWidth;
  return endpoint + direction * .35 + chain * .20;
}

/** Assigns complete hand detections to physical sides using pose arm chains. */
export function assignHandsByArmChain(rawCandidates, pose = {}) {
  const raw = Array.isArray(rawCandidates) ? rawCandidates : [];
  const valid = raw.map((candidate, index) => ({candidate, index})).filter(({candidate}) =>
    validHandLandmarks(candidate?.landmarks));
  const sideByIndex = Array(raw.length).fill(null);
  const leftShoulder = xyz(posePoint(pose, 'left', 'Shoulder', 11));
  const rightShoulder = xyz(posePoint(pose, 'right', 'Shoulder', 12));
  const shoulderWidth = Math.max(.05, Number(pose.shoulderWidth) ||
    (finite(leftShoulder) && finite(rightShoulder)
      ? distance(leftShoulder, rightShoulder) : .4));
  if (!valid.length || !finite(leftShoulder) || !finite(rightShoulder)) {
    return {sideByIndex, mode: 'fallback', costs: []};
  }

  const costs = valid.map(({candidate}) => ({
    left: armChainCost(candidate, 'left', pose, shoulderWidth),
    right: armChainCost(candidate, 'right', pose, shoulderWidth),
  }));
  const margin = Math.max(.06, shoulderWidth * .16);
  if (valid.length >= 2) {
    const normal = costs[0].left + costs[1].right;
    const crossed = costs[0].right + costs[1].left;
    if (Number.isFinite(normal) && Number.isFinite(crossed) &&
        Math.abs(normal - crossed) >= margin) {
      const leftIndex = normal < crossed ? 0 : 1;
      const rightIndex = leftIndex === 0 ? 1 : 0;
      sideByIndex[valid[leftIndex].index] = 'left';
      sideByIndex[valid[rightIndex].index] = 'right';
      return {sideByIndex, mode: 'pose_arm_chain', costs};
    }
  } else {
    const only = costs[0];
    if (Number.isFinite(only.left) && Number.isFinite(only.right) &&
        Math.abs(only.left - only.right) >= margin) {
      sideByIndex[valid[0].index] = only.left < only.right ? 'left' : 'right';
      return {sideByIndex, mode: 'pose_arm_chain', costs};
    }
  }
  return {sideByIndex, mode: 'ambiguous', costs};
}

/**
 * Resolves a candidate side only from the authoritative pose arm chain.
 * Handedness labels are not safe before that chain is available: front-camera
 * inputs can report the category in the opposite convention.
 */
export function resolveAnatomicalHandSide(assignment, index) {
  const side = assignment?.mode === 'pose_arm_chain'
    ? assignment.sideByIndex?.[index] ?? null
    : null;
  return {
    side,
    sideLocked: side != null,
    sideAmbiguous: side == null,
  };
}

export function shouldRunPoseFrame(frameIndex, hasPose) {
  const index = Math.max(0, Math.floor(Number(frameIndex) || 0));
  return hasPose !== true || index % 2 === 0;
}

const kAssignmentConfirmFrames = 3;
const kAssignmentAdvantage = .15;

function gateAssignmentMode(currentMode, pendingMode, pendingCount,
  proposedMode, advantage) {
  if (!proposedMode) {
    return {mode: currentMode, pendingMode: null, pendingCount: 0, held: false};
  }
  if (!currentMode || proposedMode === currentMode) {
    return {mode: proposedMode, pendingMode: null, pendingCount: 0, held: false};
  }
  if (!Number.isFinite(advantage) || advantage < kAssignmentAdvantage) {
    return {mode: currentMode, pendingMode: null, pendingCount: 0, held: true};
  }
  const nextCount = pendingMode === proposedMode ? pendingCount + 1 : 1;
  if (nextCount < kAssignmentConfirmFrames) {
    return {mode: currentMode, pendingMode: proposedMode,
      pendingCount: nextCount, held: true};
  }
  return {mode: proposedMode, pendingMode: null, pendingCount: 0, held: false};
}

function emptyTrack(side) {
  return {
    side,
    sideLocked: false,
    state: 'LOST',
    landmarks: null,
    rawLandmarks: null,
    acceptedLandmarks: null,
    renderLandmarks: null,
    velocity: {x: 0, y: 0, z: 0},
    frame: null,
    surface: null,
    surfaceConfidence: 0,
    surfaceChanges: 0,
    pendingSurface: null,
    pendingSurfaceCount: 0,
    confidence: 0,
    lastSeenMs: null,
    hits: 0,
    pendingOrientationFrame: null,
    pendingOrientationCount: 0,
    pendingPosition: null,
    pendingPositionCount: 0,
    recoveryFrom: null,
    recoveryTarget: null,
    recoveryFrames: 0,
    lastRejectCode: null,
    lastEventCode: null,
  };
}

function expectedWrist(track, timestampMs) {
  const wrist = xyz(track.landmarks?.[0]);
  if (!finite(wrist) || track.lastSeenMs == null) return null;
  const dt = clamp((timestampMs - track.lastSeenMs) / 1000, 0, .3);
  return {
    x: wrist.x + track.velocity.x * dt,
    y: wrist.y + track.velocity.y * dt,
    z: wrist.z + track.velocity.z * dt,
  };
}

function candidateCost(track, candidate, pose, timestampMs, contact,
  ignoreSide = false) {
  if (!ignoreSide && candidate?.sideLocked === true && candidate.side &&
      candidate.side !== track.side) return Infinity;
  const wrist = xyz(candidate.landmarks?.[0]);
  if (!finite(wrist)) return Infinity;
  const width = Math.max(.05, Number(pose?.shoulderWidth) || .4);
  const expected = expectedWrist(track, timestampMs) ?? xyz(
    track.side === 'left' ? pose?.leftWrist : pose?.rightWrist);
  const position = finite(expected) ? clamp(distance(wrist, expected) / width) : .5;
  let velocity = .5;
  if (track.landmarks && track.lastSeenMs != null && timestampMs > track.lastSeenMs) {
    const previous = xyz(track.landmarks[0]);
    const dt = Math.max(.001, (timestampMs - track.lastSeenMs) / 1000);
    const observed = {
      x: (wrist.x - previous.x) / dt,
      y: (wrist.y - previous.y) / dt,
      z: (wrist.z - previous.z) / dt,
    };
    velocity = clamp(Math.hypot(
      observed.x - track.velocity.x,
      observed.y - track.velocity.y,
      observed.z - track.velocity.z,
    ) * .25);
  }
  const orientation = orientationDistance(
    track.frame, palmFrameV2(candidate.landmarks, candidate.side));
  // Antes de pose_arm_chain, handedness de MediaPipe puede venir invertido
  // con cámara frontal. No dejar que etiqueta contradiga continuidad.
  const stated = ignoreSide || candidate.sideAmbiguous === true
    ? '' : String(candidate.side ?? '').toLowerCase();
  const side = stated && stated !== track.side ? 1 : stated ? 0 : .5;
  const confidence = 1 - clamp(candidate.confidence ?? .5);
  const sideWeight = contact ? .02 : .10;
  return .45 * position + .20 * velocity + .20 * orientation +
    sideWeight * side + .05 * confidence;
}

function translatedLandmarks(landmarks, dx, dy, dz) {
  return landmarks.map((point) => {
    const value = xyz(point);
    return {...point, x: value.x + dx, y: value.y + dy, z: value.z + dz};
  });
}

function blendLandmarks(from, to, amount) {
  const alpha = clamp(amount);
  return to.map((point, index) => {
    const start = xyz(from?.[index] ?? point);
    const end = xyz(point);
    return {...point,
      x: start.x + (end.x - start.x) * alpha,
      y: start.y + (end.y - start.y) * alpha,
      z: start.z + (end.z - start.z) * alpha,
    };
  });
}

function boundedRenderLandmarks(landmarks, previous, maxStep) {
  if (!Array.isArray(previous) || !previous.length) return cloneLandmarks(landmarks);
  const target = xyz(landmarks[0]);
  const start = xyz(previous[0]);
  if (!finite(target) || !finite(start)) return cloneLandmarks(landmarks);
  const dx = target.x - start.x, dy = target.y - start.y, dz = target.z - start.z;
  const step = Math.hypot(dx, dy, dz);
  if (step <= maxStep || step <= 1e-8) return cloneLandmarks(landmarks);
  const scale = maxStep / step;
  return translatedLandmarks(landmarks, dx * (scale - 1), dy * (scale - 1), dz * (scale - 1));
}

function updateVisible(track, candidate, timestampMs, shoulderWidth) {
  track.rawLandmarks = validHandLandmarks(candidate?.landmarks)
    ? cloneLandmarks(candidate.landmarks) : null;
  if (track.lastSeenMs != null && timestampMs <= track.lastSeenMs) {
    track.lastRejectCode = 'stale_frame';
    return false;
  }
  const landmarks = cloneLandmarks(candidate.landmarks);
  const wrist = xyz(landmarks[0]);
  const previous = xyz(track.landmarks?.[0]);
  const previousRender = track.renderLandmarks ?? track.landmarks;
  const previousState = track.state;
  const previousRestBlend = track.restBlend ?? 0;
  const hadHistory = track.lastSeenMs != null;
  const frame = palmFrameV2(landmarks, candidate.side);
  if (!frame || !frame.normal) {
    track.lastRejectCode = 'hand_geometry_degenerate';
    return false;
  }
  const surface = classifyHandSurface(landmarks, track.side);
  if (surface.surface === 'ambiguous') {
    track.lastRejectCode = 'hand_surface_ambiguous';
    return false;
  }
  const surfaceChanged = track.surface && surface.surface !== track.surface;
  const transition = handSurfaceTransition(track.frame, frame, {
    shoulderWidth,
    wristDisplacement: finite(previous) ? distance(wrist, previous) : 0,
    pendingFrame: track.pendingOrientationFrame,
    pendingCount: track.pendingOrientationCount,
  });
  track.pendingOrientationFrame = transition.pendingFrame;
  track.pendingOrientationCount = transition.pendingCount;
  if (!transition.accepted) {
    if (surfaceChanged) {
      track.pendingSurface = surface.surface;
      track.pendingSurfaceCount = track.pendingSurface === surface.surface
        ? track.pendingSurfaceCount + 1 : 1;
    }
    track.lastRejectCode = 'hand_surface_flip';
    return false;
  }
  if (surfaceChanged) {
    const repeats = track.pendingSurface === surface.surface
      ? track.pendingSurfaceCount + 1 : 1;
    track.pendingSurface = surface.surface;
    track.pendingSurfaceCount = repeats;
    if (repeats < 2) {
      track.lastRejectCode = 'hand_surface_flip';
      return false;
    }
    track.pendingSurface = null;
    track.pendingSurfaceCount = 0;
    track.surfaceChanges++;
  } else {
    track.pendingSurface = null;
    track.pendingSurfaceCount = 0;
  }
  const dt = track.lastSeenMs != null && timestampMs > track.lastSeenMs
    ? Math.max(.001, (timestampMs - track.lastSeenMs) / 1000) : 0;
  const step = finite(previous) ? distance(wrist, previous) : 0;
  const predicted = expectedWrist(track, timestampMs);
  const predictionError = finite(predicted) ? distance(wrist, predicted) / shoulderWidth : 0;
  // Normal hand motion remains responsive. Large endpoint jumps require the
  // same endpoint twice, then render advances with a bounded step.
  const maxStep = Math.max(shoulderWidth * .04,
    (shoulderWidth * 3.0 + .8) * Math.min(.2, dt || 1 / 60));
  const positionJump = finite(previous) &&
    (step > maxStep || predictionError > .55);
  if (positionJump) {
    const repeats = track.pendingPosition &&
        distance(wrist, xyz(track.pendingPosition)) <= shoulderWidth * .10
      ? track.pendingPositionCount + 1 : 1;
    track.pendingPosition = {...wrist};
    track.pendingPositionCount = repeats;
    if (repeats < 2) {
      track.lastEventCode = 'hand_position_jump';
      track.lastRejectCode = 'hand_position_held';
      return false;
    }
    track.pendingPosition = null;
    track.pendingPositionCount = 0;
  } else {
    track.pendingPosition = null;
    track.pendingPositionCount = 0;
  }
  if (finite(previous) && track.lastSeenMs != null && timestampMs > track.lastSeenMs) {
    const measured = {
      x: (wrist.x - previous.x) / dt,
      y: (wrist.y - previous.y) / dt,
      z: (wrist.z - previous.z) / dt,
    };
    track.velocity = {
      x: measured.x * .65 + track.velocity.x * .35,
      y: measured.y * .65 + track.velocity.y * .35,
      z: measured.z * .65 + track.velocity.z * .35,
    };
  }
  track.landmarks = landmarks;
  track.acceptedLandmarks = landmarks;
  track.frame = frame;
  if (!track.surface || track.surface !== surface.surface) {
    track.surface = surface.surface;
    track.surfaceConfidence = surface.confidence;
  } else {
    track.surfaceConfidence = surface.confidence;
  }
  track.confidence = clamp(candidate.confidence ?? .5);
  track.sideLocked = candidate.sideLocked === true || track.sideLocked === true;
  track.lastSeenMs = timestampMs;
  track.hits++;
  track.state = track.hits >= 2 ? 'TRACKING' : 'TENTATIVE';
  track.detected = landmarks;
  const wasRecovering = (previousState === 'LOST' && hadHistory) ||
    previousRestBlend > 0 ||
    track.recoveryFrames > 0;
  if (wasRecovering) {
    if (track.recoveryFrames <= 0) {
      track.recoveryFrames = 3;
      track.recoveryFrom = previousRender ? cloneLandmarks(previousRender) : landmarks;
    }
    track.recoveryTarget = cloneLandmarks(landmarks);
    const progress = (4 - track.recoveryFrames) / 3;
    track.renderLandmarks = blendLandmarks(
      track.recoveryFrom, track.recoveryTarget, progress);
    track.recoveryFrames--;
    if (track.recoveryFrames <= 0) {
      track.renderLandmarks = cloneLandmarks(track.recoveryTarget);
      track.recoveryFrom = null;
      track.recoveryTarget = null;
    }
    track.lastEventCode = 'hand_recovered';
  } else {
    track.renderLandmarks = boundedRenderLandmarks(
      landmarks, previousRender, maxStep);
  }
  track.restBlend = 0;
  track.lastRejectCode = null;
  return true;
}

function updateHidden(track, timestampMs) {
  track.detected = null;
  if (!track.landmarks || track.lastSeenMs == null) {
    track.state = 'LOST';
    track.renderLandmarks = null;
    track.restBlend = 1;
    return;
  }
  const elapsed = Math.max(0, timestampMs - track.lastSeenMs);
  if (elapsed > 500) {
    track.state = 'LOST';
    track.renderLandmarks = null;
    track.restBlend = 1;
    return;
  }
  track.state = 'OCCLUDED';
  const predictMs = Math.min(300, elapsed);
  const dx = track.velocity.x * predictMs / 1000;
  const dy = track.velocity.y * predictMs / 1000;
  const dz = track.velocity.z * predictMs / 1000;
  track.renderLandmarks = track.landmarks.map((point) => ({
    ...point,
    x: Number(point.x ?? point[0]) + dx,
    y: Number(point.y ?? point[1]) + dy,
    z: Number(point.z ?? point[2] ?? 0) + dz,
  }));
  track.restBlend = elapsed <= 300 ? 0 : clamp((elapsed - 300) / 200);
}

function snapshot(track) {
  return {
    side: track.side,
    sideLocked: track.sideLocked,
    state: track.state,
    landmarks: track.landmarks,
    raw: track.rawLandmarks,
    accepted: track.acceptedLandmarks,
    detected: track.detected ?? null,
    renderLandmarks: track.renderLandmarks ?? null,
    render: track.renderLandmarks ?? null,
    velocity: {...track.velocity},
    palmFrame: track.frame,
    surface: track.surface,
    surfaceConfidence: track.surfaceConfidence,
    surfaceChanges: track.surfaceChanges,
    recoveryFrames: track.recoveryFrames,
    confidence: track.confidence,
    restBlend: track.restBlend ?? 0,
  };
}

export function createHandTrackCoordinator() {
  const tracks = {left: emptyTrack('left'), right: emptyTrack('right')};
  let assignmentMode = null;
  let pendingAssignmentMode = null;
  let pendingAssignmentCount = 0;

  const reset = () => {
    tracks.left = emptyTrack('left');
    tracks.right = emptyTrack('right');
    assignmentMode = null;
    pendingAssignmentMode = null;
    pendingAssignmentCount = 0;
  };

  const update = (rawCandidates, pose = {}, timestampMs = 0) => {
    const t = Number(timestampMs) || 0;
    const raw = Array.isArray(rawCandidates) ? rawCandidates : [];
    const tooMany = raw.length > 2;
    const incomplete = raw.filter((candidate) =>
      Array.isArray(candidate?.landmarks) && candidate.landmarks.length !== 21);
    const invalid = raw.filter((candidate) =>
      Array.isArray(candidate?.landmarks) && candidate.landmarks.length === 21 &&
      !validHandLandmarks(candidate.landmarks));
    const malformed = raw.filter((candidate) =>
      candidate != null && !Array.isArray(candidate?.landmarks));
    const candidates = raw
      .filter((candidate) => validHandLandmarks(candidate?.landmarks))
      .slice(0, 2);
    const shoulderWidth = Math.max(.05, Number(pose?.shoulderWidth) || .4);
    const contactBefore = detectHandContact(
      candidates[0]?.landmarks, candidates[1]?.landmarks, shoulderWidth);
    const costs = candidates.map((candidate) => ({
      left: candidateCost(tracks.left, candidate, pose, t, contactBefore.active),
      right: candidateCost(tracks.right, candidate, pose, t, contactBefore.active),
    }));
    const assigned = {left: null, right: null};
    const assignedCosts = {left: null, right: null};
    let assignmentHysteresis = false;
    tracks.left.lastRejectCode = null;
    tracks.right.lastRejectCode = null;
    tracks.left.lastEventCode = null;
    tracks.right.lastEventCode = null;

    const canAssign = (candidate, cost) => cost <= .65 ||
      (candidate?.sideLocked === true && cost <= .95);
    if (candidates.length === 2) {
      const normal = costs[0].left + costs[1].right;
      const crossed = costs[0].right + costs[1].left;
      const margin = Math.max(.06, shoulderWidth * .16);
      const ambiguous = candidates.every((candidate) =>
        candidate?.sideAmbiguous === true) &&
        Number.isFinite(normal) && Number.isFinite(crossed) &&
        Math.abs(normal - crossed) < margin;
      if (!ambiguous) {
        // Pose arm-chain labels are authoritative only when they agree with
        // temporal continuity. A one-frame arm-chain glitch during a fast
        // crossing must not exchange physical hands in the avatar.
        const neutralCosts = candidates.map((candidate) => ({
          left: candidateCost(tracks.left,
            {...candidate, side: null, sideLocked: false, sideAmbiguous: true},
            pose, t, contactBefore, true),
          right: candidateCost(tracks.right,
            {...candidate, side: null, sideLocked: false, sideAmbiguous: true},
            pose, t, contactBefore, true),
        }));
        const temporalNormal = neutralCosts[0].left + neutralCosts[1].right;
        const temporalCrossed = neutralCosts[0].right + neutralCosts[1].left;
        const labelMode = Number.isFinite(normal) &&
            (!Number.isFinite(crossed) || normal <= crossed)
          ? 'normal' : Number.isFinite(crossed) ? 'crossed' : null;
        const temporalMode = Number.isFinite(temporalNormal) &&
            Number.isFinite(temporalCrossed) &&
            Math.abs(temporalNormal - temporalCrossed) >= margin
          ? (temporalNormal <= temporalCrossed ? 'normal' : 'crossed') : null;
        let selectedMode = labelMode;
        // One paired frame already establishes positional identity. Waiting
        // for TRACKING state (second hit) leaves first fast crossing exposed.
        const established = tracks.left.hits >= 1 && tracks.right.hits >= 1;
        if (established && labelMode && temporalMode &&
            labelMode !== temporalMode) {
          selectedMode = temporalMode;
          assignmentHysteresis = true;
        }
        const evidence = Math.abs(temporalNormal - temporalCrossed);
        // Gate only a proposed remap supported by both independent signals.
        // When label and temporal evidence disagree, temporal matching keeps
        // existing behavior; that disagreement is already reported as a
        // transient label contradiction, not a confirmed identity change.
        const gateCandidate = candidates.every((candidate) =>
          candidate?.sideLocked === true) && labelMode && temporalMode &&
          labelMode === temporalMode ? selectedMode : null;
        const gated = gateAssignmentMode(
          assignmentMode, pendingAssignmentMode, pendingAssignmentCount,
          gateCandidate, evidence,
        );
        if (gateCandidate) {
          selectedMode = gated.mode;
          pendingAssignmentMode = gated.pendingMode;
          pendingAssignmentCount = gated.pendingCount;
          assignmentHysteresis ||= gated.held;
        } else if (selectedMode === assignmentMode) {
          pendingAssignmentMode = null;
          pendingAssignmentCount = 0;
        }
        if (gateCandidate || !assignmentMode) {
          if (selectedMode) assignmentMode = selectedMode;
        }
        const pairs = selectedMode === 'normal'
          ? [['left', 0], ['right', 1]]
          : selectedMode === 'crossed'
            ? [['left', 1], ['right', 0]] : [];
        for (const [side, index] of pairs) {
          const selectedCosts = selectedMode === labelMode ? costs : neutralCosts;
          if (canAssign(candidates[index], selectedCosts[index][side])) {
            assigned[side] = candidates[index];
            assignedCosts[side] = selectedCosts[index][side];
          }
        }
      }
    } else if (candidates.length === 1) {
      const side = costs[0].left <= costs[0].right ? 'left' : 'right';
      const margin = Math.max(.06, shoulderWidth * .16);
      const ambiguous = candidates[0]?.sideAmbiguous === true &&
        Math.abs(costs[0].left - costs[0].right) < margin;
      if (!ambiguous && canAssign(candidates[0], costs[0][side])) {
        assigned[side] = candidates[0];
        assignedCosts[side] = costs[0][side];
      }
    }

    for (const side of ['left', 'right']) {
      tracks[side].rawLandmarks = assigned[side]?.landmarks &&
        validHandLandmarks(assigned[side].landmarks)
        ? cloneLandmarks(assigned[side].landmarks) : null;
      if (assigned[side]) {
        const accepted = updateVisible(
          tracks[side], assigned[side], t, shoulderWidth);
        if (!accepted) updateHidden(tracks[side], t);
      } else updateHidden(tracks[side], t);
    }
    const contact = detectHandContact(
      tracks.left.renderLandmarks, tracks.right.renderLandmarks, shoulderWidth);
    const errors = incomplete.map((candidate) => ({
      stage: 'capture', code: 'hand_landmarks_incomplete',
      side: candidate.side ?? null,
    }));
    errors.push(...invalid.map((candidate) => ({
      stage: 'capture', code: 'hand_landmarks_invalid',
      side: candidate.side ?? null,
    })));
    errors.push(...malformed.map((candidate) => ({
      stage: 'capture', code: 'hand_landmarks_invalid',
      side: candidate.side ?? null,
    })));
    if (tooMany) errors.push({
      stage: 'capture', code: 'too_many_hand_candidates',
      action: 'reject_excess_candidates',
    });
    for (const side of ['left', 'right']) {
      if (tracks[side].state === 'OCCLUDED') errors.push({
        stage: 'association', code: 'hand_occluded', side,
      });
      if (tracks[side].lastRejectCode) errors.push({
        stage: 'association', code: tracks[side].lastRejectCode, side,
        action: 'hold_previous',
      });
      if (tracks[side].lastEventCode) errors.push({
        stage: 'association', code: tracks[side].lastEventCode, side,
        action: tracks[side].lastEventCode === 'hand_recovered'
          ? 'interpolate_recovery' : 'hold_previous',
      });
    }
    if (candidates.length && !assigned.left && !assigned.right) {
      errors.push({stage: 'association', code: 'track_ambiguous'});
    }
    if (raw.some((candidate) => candidate?.sideAmbiguous === true)) {
      errors.push({stage: 'association', code: 'hand_side_ambiguous'});
    }
    if (assignmentHysteresis) {
      errors.push({stage: 'association', code: 'hand_assignment_hysteresis',
        action: 'hold_temporal_identity'});
    }
    for (const side of ['left', 'right']) {
      const stated = String(assigned[side]?.side ?? '').toLowerCase();
      // A temporal hold intentionally uses a candidate whose transient pose
      // label disagrees with the established physical track. Report the hold
      // itself, not a second identity-swap error for the same protected frame.
      if (!assignmentHysteresis && stated && stated !== side) {
        errors.push({stage: 'association', code: 'hand_identity_swap', side});
      }
    }
    return {
      left: snapshot(tracks.left),
      right: snapshot(tracks.right),
      contact,
      diagnostics: {
        costs: assignedCosts,
        candidateCosts: costs,
        swaps: 0,
        errors,
      },
    };
  };
  return {update, reset};
}
