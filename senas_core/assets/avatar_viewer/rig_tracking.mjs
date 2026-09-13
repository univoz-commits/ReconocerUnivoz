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
const cloneLandmarks = (landmarks) => landmarks.map((point) => ({...point}));

function palmFrame(landmarks) {
  if (!Array.isArray(landmarks) || landmarks.length < 18) return null;
  const wrist = xyz(landmarks[0]);
  const index = xyz(landmarks[5]);
  const middle = xyz(landmarks[9]);
  const little = xyz(landmarks[17]);
  if (![wrist, index, middle, little].every(finite)) return null;
  const normalize = (v) => {
    const n = Math.hypot(v.x, v.y, v.z);
    return n > 1e-8 ? {x: v.x / n, y: v.y / n, z: v.z / n} : null;
  };
  const across = normalize({
    x: index.x - little.x, y: index.y - little.y, z: index.z - little.z,
  });
  const forward = normalize({
    x: middle.x - wrist.x, y: middle.y - wrist.y, z: middle.z - wrist.z,
  });
  if (!across || !forward) return null;
  return {across, forward};
}

function orientationDistance(a, b) {
  if (!a || !b) return .5;
  const dot = (u, v) => clamp((u.x * v.x + u.y * v.y + u.z * v.z + 1) / 2);
  return 1 - (dot(a.across, b.across) + dot(a.forward, b.forward)) / 2;
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
    Array.isArray(candidate?.landmarks) && candidate.landmarks.length === 21 &&
    candidate.landmarks.every((point) => finite(xyz(point))));
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

export function shouldRunPoseFrame(frameIndex, hasPose) {
  const index = Math.max(0, Math.floor(Number(frameIndex) || 0));
  return hasPose !== true || index % 2 === 0;
}

function emptyTrack(side) {
  return {
    side,
    state: 'LOST',
    landmarks: null,
    velocity: {x: 0, y: 0, z: 0},
    frame: null,
    confidence: 0,
    lastSeenMs: null,
    hits: 0,
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

function candidateCost(track, candidate, pose, timestampMs, contact) {
  if (candidate?.sideLocked === true && candidate.side &&
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
  const orientation = orientationDistance(track.frame, palmFrame(candidate.landmarks));
  const stated = String(candidate.side ?? '').toLowerCase();
  const side = stated && stated !== track.side ? 1 : stated ? 0 : .5;
  const confidence = 1 - clamp(candidate.confidence ?? .5);
  const sideWeight = contact ? .02 : .10;
  return .45 * position + .20 * velocity + .20 * orientation +
    sideWeight * side + .05 * confidence;
}

function updateVisible(track, candidate, timestampMs) {
  const landmarks = cloneLandmarks(candidate.landmarks);
  const wrist = xyz(landmarks[0]);
  const previous = xyz(track.landmarks?.[0]);
  if (finite(previous) && track.lastSeenMs != null && timestampMs > track.lastSeenMs) {
    const dt = Math.max(.001, (timestampMs - track.lastSeenMs) / 1000);
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
  track.frame = palmFrame(landmarks);
  track.confidence = clamp(candidate.confidence ?? .5);
  track.lastSeenMs = timestampMs;
  track.hits++;
  track.state = track.hits >= 2 ? 'TRACKING' : 'TENTATIVE';
  track.detected = landmarks;
  track.renderLandmarks = landmarks;
  track.restBlend = 0;
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
    state: track.state,
    landmarks: track.landmarks,
    detected: track.detected ?? null,
    renderLandmarks: track.renderLandmarks ?? null,
    velocity: {...track.velocity},
    palmFrame: track.frame,
    confidence: track.confidence,
    restBlend: track.restBlend ?? 0,
  };
}

export function createHandTrackCoordinator() {
  const tracks = {left: emptyTrack('left'), right: emptyTrack('right')};

  const reset = () => {
    tracks.left = emptyTrack('left');
    tracks.right = emptyTrack('right');
  };

  const update = (rawCandidates, pose = {}, timestampMs = 0) => {
    const t = Number(timestampMs) || 0;
    const raw = Array.isArray(rawCandidates) ? rawCandidates : [];
    const incomplete = raw.filter((candidate) =>
      Array.isArray(candidate?.landmarks) && candidate.landmarks.length !== 21);
    const candidates = raw
      .filter((candidate) => Array.isArray(candidate?.landmarks) && candidate.landmarks.length === 21)
      .slice(0, 2);
    const shoulderWidth = Math.max(.05, Number(pose.shoulderWidth) || .4);
    const contactBefore = detectHandContact(
      candidates[0]?.landmarks, candidates[1]?.landmarks, shoulderWidth);
    const costs = candidates.map((candidate) => ({
      left: candidateCost(tracks.left, candidate, pose, t, contactBefore.active),
      right: candidateCost(tracks.right, candidate, pose, t, contactBefore.active),
    }));
    const assigned = {left: null, right: null};
    const assignedCosts = {left: null, right: null};

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
        const pairs = normal <= crossed
          ? [['left', 0], ['right', 1]] : [['left', 1], ['right', 0]];
        for (const [side, index] of pairs) {
          if (canAssign(candidates[index], costs[index][side])) {
            assigned[side] = candidates[index];
            assignedCosts[side] = costs[index][side];
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
      if (assigned[side]) updateVisible(tracks[side], assigned[side], t);
      else updateHidden(tracks[side], t);
    }
    const contact = detectHandContact(
      tracks.left.renderLandmarks, tracks.right.renderLandmarks, shoulderWidth);
    const errors = incomplete.map((candidate) => ({
      stage: 'capture', code: 'hand_landmarks_incomplete',
      side: candidate.side ?? null,
    }));
    for (const side of ['left', 'right']) {
      if (tracks[side].state === 'OCCLUDED') errors.push({
        stage: 'association', code: 'hand_occluded', side,
      });
    }
    if (candidates.length && !assigned.left && !assigned.right) {
      errors.push({stage: 'association', code: 'track_ambiguous'});
    }
    if (raw.some((candidate) => candidate?.sideAmbiguous === true)) {
      errors.push({stage: 'association', code: 'hand_side_ambiguous'});
    }
    for (const side of ['left', 'right']) {
      const stated = String(assigned[side]?.side ?? '').toLowerCase();
      if (stated && stated !== side) {
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
