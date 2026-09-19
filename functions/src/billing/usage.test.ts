import { describe, expect, it } from "vitest";

import {
  REPORT_SLACK_MS,
  SESSION_STALE_SECONDS,
  applySpeechReport,
  closeSession,
  isStale,
  newSession,
  sanitizeTelemetry,
} from "./usage.js";

const T0 = Date.parse("2026-09-19T10:00:00Z");
const SECOND = 1000;

function session(nowMs = T0) {
  return newSession("u1", nowMs);
}

describe("what a report is worth", () => {
  it("a fresh session has been charged nothing", () => {
    const s = session();
    expect(s.acceptedSpeechMs).toBe(0);
    expect(s.lastSequence).toBe(0);
    expect(s.closed).toBe(false);
  });

  it("charges the growth of the cumulative counter, not the counter", () => {
    let s = session();
    const first = applySpeechReport(
      s,
      { sequence: 1, cumulativeSpeechMs: 8_000 },
      T0 + 30 * SECOND,
    );
    expect(first.chargeMs).toBe(8_000);
    s = first.session;

    // Another 6 s of speech: the client reports 14 s TOTAL, not 6 s more.
    const second = applySpeechReport(
      s,
      { sequence: 2, cumulativeSpeechMs: 14_000 },
      T0 + 60 * SECOND,
    );
    expect(second.chargeMs).toBe(6_000);
    expect(second.session.acceptedSpeechMs).toBe(14_000);
  });

  it("a report with no new speech costs nothing", () => {
    const s = applySpeechReport(
      session(),
      { sequence: 1, cumulativeSpeechMs: 5_000 },
      T0 + 10 * SECOND,
    ).session;
    const again = applySpeechReport(
      s,
      { sequence: 2, cumulativeSpeechMs: 5_000 },
      T0 + 40 * SECOND,
    );
    expect(again.chargeMs).toBe(0);
    expect(again.status).toBe("applied");
  });
});

describe("replay and ordering", () => {
  it("the same report sent twice is charged once", () => {
    const report = { sequence: 1, cumulativeSpeechMs: 9_000 };
    const first = applySpeechReport(session(), report, T0 + 20 * SECOND);
    expect(first.chargeMs).toBe(9_000);

    const replay = applySpeechReport(first.session, report, T0 + 21 * SECOND);
    expect(replay.chargeMs).toBe(0);
    expect(replay.status).toBe("replay");
    expect(replay.session.acceptedSpeechMs).toBe(9_000);
  });

  it("an out-of-order report from before the last one is ignored", () => {
    let s = session();
    s = applySpeechReport(
      s,
      { sequence: 4, cumulativeSpeechMs: 12_000 },
      T0 + 30 * SECOND,
    ).session;
    const late = applySpeechReport(
      s,
      { sequence: 3, cumulativeSpeechMs: 30_000 },
      T0 + 31 * SECOND,
    );
    expect(late.chargeMs).toBe(0);
    expect(late.status).toBe("replay");
  });

  it("a cumulative counter that goes backwards is refused", () => {
    let s = session();
    s = applySpeechReport(
      s,
      { sequence: 1, cumulativeSpeechMs: 20_000 },
      T0 + 30 * SECOND,
    ).session;
    const shrunk = applySpeechReport(
      s,
      { sequence: 2, cumulativeSpeechMs: 5_000 },
      T0 + 40 * SECOND,
    );
    expect(shrunk.chargeMs).toBe(0);
    expect(shrunk.status).toBe("decreasing");
    // Usage never decreases, and the sequence still moves so it cannot be
    // replayed later.
    expect(shrunk.session.acceptedSpeechMs).toBe(20_000);
    expect(shrunk.session.lastSequence).toBe(2);
  });

  it("a closed session can never be charged again", () => {
    let s = session();
    s = applySpeechReport(
      s,
      { sequence: 1, cumulativeSpeechMs: 4_000, close: true },
      T0 + 10 * SECOND,
    ).session;
    expect(s.closed).toBe(true);

    const after = applySpeechReport(
      s,
      { sequence: 2, cumulativeSpeechMs: 600_000 },
      T0 + 20 * SECOND,
    );
    expect(after.chargeMs).toBe(0);
    expect(after.status).toBe("closed");
  });

  it("the closing report may reuse the last sequence", () => {
    // Stop Listening can race the periodic flush; the close must still land.
    let s = session();
    s = applySpeechReport(
      s,
      { sequence: 3, cumulativeSpeechMs: 7_000 },
      T0 + 20 * SECOND,
    ).session;
    const closing = applySpeechReport(
      s,
      { sequence: 3, cumulativeSpeechMs: 9_000, close: true },
      T0 + 25 * SECOND,
    );
    expect(closing.chargeMs).toBe(2_000);
    expect(closing.session.closed).toBe(true);
  });
});

