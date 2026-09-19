import test from 'node:test';
import assert from 'node:assert/strict';

import {
  assignHandsByArmChain,
  classifySourceSkew,
  createHandTrackCoordinator,
  detectHandContact,
  handOrientationFrame,
  palmFrameV2,
  handSurfaceTransition,
  classifyHandSurface,
  resolveAnatomicalHandSide,
  shouldRunPoseFrame,
  validHandLandmarks,
} from '../../assets/avatar_viewer/rig_tracking.mjs';

const p = (x, y, z = 0) => ({x, y, z});
function hand(x, y, direction = 1) {
  const points = Array.from({length: 21}, () => p(x, y));
  points[0] = p(x, y);
  points[1] = p(x + .06 * direction, y + .01);
  points[5] = p(x + .04 * direction, y - .02);
  points[9] = p(x, y - .08);
  points[17] = p(x - .04 * direction, y - .02);
  return points;
}

test('PalmFrameV2 points radial axis toward CMC for both anatomical sides', () => {
  for (const side of ['left', 'right']) {
    const direction = side === 'left' ? 1 : -1;
    const frame = palmFrameV2(hand(.5, .5, direction), side);
    assert.ok(frame);
    assert.ok(Number.isFinite(frame.normal.x));
    assert.ok(frame.cmcRadialDot > 0);
    assert.ok(frame.radial.x * direction > 0);
  }
});

test('surface classifier returns fixed palm/dorsum contract for both sides', () => {
  for (const side of ['left', 'right']) {
    const palm = classifyHandSurface(hand(.5, .5, side === 'left' ? 1 : -1), side);
    const dorsum = classifyHandSurface(hand(.5, .5, side === 'left' ? -1 : 1), side);
    assert.ok(['palm', 'dorsum', 'ambiguous'].includes(palm.surface));
    assert.ok(['palm', 'dorsum', 'ambiguous'].includes(dorsum.surface));
    for (const result of [palm, dorsum]) {
      assert.ok(Number.isFinite(result.confidence));
      assert.ok(result.confidence >= 0 && result.confidence <= 1);
      assert.ok(Number.isFinite(result.score));
      assert.ok(result.normal && Object.values(result.normal).every(Number.isFinite));
    }
    assert.equal(palm.surface, 'palm');
    assert.equal(dorsum.surface, 'dorsum');
  }
});

test('surface classifier marks low normal margin ambiguous', () => {
  const edgeOn = hand(.5, .5, 1).map((point) => ({...point, y: .5,
    z: Math.abs(point.x - .5)}));
  const result = classifyHandSurface(edgeOn, 'left', {margin: .2});
  assert.equal(result.surface, 'ambiguous');
  assert.ok(result.confidence < 1);
});

test('hand contract requires exactly 21 finite landmarks', () => {
  assert.equal(validHandLandmarks(hand(.5, .5)), true);
  assert.equal(validHandLandmarks(hand(.5, .5).map((point) =>
    [point.x, point.y, point.z])), true);
  assert.equal(validHandLandmarks(hand(.5, .5).slice(0, 20)), false);
  const nonFinite = hand(.5, .5);
  nonFinite[8] = p(Number.NaN, .5, 0);
  assert.equal(validHandLandmarks(nonFinite), false);
  const infinite = hand(.5, .5);
  infinite[9] = [Infinity, .5, 0];
  assert.equal(validHandLandmarks(infinite), false);
});
const pose = {
  leftWrist: p(.68, .55), rightWrist: p(.32, .55), shoulderWidth: .4,
};

test('arm chain assignment locks physical hands despite contradictory labels', () => {
  const result = assignHandsByArmChain([
    {landmarks: hand(.68, .55), side: 'right'},
    {landmarks: hand(.32, .55), side: 'left'},
  ], {
    leftShoulder: p(.72, .35), leftElbow: p(.70, .46), leftWrist: p(.68, .55),
    rightShoulder: p(.28, .35), rightElbow: p(.30, .46), rightWrist: p(.32, .55),
    shoulderWidth: .4,
  });
  assert.deepEqual(result.sideByIndex, ['left', 'right']);
  assert.equal(result.mode, 'pose_arm_chain');
});

