const finite = (value) => Number.isFinite(Number(value));

export function percentile(values, p = .95) {
  const samples = (Array.isArray(values) ? values : [])
    .map(Number).filter(Number.isFinite).sort((a, b) => a - b);
  if (!samples.length) return 0;
  const probability = Math.max(0, Math.min(1, Number(p)));
  const index = Math.min(samples.length - 1,
    Math.max(0, Math.ceil(samples.length * probability) - 1));
  return samples[index];
}

export function nextMonotonicTimestamp(previous, candidate) {
  const before = finite(previous) ? Number(previous) : 0;
  const value = finite(candidate) ? Number(candidate) : 0;
  return value > before ? value : before + 1;
}

const emptySummary = () => ({
  count: 0,
  last_ms: 0,
  p50_ms: 0,
  p95_ms: 0,
  p99_ms: 0,
});

function summarize(samples) {
  return {
    count: samples.length,
    last_ms: samples.at(-1) ?? 0,
    p50_ms: percentile(samples, .5),
    p95_ms: percentile(samples, .95),
    p99_ms: percentile(samples, .99),
  };
}

/** Bounded numeric performance metrics. Never stores images, landmarks or video. */
export function createPerformanceMetrics(stageNames = []) {
  const names = [...new Set(stageNames.map(String))];
  const stages = new Map(names.map((name) => [name, []]));
  const latency = [];
  let total = 0;
  let valid = 0;
  let invalid = 0;
  let dropped = 0;
  let timestampRejected = 0;
  let duplicateSourceFrames = 0;
  let firstTimestamp = null;
  let lastTimestamp = null;
  const sourceRecords = new Map();
  const sourceOrder = [];

  const reset = () => {
    for (const values of stages.values()) values.length = 0;
    latency.length = 0;
    total = 0;
    valid = 0;
    invalid = 0;
    dropped = 0;
    timestampRejected = 0;
    duplicateSourceFrames = 0;
    firstTimestamp = null;
    lastTimestamp = null;
    sourceRecords.clear();
    sourceOrder.length = 0;
  };

  const recordStage = (stage, elapsedMs) => {
    const name = String(stage);
    const value = Number(elapsedMs);
    if (!finite(value) || value < 0) return false;
    if (!stages.has(name)) stages.set(name, []);
    const values = stages.get(name);
    values.push(value);
    if (values.length > 300) values.shift();
    return true;
  };

  const recordFrame = ({
    timestampMs,
    sourceFrameId = null,
    capturedAtMs = null,
    renderedAtMs = null,
    valid: frameValid = true,
    dropped: frameDropped = false,
  } = {}) => {
    const sourceId = sourceFrameId == null ? NaN : Number(sourceFrameId);
    if (Number.isFinite(sourceId)) {
      const key = String(sourceId);
      const previous = sourceRecords.get(key);
      if (previous) {
        if (finite(renderedAtMs) && previous.renderedAtMs == null &&
            Number(renderedAtMs) >= Number(previous.capturedAtMs)) {
          previous.renderedAtMs = Number(renderedAtMs);
          latency.push(previous.renderedAtMs - Number(previous.capturedAtMs));
          if (latency.length > 300) latency.shift();
        } else {
          duplicateSourceFrames++;
        }
        return false;
      }
      sourceRecords.set(key, {
        capturedAtMs: finite(capturedAtMs) ? Number(capturedAtMs) : null,
        renderedAtMs: finite(renderedAtMs) ? Number(renderedAtMs) : null,
      });
      sourceOrder.push(key);
      if (sourceOrder.length > 300) {
        sourceRecords.delete(sourceOrder.shift());
      }
      if (finite(capturedAtMs) && finite(renderedAtMs) &&
          Number(renderedAtMs) >= Number(capturedAtMs)) {
        latency.push(Number(renderedAtMs) - Number(capturedAtMs));
        if (latency.length > 300) latency.shift();
      }
    }
    total++;
    const timestamp = Number(timestampMs);
    const monotonic = finite(timestamp) &&
      (lastTimestamp == null || timestamp > lastTimestamp);
    if (!monotonic) {
      timestampRejected++;
    } else {
      if (firstTimestamp == null) firstTimestamp = timestamp;
      lastTimestamp = timestamp;
      if (frameValid === true) valid++;
      if (!Number.isFinite(sourceId) && finite(capturedAtMs) && finite(renderedAtMs) &&
          Number(renderedAtMs) >= Number(capturedAtMs)) {
        latency.push(Number(renderedAtMs) - Number(capturedAtMs));
        if (latency.length > 300) latency.shift();
      }
    }
    if (frameDropped === true) dropped++;
    else if (frameValid !== true) invalid++;
    return monotonic;
  };

  const snapshot = () => {
    const outputStages = {};
    for (const [name, values] of stages.entries()) {
      outputStages[name] = values.length ? summarize(values) : emptySummary();
    }
    const durationMs = firstTimestamp != null && lastTimestamp != null
      ? Math.max(0, lastTimestamp - firstTimestamp) : 0;
    return {
      schema: 'RigPerformanceMetricsV1',
      stages: outputStages,
      latency_ms: latency.length ? summarize(latency) : emptySummary(),
      frames: {
        total,
        valid,
        invalid,
        dropped,
        duplicate_source_frames: duplicateSourceFrames,
        timestamp_rejected: timestampRejected,
        input_fps: durationMs > 0
          ? Number(((valid - 1) * 1000 / durationMs).toFixed(2)) : 0,
      },
    };
  };

  return {recordStage, recordFrame, snapshot, reset};
}