describe("what is physically possible", () => {
  it("clamps a client claiming more speech than time has passed", () => {
    // Five seconds after the session opened, claiming five minutes of speech.
    const outcome = applySpeechReport(
      session(),
      { sequence: 1, cumulativeSpeechMs: 300_000 },
      T0 + 5 * SECOND,
    );
    expect(outcome.status).toBe("clamped");
    expect(outcome.chargeMs).toBe(5 * SECOND + REPORT_SLACK_MS);
    expect(outcome.session.acceptedSpeechMs).toBe(5 * SECOND + REPORT_SLACK_MS);
  });

  it("a clamp is measured from the previous report, not the session start", () => {
    let s = session();
    s = applySpeechReport(
      s,
      { sequence: 1, cumulativeSpeechMs: 10_000 },
      T0 + 30 * SECOND,
    ).session;
    const outcome = applySpeechReport(
      s,
      { sequence: 2, cumulativeSpeechMs: 999_000 },
      T0 + 40 * SECOND,
    );
    // Ten seconds passed, so at most ten seconds (plus slack) is available.
    expect(outcome.chargeMs).toBe(10 * SECOND + REPORT_SLACK_MS);
  });

  it("lets an honest burst through untouched", () => {
    // 25 s of speech reported 30 s after the session opened is ordinary.
    const outcome = applySpeechReport(
      session(),
      { sequence: 1, cumulativeSpeechMs: 25_000 },
      T0 + 30 * SECOND,
    );
    expect(outcome.status).toBe("applied");
    expect(outcome.chargeMs).toBe(25_000);
  });

  it("a nonsense counter costs nothing rather than crashing", () => {
    const outcome = applySpeechReport(
      session(),
      { sequence: 1, cumulativeSpeechMs: Number.NaN },
      T0 + 10 * SECOND,
    );
    expect(outcome.chargeMs).toBe(0);
  });
});

describe("abandoned sessions", () => {
  it("is not stale while reports keep arriving", () => {
    const s = session();
    expect(isStale(s, T0 + 60 * SECOND)).toBe(false);
  });

  it("goes stale once the client stops reporting", () => {
    const s = session();
    expect(isStale(s, T0 + (SESSION_STALE_SECONDS + 1) * SECOND)).toBe(true);
  });

  it("closing an abandoned session charges nothing", () => {
    // Nothing is ever charged without an accepted report, so a client that
    // vanished mid-session costs the user only what it had already reported.
    const s = applySpeechReport(
      session(),
      { sequence: 1, cumulativeSpeechMs: 3_000 },
      T0 + 10 * SECOND,
    ).session;
    const closed = closeSession(s, T0 + 3600 * SECOND);
    expect(closed.closed).toBe(true);
    expect(closed.acceptedSpeechMs).toBe(3_000);
  });
});

describe("telemetry", () => {
  it("bounds client counters to what the session could possibly hold", () => {
    const t = sanitizeTelemetry(
      {
        connectedMs: 999_999_999,
        audioSentMs: -5,
        committedSpeechMs: 4_000,
        translatedUtteranceCount: 7,
      },
      session(),
      T0 + 60 * SECOND,
    );
    expect(t.connectedMs).toBe(60 * SECOND + REPORT_SLACK_MS);
    expect(t.audioSentMs).toBe(0);
    expect(t.committedSpeechMs).toBe(4_000);
    expect(t.translatedUtteranceCount).toBe(7);
  });

  it("missing telemetry reads as zeroes", () => {
    const t = sanitizeTelemetry(undefined, session(), T0 + SECOND);
    expect(t).toEqual({
      connectedMs: 0,
      audioSentMs: 0,
      committedSpeechMs: 0,
      translatedUtteranceCount: 0,
    });
  });
});