test('ambiguous arm chains do not lock either hand to a guessed side', () => {
  const result = assignHandsByArmChain([
    {landmarks: hand(.48, .55), side: 'left'},
    {landmarks: hand(.52, .55), side: 'right'},
  ], {
    leftShoulder: p(.40, .35), leftElbow: p(.46, .45), leftWrist: p(.50, .55),
    rightShoulder: p(.60, .35), rightElbow: p(.54, .45), rightWrist: p(.50, .55),
    shoulderWidth: .2,
  });
  assert.deepEqual(result.sideByIndex, [null, null]);
  assert.equal(result.mode, 'ambiguous');
});

test('single complete hand resolves anatomical side from the arm chain', () => {
  const result = assignHandsByArmChain([
    {landmarks: hand(.68, .55), side: 'right'},
  ], {
    leftShoulder: p(.72, .35), leftElbow: p(.70, .46), leftWrist: p(.68, .55),
    rightShoulder: p(.28, .35), rightElbow: p(.30, .46), rightWrist: p(.32, .55),
    shoulderWidth: .4,
  });
  assert.deepEqual(result.sideByIndex, ['left']);
  assert.equal(result.mode, 'pose_arm_chain');
});

test('hand side remains pending until anatomical arm chain is ready', () => {
  assert.deepEqual(resolveAnatomicalHandSide({
    mode: 'fallback', sideByIndex: ['right'],
  }, 0), {
    side: null, sideLocked: false, sideAmbiguous: true,
  });
  assert.deepEqual(resolveAnatomicalHandSide({
    mode: 'pose_arm_chain', sideByIndex: ['left'],
  }, 0), {
    side: 'left', sideLocked: true, sideAmbiguous: false,
  });
});

test('pending hand association tolerates absent pose hint', () => {
  const tracker = createHandTrackCoordinator();
  const result = tracker.update([
    {landmarks: hand(.68, .55), side: 'right', sideAmbiguous: true},
  ], null, 0);
  assert.equal(result.left.state, 'LOST');
  assert.equal(result.right.state, 'LOST');
  assert.ok(result.diagnostics.errors.some((error) =>
    error.code === 'hand_side_ambiguous'));
});

test('pose scheduler preserves first pose and runs every second frame afterwards', () => {
  assert.equal(shouldRunPoseFrame(0, false), true);
  assert.equal(shouldRunPoseFrame(1, true), false);
  assert.equal(shouldRunPoseFrame(2, true), true);
  assert.equal(shouldRunPoseFrame(3, true), false);
  assert.equal(shouldRunPoseFrame(1, false), true);
});

test('contact tracker keeps anatomical identity when detection order reverses', () => {
  const tracker = createHandTrackCoordinator();
  let result = tracker.update([
    {landmarks: hand(.68, .55), side: 'left', confidence: .95},
    {landmarks: hand(.32, .55), side: 'right', confidence: .95},
  ], pose, 0);
  assert.equal(result.left.landmarks[0].x, .68);
  assert.equal(result.right.landmarks[0].x, .32);

  let sawContact = false;
  for (let n = 1; n <= 6; n++) {
    const leftX = .68 - n * .045;
    const rightX = .32 + n * .045;
    result = tracker.update([
      {landmarks: hand(rightX, .55), side: 'left', confidence: .55},
      {landmarks: hand(leftX, .55), side: 'right', confidence: .55},
    ], pose, n * 33);
    sawContact ||= result.contact.active;
  }
  assert.ok(sawContact);
  assert.ok(result.left.velocity.x < 0);
  assert.ok(result.right.velocity.x > 0);
  assert.equal(result.diagnostics.swaps, 0);
});

