import test from 'node:test';
import assert from 'node:assert/strict';

import {
  createRigSafetyGate,
  quaternionFromEuler,
} from '../../assets/avatar_viewer/rig_safety.mjs';

const valid = (overrides = {}) => ({
  jointId: 'leftIndexProximal',
  frameId: 1,
  timestampMs: 1000,
  nowMs: 1000,
  rotation: [0, 0, 0],
  ...overrides,
});

test('Safety Gate rejects non-finite transforms and freezes only local joint', () => {
  const gate = createRigSafetyGate();
  assert.equal(gate.check(valid()).accepted, true);
  const bad = gate.check(valid({frameId: 2, timestampMs: 1033, nowMs: 1033,
    rotation: [NaN, 0, 0]}));
  assert.equal(bad.accepted, false);
  assert.equal(bad.state, 'FROZEN');
  assert.equal(bad.action, 'freeze_local');
  assert.deepEqual(bad.value, [0, 0, 0]);
  assert.equal(bad.code, 'non_finite_transform');
  assert.equal(gate.check(valid({jointId: 'rightIndexProximal', frameId: 2,
    timestampMs: 1033, nowMs: 1033, rotation: [.2, 0, 0]})).accepted, true);
});

test('Safety Gate validates lengths, limits, speed, stage and hand identity', () => {
  const common = {referenceBoneLength: 1, boneLength: 1};
  const length = createRigSafetyGate({boneLengthTolerance: .1});
  length.check(valid(common));
  assert.equal(length.check(valid({frameId: 2, timestampMs: 1033, nowMs: 1033,
    ...common, boneLength: 1.3})).code, 'bone_length_drift');

  const limits = createRigSafetyGate({jointLimits: {min: [-.5, -.5, -.5],
    max: [.5, .5, .5]}});
  limits.check(valid());
  assert.equal(limits.check(valid({frameId: 2, timestampMs: 1033, nowMs: 1033,
    rotation: [.6, 0, 0]})).code, 'joint_limit_violation');

  const speed = createRigSafetyGate({maxAngularVelocityRadS: 1});
  speed.check(valid());
  assert.equal(speed.check(valid({frameId: 2, timestampMs: 1033, nowMs: 1033,
    rotation: [1, 0, 0]})).code, 'angular_velocity_exceeded');

  const stage = createRigSafetyGate({maxSourceSkewMs: 50});
  stage.check(valid());
  assert.equal(stage.check(valid({frameId: 2, timestampMs: 1033, nowMs: 1033,
    sourceSkewMs: 90})).code, 'stage_desync');

  const hand = createRigSafetyGate();
  hand.check(valid({handId: 'left'}));
  assert.equal(hand.check(valid({frameId: 2, timestampMs: 1033, nowMs: 1033,
    handId: 'right'})).code, 'hand_identity_swap');

  const parent = createRigSafetyGate();
  parent.check(valid({parentId: 'leftHand'}));
  assert.equal(parent.check(valid({frameId: 2, timestampMs: 1033, nowMs: 1033,
    parentId: 'rightHand'})).code, 'parent_frame_mismatch');
});

test('Safety Gate detects stale frames and quaternion sign flips', () => {
  const stale = createRigSafetyGate({maxAgeMs: 100});
  assert.equal(stale.check(valid({nowMs: 1201})).code, 'stale_frame');

  const gate = createRigSafetyGate();
  const q = quaternionFromEuler([.2, 0, 0]);
  assert.equal(gate.check(valid({quaternion: q})).accepted, true);
  const flipped = q.map((value) => -value);
  const result = gate.check(valid({frameId: 2, timestampMs: 1033, nowMs: 1033,
    quaternion: flipped}));
  assert.equal(result.accepted, true);
  assert.ok(result.anomalies.includes('quaternion_flip'));
  assert.ok(result.quaternion[3] > 0);
});

test('Safety Gate audit events preserve numeric frame timestamp', () => {
  const events = [];
  const gate = createRigSafetyGate({onAudit: (event) => events.push(event)});
  gate.check(valid({frameId: 9, timestampMs: 1099, nowMs: 1099}));
  assert.equal(events[0].frame, 9);
  assert.equal(events[0].timestampMs, 1099);
});

test('Safety Gate recovers gradually without teleport and treats duplicate frame idempotently', () => {
  const gate = createRigSafetyGate({recoveryFrames: 3,
    maxAngularVelocityRadS: 100});
  gate.check(valid());
  const frozen = gate.check(valid({frameId: 2, timestampMs: 1033, nowMs: 1033,
    rotation: [NaN, 0, 0]}));
  assert.equal(frozen.applied, false);
  const first = gate.check(valid({frameId: 3, timestampMs: 1066, nowMs: 1066,
    rotation: [.6, 0, 0]}));
  const duplicate = gate.check(valid({frameId: 3, timestampMs: 1066, nowMs: 1066,
    rotation: [.6, 0, 0]}));
  assert.equal(first.state, 'RECOVERING');
  assert.ok(first.value[0] < .6);
  assert.deepEqual(duplicate, first);
  const second = gate.check(valid({frameId: 4, timestampMs: 1099, nowMs: 1099,
    rotation: [.6, 0, 0]}));
  const third = gate.check(valid({frameId: 5, timestampMs: 1132, nowMs: 1132,
    rotation: [.6, 0, 0]}));
  assert.ok(first.value[0] < second.value[0]);
  assert.ok(second.value[0] < third.value[0]);
  assert.equal(third.state, 'VALID');
});
