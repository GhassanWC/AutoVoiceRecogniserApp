/**
 * Translated-speech accounting.
 *
 * WHAT IS METERED: milliseconds of source speech that Sayvo actually
 * translated into text the user can see. NOT the time the microphone was
 * open. A ten-minute session in a silent room costs nothing; two minutes of
 * speech inside that session costs about two minutes.
 *
 * Not charged: silence, waiting for someone to speak, background noise that
 * produces no translation, network and model latency, reconnection, the app's
 * own spoken playback, the moments the uplink is muted so the device's voice
 * is not re-translated, and any speech whose translation never arrives.
 *
 * HOW THE CLIENT REPORTS IT: the phone streams audio straight to Gemini, so
 * the server cannot hear the room and cannot prove a reported segment really
 * contained speech. What the server CAN do is refuse to take the client's
 * word for a delta. The client therefore reports a CUMULATIVE counter with a
 * sequence number, and this module decides what to accept:
 *
 *   - a sequence it has already seen is ignored,
 *   - a counter that went backwards is ignored,
 *   - a jump larger than the wall-clock time that has actually passed on the
 *     SERVER since the last report is clamped to that elapsed time.
 *
 * Speech cannot outrun real time, so the elapsed-time clamp is a physical
 * bound: a client cannot bill more than the session has existed for, no
 * matter what it claims. This is a mitigation, not a proof — see the report
 * in the repo for the honest statement of that trust boundary.
 */

/**
 * Slack added to the elapsed-time bound, covering round-trip latency, timer
 * jitter and small clock differences between reports.
 */
export const REPORT_SLACK_MS = 2_000;

/** How long after its last report a session is treated as abandoned. */
export const SESSION_STALE_SECONDS = 150;

export interface UsageSession {
  uid: string;
  /** Server epoch ms. */
  startedAt: number;
  /** Server epoch ms of the last report this session accepted or rejected. */
  lastReportAt: number;
  /** Highest report sequence seen; reports at or below it are replays. */
  lastSequence: number;
  /** Cumulative translated-speech ms the server has accepted for it. */
  acceptedSpeechMs: number;
  closed: boolean;
}

/** Non-PII operational counters, for cost analysis only. */
export interface SessionTelemetry {
  /** Wall-clock ms the live session was connected. */
  connectedMs: number;
  /** Ms of audio actually streamed to Gemini. */
  audioSentMs: number;
  /** Translated-speech ms the client committed (before server clamping). */
  committedSpeechMs: number;
  translatedUtteranceCount: number;
}

export function newSession(uid: string, nowMs: number): UsageSession {
  return {
    uid,
    startedAt: nowMs,
    lastReportAt: nowMs,
    lastSequence: 0,
    acceptedSpeechMs: 0,
    closed: false,
  };
}

/** What the client says it has committed so far in this session. */
export interface SpeechReport {
  sequence: number;
  /** Cumulative, never a delta: "total so far", so a replay is harmless. */
  cumulativeSpeechMs: number;
  close?: boolean;
}

export type ReportStatus =
  | "applied"
  | "replay"
  | "decreasing"
  | "clamped"
  | "closed";

export interface ReportOutcome {
  session: UsageSession;
  /** Translated-speech ms to charge for THIS report. Never negative. */
  chargeMs: number;
  status: ReportStatus;
}

/**
 * Decides what a cumulative report is worth. Pure: every anti-replay and
 * clamping rule is testable without Firestore.
 */
export function applySpeechReport(
  session: UsageSession,
  report: SpeechReport,
  nowMs: number,
): ReportOutcome {
  const closing = report.close === true;

  if (session.closed) {
    // A closed session can never be charged again, however often a stale
    // client retries.
    return { session, chargeMs: 0, status: "closed" };
  }

  // Replay or out-of-order: the sequence has already been used. The final
  // closing report is allowed to reuse the last sequence so a stop that races
  // the periodic flush still closes the session.
  if (report.sequence <= session.lastSequence && !closing) {
    return { session, chargeMs: 0, status: "replay" };
  }

  const claimed = Number.isFinite(report.cumulativeSpeechMs)
    ? report.cumulativeSpeechMs
    : 0;

  // The counter must be monotonic. A decrease means a broken or hostile
  // client; take nothing, but move the sequence on so the same one cannot be
  // replayed later.
  if (claimed < session.acceptedSpeechMs) {
    return {
      session: {
        ...session,
        lastSequence: Math.max(session.lastSequence, report.sequence),
        lastReportAt: nowMs,
        closed: closing,
      },
      chargeMs: 0,
      status: "decreasing",
    };
  }

  const wanted = claimed - session.acceptedSpeechMs;
  // Speech cannot outrun the clock: at most the time that really passed on
  // the server since the previous report, plus slack.
  const elapsed = Math.max(0, nowMs - session.lastReportAt);
  const ceiling = elapsed + REPORT_SLACK_MS;
  const chargeMs = Math.min(wanted, ceiling);

  return {
    session: {
      ...session,
      lastSequence: Math.max(session.lastSequence, report.sequence),
      lastReportAt: nowMs,
      acceptedSpeechMs: session.acceptedSpeechMs + chargeMs,
      closed: closing,
    },
    chargeMs,
    status: chargeMs < wanted ? "clamped" : "applied",
  };
}

/** Closes a session without charging anything more. */
export function closeSession(session: UsageSession, nowMs: number): UsageSession {
  return { ...session, closed: true, lastReportAt: nowMs };
}

export function isStale(session: UsageSession, nowMs: number): boolean {
  return (
    !session.closed && nowMs - session.lastReportAt > SESSION_STALE_SECONDS * 1000
  );
}

/**
 * Bounds client-reported telemetry to something physically possible, so a
 * broken client cannot poison the cost metrics. Telemetry never touches
 * billing — this only keeps the numbers usable.
 */
export function sanitizeTelemetry(
  raw: Partial<SessionTelemetry> | undefined,
  session: UsageSession,
  nowMs: number,
): SessionTelemetry {
  const sessionMs = Math.max(0, nowMs - session.startedAt) + REPORT_SLACK_MS;
  const bound = (value: unknown, max: number) => {
    const n = typeof value === "number" && Number.isFinite(value) ? value : 0;
    return Math.min(Math.max(0, Math.round(n)), max);
  };
  return {
    connectedMs: bound(raw?.connectedMs, sessionMs),
    audioSentMs: bound(raw?.audioSentMs, sessionMs),
    committedSpeechMs: bound(raw?.committedSpeechMs, sessionMs),
    // A translated utterance is at least a fraction of a second, so this is a
    // generous ceiling rather than a tight one.
    translatedUtteranceCount: bound(raw?.translatedUtteranceCount, 10_000),
  };
}