test('rapid crossing holds identity through transient locked-side inversion', () => {
  const tracker = createHandTrackCoordinator();
  tracker.update([
    {landmarks: hand(.68, .55), side: 'left', confidence: .95},
    {landmarks: hand(.32, .55), side: 'right', confidence: .95},
  ], pose, 0);
  const result = tracker.update([
    // Pose arm-chain can report one bad frame while wrists still continue
    // their previous trajectories. Continuity must win over that transient.
    {landmarks: hand(.64, .55), side: 'right', sideLocked: true, confidence: .95},
    {landmarks: hand(.36, .55), side: 'left', sideLocked: true, confidence: .95},
  ], pose, 33);
  assert.equal(result.left.landmarks[0].x, .64);
  assert.equal(result.right.landmarks[0].x, .36);
  assert.ok(result.diagnostics.errors.some((error) =>
    error.code === 'hand_assignment_hysteresis'));
});

test('identity reassignment requires three consecutive strong frames', () => {
  const tracker = createHandTrackCoordinator();
  tracker.update([
    {landmarks: hand(.68, .55), side: 'left', confidence: .95},
    {landmarks: hand(.32, .55), side: 'right', confidence: .95},
  ], pose, 0);
  const swapped = () => tracker.update([
    {landmarks: hand(.32, .55), side: 'right', sideLocked: true, confidence: .95},
    {landmarks: hand(.68, .55), side: 'left', sideLocked: true, confidence: .95},
  ], pose, 33);
  const first = swapped();
  const second = tracker.update([
    {landmarks: hand(.31, .55), side: 'right', sideLocked: true, confidence: .95},
    {landmarks: hand(.69, .55), side: 'left', sideLocked: true, confidence: .95},
  ], pose, 66);
  assert.ok(first.diagnostics.errors.some((error) =>
    error.code === 'hand_assignment_hysteresis'));
  assert.ok(second.diagnostics.errors.some((error) =>
    error.code === 'hand_assignment_hysteresis'));
  const third = tracker.update([
    {landmarks: hand(.30, .55), side: 'right', sideLocked: true, confidence: .95},
    {landmarks: hand(.70, .55), side: 'left', sideLocked: true, confidence: .95},
  ], pose, 99);
  assert.equal(third.left.detected[0].x, .30);
  assert.equal(third.right.detected[0].x, .70);
});

test('hand surface flip is held once and accepted after temporal confirmation', () => {
  const tracker = createHandTrackCoordinator();
  tracker.update([{landmarks: hand(.68, .55, 1), side: 'left', confidence: 1}], pose, 0);
  const flipped = tracker.update([
    {landmarks: hand(.68, .55, -1), side: 'left', confidence: 1},
  ], pose, 33);
  assert.equal(flipped.left.detected, null);
  assert.ok(Math.abs(flipped.left.renderLandmarks[5].x - .72) < 1e-9);
  assert.ok(flipped.diagnostics.errors.some((error) =>
    error.code === 'hand_surface_flip' && error.action === 'hold_previous'));

  const confirmed = tracker.update([
    {landmarks: hand(.68, .55, -1), side: 'left', confidence: 1},
  ], pose, 66);
  assert.ok(Math.abs(confirmed.left.detected[5].x - .64) < 1e-9);
  assert.equal(confirmed.left.surface, 'dorsum');
  assert.equal(confirmed.left.surfaceChanges, 1);
  assert.equal(confirmed.diagnostics.errors.some((error) =>
    error.code === 'hand_surface_flip'), false);
});

test('isolated wrist jump is held and repeated movement is bounded', () => {
  const tracker = createHandTrackCoordinator();
  tracker.update([{landmarks: hand(.68, .55), side: 'left', confidence: 1}], pose, 0);
  const isolated = tracker.update([
    {landmarks: hand(.92, .55), side: 'left', confidence: 1},
  ], pose, 33);
  assert.equal(isolated.left.detected, null);
  assert.equal(isolated.left.renderLandmarks[0].x, .68);
  assert.ok(isolated.diagnostics.errors.some((error) =>
    error.code === 'hand_position_jump' && error.action === 'hold_previous'));

  const repeated = tracker.update([
    {landmarks: hand(.92, .55), side: 'left', confidence: 1},
  ], pose, 66);
  assert.ok(repeated.left.detected);
  assert.ok(repeated.left.renderLandmarks[0].x < .92);
  assert.ok(repeated.left.renderLandmarks[0].x > .68);
  assert.ok(repeated.left.raw && repeated.left.accepted && repeated.left.render);
});

