import test from 'node:test';
import assert from 'node:assert/strict';

import {
  createPerformanceMetrics,
  nextMonotonicTimestamp,
  percentile,
} from '../../assets/avatar_viewer/rig_metrics.mjs';

test('percentile ignores invalid samples and clamps requested percentile', () => {
  assert.equal(percentile([1, 2, 3, 4], 0), 1);
  assert.equal(percentile([1, 2, 3, 4], 1), 4);
  assert.equal(percentile([1, Number.NaN, 3, Infinity], .5), 1);
  assert.equal(percentile([], .95), 0);
});

test('performance metrics reports stage p50/p95/p99 and capture latency', () => {
  const metrics = createPerformanceMetrics(['capture', 'pose', 'render']);
  metrics.recordStage('pose', 4);
  metrics.recordStage('pose', 8);
  metrics.recordStage('pose', 12);
  metrics.recordFrame({timestampMs: 100, capturedAtMs: 100, renderedAtMs: 130});
  metrics.recordFrame({timestampMs: 133, capturedAtMs: 133, renderedAtMs: 180});
  metrics.recordFrame({timestampMs: 166, capturedAtMs: 166, renderedAtMs: 176});

  const report = metrics.snapshot();
  assert.deepEqual(report.stages.pose, {
    count: 3, last_ms: 12, p50_ms: 8, p95_ms: 12, p99_ms: 12,
  });
  assert.equal(report.latency_ms.count, 3);
  assert.equal(report.latency_ms.p50_ms, 30);
  assert.equal(report.latency_ms.p95_ms, 47);
  assert.equal(report.latency_ms.p99_ms, 47);
  assert.equal(report.frames.total, 3);
  assert.equal(report.frames.valid, 3);
});

test('performance metrics counts drops, invalid frames and timestamp rejects', () => {
  const metrics = createPerformanceMetrics(['capture']);
  metrics.recordFrame({timestampMs: 10, valid: true});
  metrics.recordFrame({timestampMs: 10, valid: true});
  metrics.recordFrame({timestampMs: 9, valid: false, dropped: true});
  metrics.recordFrame({timestampMs: 20, valid: false});
  const report = metrics.snapshot();
  assert.equal(report.frames.total, 4);
  assert.equal(report.frames.valid, 1);
  assert.equal(report.frames.invalid, 1);
  assert.equal(report.frames.dropped, 1);
  assert.equal(report.frames.timestamp_rejected, 2);
});

test('performance metrics counts one latency sample per source frame', () => {
  const metrics = createPerformanceMetrics(['render']);
  metrics.recordFrame({
    timestampMs: 100, sourceFrameId: 7,
    capturedAtMs: 100, renderedAtMs: 130,
  });
  metrics.recordFrame({
    timestampMs: 100, sourceFrameId: 7,
    capturedAtMs: 100, renderedAtMs: 150,
  });
  metrics.recordFrame({
    timestampMs: 133, sourceFrameId: 8,
    capturedAtMs: 133, renderedAtMs: 170,
  });
  const report = metrics.snapshot();
  assert.equal(report.latency_ms.count, 2);
  assert.equal(report.frames.total, 2);
});

test('next monotonic timestamp repairs missing, duplicate and regressive values', () => {
  assert.equal(nextMonotonicTimestamp(0, 10), 10);
  assert.equal(nextMonotonicTimestamp(10, 10), 11);
  assert.equal(nextMonotonicTimestamp(11, 4), 12);
  assert.equal(nextMonotonicTimestamp(12, Number.NaN), 13);
});
