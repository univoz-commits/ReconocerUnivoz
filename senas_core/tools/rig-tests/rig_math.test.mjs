import test from 'node:test';
import assert from 'node:assert/strict';

import {
  chooseThumbBoneAxis,
  createHandAngleFilter,
  createFastFingerAngleFilter,
  createResponsiveRigFilter,
  createThumbCalibration,
  measureThumbPose,
  solveThumbPose,
  measureFingerLag,
} from '../../assets/avatar_viewer/rig_math.mjs';

const point = (x, y, z = 0) => [x, y, z];

function thumbShape(amount) {
  const points = Array.from({length: 20}, () => point(0, 0, 0));
  points[0] = point(.14, .02);
  points[1] = point(.27 - amount * .08, .04 + amount * .08);
  points[2] = point(.39 - amount * .22, .05 + amount * .18);
  points[3] = point(.52 - amount * .47, .06 + amount * .34);
  points[4] = point(.28, .30);
  points[8] = point(0, .50);
  points[16] = point(-.25, .28);
  return points;
}

test('thumb calibration maps tip approaching palm to monotonic flexion', () => {
  const calibration = createThumbCalibration(
    measureThumbPose(thumbShape(0)),
    measureThumbPose(thumbShape(1)),
    1234,
  );
  const open = solveThumbPose(measureThumbPose(thumbShape(0)), calibration);
  const middle = solveThumbPose(measureThumbPose(thumbShape(.5)), calibration);
  const closed = solveThumbPose(measureThumbPose(thumbShape(1)), calibration);

  assert.ok(open.closure <= .001);
  assert.ok(closed.closure >= .999);
  for (let i = 0; i < 3; i++) {
    assert.ok(open.flexions[i] < middle.flexions[i]);
    assert.ok(middle.flexions[i] < closed.flexions[i]);
  }
  assert.deepEqual(closed.flexions.map((v) => Number(v.toFixed(2))), [.85, 1, .75]);
});

test('thumb bone direction chooses rotation that moves tip toward palm target', () => {
  const chosen = chooseThumbBoneAxis(1.0, [
    {axis: 'x', sign: 1, distance: .96},
    {axis: 'x', sign: -1, distance: 1.04},
    {axis: 'y', sign: 1, distance: .99},
    {axis: 'y', sign: -1, distance: 1.01},
    {axis: 'z', sign: 1, distance: .72},
    {axis: 'z', sign: -1, distance: 1.18},
  ]);
  assert.deepEqual(chosen, {axis: 'z', sign: 1, improvement: .28});
});

function baseFrame(value = 0) {
  const frame = Array(152).fill(value);
  frame[30] = 1;
  frame[31] = 1;
  return frame;
}

for (const fps of [16, 30, 60]) {
  test(`angle-domain finger filter reaches 90% within 120ms at ${fps}fps`, () => {
    const filter = createHandAngleFilter();
    const dt = 1000 / fps;
    filter.filter(Array(15).fill(0), 0, 1);
    let reachedAt = Infinity;
    for (let n = 1; n <= Math.ceil(.3 * fps); n++) {
      const result = filter.filter(Array(15).fill(1), n * dt, 1);
      if (result.angles[0] >= .9 && reachedAt === Infinity) reachedAt = n * dt;
    }
    assert.ok(reachedAt <= 120, `90% reached after ${reachedAt}ms`);
  });
}

test('angle-domain finger filter reduces static jitter by at least 35%', () => {
  const filter = createHandAngleFilter();
  const raw = [];
  const rendered = [];
  for (let n = 0; n < 180; n++) {
    const noise = Math.sin(n * 2.17) * .018 + Math.sin(n * .73) * .009;
    raw.push(noise);
    const angles = Array(15).fill(0); angles[0] = noise;
    rendered.push(filter.filter(angles, n * (1000 / 30), 1).angles[0]);
  }
  const rms = (xs) => Math.sqrt(xs.reduce((s, x) => s + x * x, 0) / xs.length);
  assert.ok(rms(rendered.slice(15)) <= rms(raw.slice(15)) * .65,
    `raw=${rms(raw)} rendered=${rms(rendered)}`);
});

test('isolated impossible jump freezes only affected finger chain for one frame', () => {
  const filter = createHandAngleFilter();
  filter.filter(Array(15).fill(0), 0, 1);
  const first = Array(15).fill(0); first[3] = 1.5;
  const second = Array(15).fill(0); second[3] = 1.5;
  const a = filter.filter(first, 33, 1);
  const b = filter.filter(second, 66, 1);
  assert.equal(a.angles[3], 0);
  assert.equal(a.angles[0], 0);
  assert.ok(b.angles[3] > 0);
  assert.deepEqual(a.diagnostics.jumpRejectedChains, [1]);
});

test('frame filter leaves hand shape XYZ untouched for angle-domain filtering', () => {
  const filter = createResponsiveRigFilter();
  filter.filter(baseFrame(0), 0, 1);
  const next = baseFrame(0); next[32] = .37; next[91] = -.22;
  const result = filter.filter(next, 33, 1);
  assert.equal(result.frame[32], .37);
  assert.equal(result.frame[91], -.22);
});

test('responsive body filter holds micro-motion but passes intentional movement', () => {
  const filter = createResponsiveRigFilter();
  filter.filter(baseFrame(0), 0, 1);
  const micro = baseFrame(0); micro[0] = .001;
  const held = filter.filter(micro, 33, 1);
  assert.equal(held.frame[0], 0);
  assert.ok(held.diagnostics.deadbandHeld > 0);

  const intentional = baseFrame(0); intentional[0] = .03;
  const moved = filter.filter(intentional, 66, 1);
  assert.ok(moved.frame[0] > .003);
});

test('responsive body filter rejects regressive timestamps without a jump', () => {
  const filter = createResponsiveRigFilter();
  filter.filter(baseFrame(0), 100, 1);
  const moved = baseFrame(0); moved[0] = .03;
  const forward = filter.filter(moved, 133, 1);
  const stale = baseFrame(0); stale[0] = .8;
  const result = filter.filter(stale, 120, 1);
  assert.equal(result.frame[0], forward.frame[0]);
  assert.equal(result.diagnostics.timestampRejected, true);
});

test('fast finger route keeps incremental palm closure under 66ms lag', () => {
  const filter = createFastFingerAngleFilter(3);
  const samples = [];
  const dt = 1000 / 30;
  const rampMs = 500;
  filter.filter([0, 0, 0], 0, 1);
  for (let n = 1; n <= 30; n++) {
    const input = Math.min(1, n * dt / rampMs);
    const output = filter.filter([input, input, input], n * dt, 1);
    samples.push({timestampMs: n * dt, input, avatar: output.angles[0]});
  }
  assert.ok(measureFingerLag(samples) <= 66,
    `finger lag=${measureFingerLag(samples)}ms`);
});

test('finger lag metric ignores duplicate render samples', () => {
  const lag = measureFingerLag([
    {timestampMs: 0, input: 0, avatar: 0},
    {timestampMs: 33, input: .9, avatar: .4},
    {timestampMs: 33, input: .9, avatar: .4},
    {timestampMs: 66, input: 1, avatar: .95},
  ]);
  assert.equal(lag, 33);
});