test('reappearance after long occlusion interpolates render state', () => {
  const tracker = createHandTrackCoordinator();
  tracker.update([{landmarks: hand(.68, .55), side: 'left', confidence: 1}], pose, 0);
  tracker.update([], pose, 600);
  const first = tracker.update([
    {landmarks: hand(.68, .45), side: 'left', confidence: 1},
  ], pose, 633).left;
  assert.ok(first.detected);
  assert.ok(first.renderLandmarks[0].y > .45);
  assert.ok(first.renderLandmarks[0].y < .55);
  assert.equal(first.recoveryFrames, 2);
  const second = tracker.update([
    {landmarks: hand(.68, .45), side: 'left', confidence: 1},
  ], pose, 666).left;
  const third = tracker.update([
    {landmarks: hand(.68, .45), side: 'left', confidence: 1},
  ], pose, 699).left;
  assert.ok(second.renderLandmarks[0].y < first.renderLandmarks[0].y);
  assert.equal(third.recoveryFrames, 0);
  assert.equal(third.renderLandmarks[0].y, .45);
});

test('hand surface transition reports finite orientation distance', () => {
  const before = handOrientationFrame(hand(.68, .55, 1));
  const after = handOrientationFrame(hand(.68, .55, -1));
  const result = handSurfaceTransition(before, after, {
    wristDisplacement: 0,
    shoulderWidth: .4,
  });
  assert.equal(result.accepted, false);
  assert.equal(result.pendingCount, 1);
  assert.ok(Number.isFinite(result.orientationDistance));
});

test('stale hand timestamps hold previous landmarks and report explicit error', () => {
  const tracker = createHandTrackCoordinator();
  tracker.update([{landmarks: hand(.68, .55), side: 'left', sideLocked: true, confidence: .9}], pose, 100);
  const result = tracker.update([
    {landmarks: hand(.30, .55), side: 'left', sideLocked: true, confidence: .9},
  ], pose, 100);
  assert.equal(result.left.detected, null);
  assert.equal(result.left.renderLandmarks[0].x, .68);
  assert.ok(result.diagnostics.errors.some((error) =>
    error.code === 'stale_frame' && error.action === 'hold_previous'));
});

test('degenerate palm frame holds previous orientation instead of replacing it', () => {
  const tracker = createHandTrackCoordinator();
  tracker.update([{landmarks: hand(.68, .55), side: 'left', sideLocked: true, confidence: .9}], pose, 100);
  const degenerate = hand(.68, .55);
  degenerate[17] = degenerate[5];
  const result = tracker.update([
    {landmarks: degenerate, side: 'left', sideLocked: true, confidence: .9},
  ], pose, 133);
  assert.equal(result.left.detected, null);
  assert.equal(result.left.renderLandmarks[0].x, .68);
  assert.ok(result.diagnostics.errors.some((error) =>
    error.code === 'hand_geometry_degenerate' && error.action === 'hold_previous'));
});

test('more than two hand candidates are rejected without silently dropping evidence', () => {
  const tracker = createHandTrackCoordinator();
  const result = tracker.update([
    {landmarks: hand(.68, .55), side: 'left', confidence: .9},
    {landmarks: hand(.32, .55), side: 'right', confidence: .9},
    {landmarks: hand(.50, .55), side: null, confidence: .4},
  ], pose, 100);
  assert.ok(result.diagnostics.errors.some((error) =>
    error.code === 'too_many_hand_candidates'));
});

