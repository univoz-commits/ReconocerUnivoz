import test from 'node:test';
import assert from 'node:assert/strict';

import {
  RigAuditBuffer,
  RigDiagnosticBuffer,
  createAuditSnapshot,
  diagnosticError,
} from '../../assets/avatar_viewer/rig_diagnostics.mjs';

test('diagnostic buffer keeps newest 300 frames and emits V1 report', () => {
  const buffer = new RigDiagnosticBuffer({platform: 'web', avatar: 'univozM'});
  for (let i = 0; i < 305; i++) {
    buffer.record({
      t: i * 33,
      quality: .8,
      raw_frame: Array(152).fill(i),
      filtered_frame: Array(152).fill(i - .1),
      errors: i === 304
        ? [diagnosticError('capture', 'hand_geometry', 'left', 4)]
        : [],
      filter: {delay_ms: i % 4, mad_outliers: [], jump_rejected: []},
    });
  }
  const report = buffer.report({version: 2});
  assert.equal(report.schema, 'RigDiagnosticReportV1');
  assert.equal(report.frame_dim, 152);
  assert.equal(report.frames.length, 300);
  assert.equal(report.frames[0].t, 165);
  assert.equal(report.frames.at(-1).errors[0].landmark, 4);
  assert.equal(report.summary.frames_total, 300);
  assert.equal(report.summary.errors_total, 1);
  assert.equal(report.calibration.version, 2);
});

test('diagnostic buffer can be disabled and cleared without retaining frames', () => {
  const buffer = new RigDiagnosticBuffer();
  buffer.setEnabled(false);
  buffer.record({t: 1, raw_frame: Array(152).fill(0)});
  assert.equal(buffer.report().frames.length, 0);
  buffer.setEnabled(true);
  buffer.record({t: 2, raw_frame: Array(152).fill(0)});
  buffer.clear();
  assert.equal(buffer.report().frames.length, 0);
});

test('numeric AuditSnapshot keeps ephemeral 45s window without video', () => {
  const snapshot = createAuditSnapshot({
    frame: 7, timestampMs: 1000, stage: 'safety_gate',
    joint: 'leftIndexProximal', score: .2, severity: 'error',
    state: 'FROZEN', action: 'freeze_local', code: 'non_finite_transform',
  });
  assert.equal(snapshot.schema, 'AuditSnapshotV1');
  assert.equal(snapshot.code, 'non_finite_transform');
  assert.equal(snapshot.frame, 7);
  assert.equal(snapshot.raw_frame, undefined);

  const buffer = new RigAuditBuffer({maxAgeMs: 45_000, maxEvents: 10});
  buffer.record(snapshot);
  buffer.record(createAuditSnapshot({
    frame: 8, timestampMs: 46_001, stage: 'safety_gate',
    joint: 'leftIndexProximal', score: 1, severity: 'ok',
    state: 'VALID', action: 'apply', code: null,
  }));
  const report = buffer.report(46_001);
  assert.equal(report.schema, 'RigAuditReportV1');
  assert.equal(report.events.length, 1);
  assert.equal(report.events[0].frame, 8);
  assert.equal(report.summary.events_total, 1);
  assert.equal(report.summary.anomalies_total, 0);
  assert.equal(report.summary.health_score, 100);
  assert.equal(report.summary.invalid_transforms_applied, 0);

  const health = new RigAuditBuffer({maxAgeMs: 45_000});
  health.record(createAuditSnapshot({
    timestampMs: 2, severity: 'error', score: 0, code: 'stale_frame',
  }));
  health.record(createAuditSnapshot({
    timestampMs: 3, severity: 'warn', score: .8, code: 'queue_age',
  }));
  assert.equal(health.report(3).summary.health_score, 34.29);
});
