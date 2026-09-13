const FRAME_DIM = 152;

const percentile = (values, p) => {
  if (!values.length) return 0;
  const sorted = values.slice().sort((a, b) => a - b);
  return sorted[Math.min(sorted.length - 1,
    Math.max(0, Math.ceil(sorted.length * p) - 1))];
};

export function diagnosticError(stage, code, side = null, landmark = null) {
  return {
    stage: String(stage),
    code: String(code),
    ...(side ? {side: String(side)} : {}),
    ...(Number.isInteger(landmark) ? {landmark} : {}),
  };
}

export function createAuditSnapshot({
  frame = null,
  timestampMs,
  stage = 'unknown',
  joint = null,
  score = 0,
  severity = 'info',
  state = 'UNKNOWN',
  action = 'observe',
  code = null,
} = {}) {
  const safeSeverity = ['ok', 'info', 'warn', 'error'].includes(severity)
    ? severity : 'info';
  const numericScore = Number(score);
  const normalizedFrame = Number.isFinite(Number(frame)) ? Number(frame) : null;
  const normalizedTimestamp = Number(timestampMs);
  return {
    schema: 'AuditSnapshotV1',
    frame: normalizedFrame,
    frameId: normalizedFrame,
    t: normalizedTimestamp,
    timestampMs: normalizedTimestamp,
    stage: String(stage),
    joint: joint == null ? null : String(joint),
    score: Number.isFinite(numericScore)
      ? Math.max(0, Math.min(1, numericScore)) : 0,
    severity: safeSeverity,
    state: String(state),
    action: String(action),
    code: code == null ? null : String(code),
  };
}

/** Numeric, in-memory, time-bounded audit. It never stores media or frames. */
export class RigAuditBuffer {
  constructor({maxAgeMs = 45_000, maxEvents = 1_800} = {}) {
    this.maxAgeMs = Math.max(1, Number(maxAgeMs) || 45_000);
    this.maxEvents = Math.max(1, Number(maxEvents) || 1_800);
    this.events = [];
    this.latestTimestampMs = null;
  }

  _purge(referenceMs) {
    const cutoff = Number(referenceMs) - this.maxAgeMs;
    this.events = this.events.filter((event) => event.t >= cutoff);
    if (this.events.length > this.maxEvents) {
      this.events.splice(0, this.events.length - this.maxEvents);
    }
  }

  record(snapshot) {
    if (!snapshot || snapshot.schema !== 'AuditSnapshotV1' ||
        !Number.isFinite(Number(snapshot.t))) return;
    const copy = {...snapshot, t: Number(snapshot.t)};
    this.latestTimestampMs = this.latestTimestampMs == null
      ? copy.t : Math.max(this.latestTimestampMs, copy.t);
    this.events.push(copy);
    this._purge(this.latestTimestampMs);
  }

  clear() {
    this.events.length = 0;
    this.latestTimestampMs = null;
  }

  report(nowMs = this.latestTimestampMs ?? Date.now()) {
    const referenceMs = Number(nowMs);
    if (Number.isFinite(referenceMs)) this._purge(referenceMs);
    const events = this.events.map((event) => ({...event}));
    const codes = {};
    for (const event of events) {
      if (event.code) codes[event.code] = (codes[event.code] ?? 0) + 1;
    }
    const severityWeights = {ok: 1, info: 1, warn: 1.5, error: 2};
    const weighted = events.reduce((result, event) => {
      const score = Number(event.score);
      if (!Number.isFinite(score)) return result;
      const weight = severityWeights[event.severity] ?? 1;
      result.score += weight * Math.max(0, Math.min(1, score));
      result.weight += weight;
      return result;
    }, {score: 0, weight: 0});
    const healthScore = weighted.weight > 0
      ? Number((100 * weighted.score / weighted.weight).toFixed(2)) : 100;
    return {
      schema: 'RigAuditReportV1',
      window_ms: this.maxAgeMs,
      created_at_ms: Date.now(),
      summary: {
        events_total: events.length,
        anomalies_total: events.filter((event) => event.code != null).length,
        health_score: healthScore,
        invalid_transforms_applied: 0,
        codes,
      },
      events,
    };
  }
}

export class RigDiagnosticBuffer {
  constructor(metadata = {}, maxFrames = 300) {
    this.metadata = {...metadata};
    this.maxFrames = Math.max(1, Number(maxFrames) || 300);
    this.enabled = true;
    this.frames = [];
  }

  setEnabled(enabled) {
    this.enabled = enabled === true;
  }

  clear() {
    this.frames.length = 0;
  }

  record(frame) {
    if (!this.enabled || !frame || !Number.isFinite(Number(frame.t))) return;
    const copy = JSON.parse(JSON.stringify(frame));
    this.frames.push(copy);
    if (this.frames.length > this.maxFrames) {
      this.frames.splice(0, this.frames.length - this.maxFrames);
    }
  }

  report(calibration = null, audit = null) {
    const frames = JSON.parse(JSON.stringify(this.frames));
    const delays = frames.map((frame) => Number(frame.filter?.delay_ms ?? 0))
      .filter(Number.isFinite);
    const timestamps = frames.map((frame) => Number(frame.t)).filter(Number.isFinite);
    const duration = timestamps.length > 1 ? timestamps.at(-1) - timestamps[0] : 0;
    const errorsTotal = frames.reduce((sum, frame) =>
      sum + (Array.isArray(frame.errors) ? frame.errors.length : 0), 0);
    const jumpRejected = frames.reduce((sum, frame) =>
      sum + (frame.filter?.jump_rejected?.length ?? 0), 0);
    const madOutliers = frames.reduce((sum, frame) =>
      sum + (frame.filter?.mad_outliers?.length ?? 0), 0);
    return {
      schema: 'RigDiagnosticReportV1',
      created_at_ms: Date.now(),
      platform: this.metadata.platform ?? 'unknown',
      avatar: this.metadata.avatar ?? 'univozM',
      norm_version: '2.0.0',
      frame_dim: FRAME_DIM,
      calibration: calibration ? JSON.parse(JSON.stringify(calibration)) : null,
      summary: {
        frames_total: frames.length,
        errors_total: errorsTotal,
        input_fps: duration > 0 ? Number(((frames.length - 1) * 1000 / duration).toFixed(2)) : 0,
        filter_delay_p50_ms: Number(percentile(delays, .5).toFixed(2)),
        filter_delay_p95_ms: Number(percentile(delays, .95).toFixed(2)),
        jump_rejections: jumpRejected,
        mad_outliers: madOutliers,
      },
      ...(audit ? {audit: JSON.parse(JSON.stringify(audit))} : {}),
      frames,
    };
  }
}