test('single detection updates one track and never duplicates landmarks', () => {
  const tracker = createHandTrackCoordinator();
  tracker.update([
    {landmarks: hand(.68, .55), side: 'left', confidence: .9},
    {landmarks: hand(.32, .55), side: 'right', confidence: .9},
  ], pose, 0);
  const result = tracker.update([
    {landmarks: hand(.66, .55), side: 'left', confidence: .9},
  ], pose, 200);
  assert.equal(result.left.state, 'TRACKING');
  assert.equal(result.right.state, 'OCCLUDED');
  assert.ok(result.left.detected);
  assert.equal(result.right.detected, null);
  assert.ok(result.right.renderLandmarks);
  assert.notEqual(result.left.landmarks, result.right.renderLandmarks);
});

test('hand tracker rejects incomplete hand instead of tracking only palm', () => {
  const tracker = createHandTrackCoordinator();
  const result = tracker.update([
    {landmarks: hand(.68, .55).slice(0, 20), side: 'left', confidence: .9},
  ], pose, 0);
  assert.equal(result.left.state, 'LOST');
  assert.equal(result.left.detected, null);
  assert.ok(result.diagnostics.errors.some((error) =>
    error.code === 'hand_landmarks_incomplete'));
});

test('hand tracker rejects exact-size non-finite input numerically', () => {
  const tracker = createHandTrackCoordinator();
  const invalid = hand(.68, .55);
  invalid[4] = p(Infinity, .55, 0);
  const result = tracker.update([
    {landmarks: invalid, side: 'left', confidence: .9},
  ], pose, 0);
  assert.equal(result.left.state, 'LOST');
  assert.ok(result.diagnostics.errors.some((error) =>
    error.code === 'hand_landmarks_invalid'));
});

test('hand tracker tolerates absent, array and degenerate inputs without throwing', () => {
  const tracker = createHandTrackCoordinator();
  const arrayHand = hand(.68, .55).map((point) => [point.x, point.y, point.z]);
  assert.doesNotThrow(() => tracker.update([
    null, {landmarks: null}, {landmarks: arrayHand},
  ], pose, 0));
});

test('association reports explicit hand identity contradiction numerically', () => {
  const tracker = createHandTrackCoordinator();
  tracker.update([{landmarks: hand(.68, .55), side: 'left', confidence: .9}], pose, 0);
  const result = tracker.update([
    {landmarks: hand(.67, .55), side: 'right', confidence: .9},
  ], pose, 33);
  assert.ok(result.diagnostics.errors.some((error) =>
    error.code === 'hand_identity_swap' && error.side === 'left'));
});

test('occluded render predicts 300ms, then rests and becomes lost after 500ms', () => {
  const tracker = createHandTrackCoordinator();
  tracker.update([{landmarks: hand(.6, .5), side: 'left', confidence: 1}], pose, 0);
  tracker.update([{landmarks: hand(.58, .5), side: 'left', confidence: 1}], pose, 50);
  const predicted = tracker.update([], pose, 250).left;
  const resting = tracker.update([], pose, 370).left;
  const lost = tracker.update([], pose, 551).left;
  assert.equal(predicted.state, 'OCCLUDED');
  assert.ok(predicted.renderLandmarks[0].x < .58);
  assert.equal(predicted.restBlend, 0);
  assert.ok(resting.restBlend > 0 && resting.restBlend < 1);
  assert.equal(lost.state, 'LOST');
  assert.equal(lost.renderLandmarks, null);
});

test('contact uses wrist distance or hand-box overlap', () => {
  assert.equal(detectHandContact(hand(.49, .5), hand(.51, .5), .4).active, true);
  assert.equal(detectHandContact(hand(.2, .5), hand(.8, .5), .4).active, false);
});

test('source skew boundaries select direct, projected and rejected fusion', () => {
  assert.equal(classifySourceSkew(0).mode, 'direct');
  assert.equal(classifySourceSkew(50).mode, 'direct');
  assert.equal(classifySourceSkew(80).mode, 'project');
  assert.equal(classifySourceSkew(120).mode, 'project');
  assert.equal(classifySourceSkew(121).mode, 'reject');
});
