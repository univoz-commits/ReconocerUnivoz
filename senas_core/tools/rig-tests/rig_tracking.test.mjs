import test from 'node:test';
import assert from 'node:assert/strict';

import {
  assignHandsByArmChain,
  classifySourceSkew,
  createHandTrackCoordinator,
  detectHandContact,
  shouldRunPoseFrame,
} from '../../assets/avatar_viewer/rig_tracking.mjs';

const p = (x, y, z = 0) => ({x, y, z});
function hand(x, y, direction = 1) {
  const points = Array.from({length: 21}, () => p(x, y));
  points[0] = p(x, y);
  points[5] = p(x + .04 * direction, y - .02);
  points[9] = p(x, y - .08);
  points[17] = p(x - .04 * direction, y - .02);
  return points;
}
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
      {landmarks: hand(rightX, .55, -1), side: 'left', confidence: .55},
      {landmarks: hand(leftX, .55), side: 'right', confidence: .55},
    ], pose, n * 33);
    sawContact ||= result.contact.active;
  }
  assert.ok(sawContact);
  assert.ok(result.left.velocity.x < 0);
  assert.ok(result.right.velocity.x > 0);
  assert.equal(result.diagnostics.swaps, 0);
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
