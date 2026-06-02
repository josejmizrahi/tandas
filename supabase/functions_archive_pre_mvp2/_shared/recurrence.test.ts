// Pure-logic unit tests for the recurrence pattern → occurrences
// generator. Runs via `deno test --allow-env supabase/functions/_shared/`.

import { assertEquals, assertGreaterOrEqual } from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  advance,
  computeNextOccurrences,
  firstOccurrence,
  validatePattern,
  type RecurrencePattern,
} from "./recurrence.ts";

// =============================================================================
// validatePattern
// =============================================================================

Deno.test("validatePattern: weekly Thursday 20:00 with never end → valid", () => {
  const errs = validatePattern({
    frequency: "weekly",
    dayOfWeek: 4,
    hour: 20,
    minute: 0,
    startDate: "2026-05-14",
    endCondition: "never",
  });
  assertEquals(errs, []);
});

Deno.test("validatePattern: rejects out-of-range dayOfWeek + hour + minute", () => {
  const errs = validatePattern({
    frequency: "weekly",
    dayOfWeek: 7,
    hour: 24,
    minute: 60,
    startDate: "2026-05-14",
    endCondition: "never",
  });
  // Three distinct field errors expected.
  assertEquals(errs.length, 3);
  const fields = new Set(errs.map(e => e.field));
  assertEquals(fields.has("dayOfWeek"), true);
  assertEquals(fields.has("hour"), true);
  assertEquals(fields.has("minute"), true);
});

Deno.test("validatePattern: after_count requires count >= 1", () => {
  const errs = validatePattern({
    frequency: "weekly",
    dayOfWeek: 4,
    hour: 20,
    minute: 0,
    startDate: "2026-05-14",
    endCondition: "after_count",
  });
  assertEquals(errs.length, 1);
  assertEquals(errs[0].field, "count");
});

Deno.test("validatePattern: until_date requires untilDate > startDate", () => {
  const errs = validatePattern({
    frequency: "weekly",
    dayOfWeek: 4,
    hour: 20,
    minute: 0,
    startDate: "2026-05-14",
    endCondition: "until_date",
    untilDate: "2026-05-14",  // same day → invalid
  });
  assertEquals(errs.length, 1);
  assertEquals(errs[0].field, "untilDate");
});

Deno.test("validatePattern: startDate format is enforced", () => {
  const errs = validatePattern({
    frequency: "weekly",
    dayOfWeek: 4,
    hour: 20,
    minute: 0,
    startDate: "2026/05/14",  // wrong separator
    endCondition: "never",
  });
  assertEquals(errs.length, 1);
  assertEquals(errs[0].field, "startDate");
});

// =============================================================================
// firstOccurrence
// =============================================================================

Deno.test("firstOccurrence: startDate is already the target DOW → use as anchor", () => {
  // 2026-05-14 is a Thursday (DOW=4).
  const p: RecurrencePattern = {
    frequency: "weekly", dayOfWeek: 4, hour: 20, minute: 30,
    startDate: "2026-05-14", endCondition: "never",
  };
  const first = firstOccurrence(p);
  assertEquals(first.toISOString(), "2026-05-14T20:30:00.000Z");
});

Deno.test("firstOccurrence: startDate is Monday → advance forward to Thursday", () => {
  // 2026-05-11 is Monday. Target Thursday (DOW=4) → 2026-05-14.
  const p: RecurrencePattern = {
    frequency: "weekly", dayOfWeek: 4, hour: 20, minute: 0,
    startDate: "2026-05-11", endCondition: "never",
  };
  const first = firstOccurrence(p);
  assertEquals(first.toISOString(), "2026-05-14T20:00:00.000Z");
});

Deno.test("firstOccurrence: startDate is Friday → advance forward to next Thursday (6 days)", () => {
  // 2026-05-15 is Friday. Target Thursday → 2026-05-21.
  const p: RecurrencePattern = {
    frequency: "weekly", dayOfWeek: 4, hour: 20, minute: 0,
    startDate: "2026-05-15", endCondition: "never",
  };
  const first = firstOccurrence(p);
  assertEquals(first.toISOString(), "2026-05-21T20:00:00.000Z");
});

// =============================================================================
// advance (frequency walk)
// =============================================================================

Deno.test("advance: weekly +7 days", () => {
  const d = advance(new Date("2026-05-14T20:00:00.000Z"), "weekly");
  assertEquals(d.toISOString(), "2026-05-21T20:00:00.000Z");
});

Deno.test("advance: biweekly +14 days", () => {
  const d = advance(new Date("2026-05-14T20:00:00.000Z"), "biweekly");
  assertEquals(d.toISOString(), "2026-05-28T20:00:00.000Z");
});

Deno.test("advance: monthly +1 month, same day-of-month", () => {
  const d = advance(new Date("2026-05-14T20:00:00.000Z"), "monthly");
  assertEquals(d.toISOString(), "2026-06-14T20:00:00.000Z");
});

Deno.test("advance: monthly Jan 31 + 1mo → Feb 28 (non-leap year)", () => {
  const d = advance(new Date("2027-01-31T20:00:00.000Z"), "monthly");
  // 2027 is not a leap year → Feb has 28 days.
  assertEquals(d.toISOString(), "2027-02-28T20:00:00.000Z");
});

Deno.test("advance: monthly Jan 31 + 1mo → Feb 29 (leap year)", () => {
  const d = advance(new Date("2028-01-31T20:00:00.000Z"), "monthly");
  // 2028 is a leap year.
  assertEquals(d.toISOString(), "2028-02-29T20:00:00.000Z");
});

// =============================================================================
// computeNextOccurrences — the function the cron actually calls
// =============================================================================

Deno.test("compute: never, weekly Thursday, first run → fills horizon up to maxPerRun", () => {
  const occurrences = computeNextOccurrences({
    pattern: {
      frequency: "weekly", dayOfWeek: 4, hour: 20, minute: 0,
      startDate: "2026-05-14", endCondition: "never",
    },
    after: null,
    alreadyGenerated: 0,
    now: new Date("2026-05-12T00:00:00.000Z"),
    horizonMs: 60 * 24 * 3600_000,  // 60 days horizon
    maxPerRun: 50,
  });
  // 60 days / 7 ≈ 8-9 weekly occurrences.
  assertGreaterOrEqual(occurrences.length, 8);
  // First one is the first Thursday >= startDate.
  assertEquals(occurrences[0].toISOString(), "2026-05-14T20:00:00.000Z");
  // Each is exactly 7 days after the previous.
  for (let i = 1; i < occurrences.length; i++) {
    const diff = occurrences[i].getTime() - occurrences[i-1].getTime();
    assertEquals(diff, 7 * 24 * 3600_000, `gap ${i}: ${diff}ms not 7d`);
  }
});

Deno.test("compute: re-run with `after` skips already-generated occurrences", () => {
  const pattern: RecurrencePattern = {
    frequency: "weekly", dayOfWeek: 4, hour: 20, minute: 0,
    startDate: "2026-05-14", endCondition: "never",
  };
  // Pretend the previous run produced occurrences up through 2026-05-28.
  const occurrences = computeNextOccurrences({
    pattern,
    after: new Date("2026-05-28T20:00:00.000Z"),
    alreadyGenerated: 3,
    now: new Date("2026-05-29T00:00:00.000Z"),
    horizonMs: 30 * 24 * 3600_000,
    maxPerRun: 50,
  });
  assertGreaterOrEqual(occurrences.length, 4);
  // First in this batch is the Thursday AFTER 2026-05-28 → 2026-06-04.
  assertEquals(occurrences[0].toISOString(), "2026-06-04T20:00:00.000Z");
});

Deno.test("compute: after_count caps the series at `count` total", () => {
  const occurrences = computeNextOccurrences({
    pattern: {
      frequency: "weekly", dayOfWeek: 4, hour: 20, minute: 0,
      startDate: "2026-05-14", endCondition: "after_count", count: 5,
    },
    after: null,
    alreadyGenerated: 0,
    now: new Date("2026-05-12T00:00:00.000Z"),
    horizonMs: 365 * 24 * 3600_000,  // very large horizon — count should bound, not horizon
    maxPerRun: 50,
  });
  assertEquals(occurrences.length, 5);
  assertEquals(occurrences[0].toISOString(), "2026-05-14T20:00:00.000Z");
  assertEquals(occurrences[4].toISOString(), "2026-06-11T20:00:00.000Z");
});

Deno.test("compute: after_count subtracts alreadyGenerated", () => {
  const occurrences = computeNextOccurrences({
    pattern: {
      frequency: "weekly", dayOfWeek: 4, hour: 20, minute: 0,
      startDate: "2026-05-14", endCondition: "after_count", count: 5,
    },
    after: new Date("2026-05-28T20:00:00.000Z"),
    alreadyGenerated: 3,  // 3 of 5 already done
    now: new Date("2026-05-29T00:00:00.000Z"),
    horizonMs: 365 * 24 * 3600_000,
    maxPerRun: 50,
  });
  // Only 2 more occurrences expected to reach total count=5.
  assertEquals(occurrences.length, 2);
});

Deno.test("compute: after_count fully satisfied → empty", () => {
  const occurrences = computeNextOccurrences({
    pattern: {
      frequency: "weekly", dayOfWeek: 4, hour: 20, minute: 0,
      startDate: "2026-05-14", endCondition: "after_count", count: 5,
    },
    after: new Date("2026-06-11T20:00:00.000Z"),
    alreadyGenerated: 5,
    now: new Date("2026-06-12T00:00:00.000Z"),
    horizonMs: 365 * 24 * 3600_000,
    maxPerRun: 50,
  });
  assertEquals(occurrences.length, 0);
});

Deno.test("compute: until_date is inclusive of any occurrence that day", () => {
  const occurrences = computeNextOccurrences({
    pattern: {
      frequency: "weekly", dayOfWeek: 4, hour: 20, minute: 0,
      startDate: "2026-05-14", endCondition: "until_date",
      untilDate: "2026-06-11",  // a Thursday
    },
    after: null,
    alreadyGenerated: 0,
    now: new Date("2026-05-12T00:00:00.000Z"),
    horizonMs: 365 * 24 * 3600_000,
    maxPerRun: 50,
  });
  // Thursdays from 2026-05-14 through 2026-06-11 inclusive = 5 dates.
  assertEquals(occurrences.length, 5);
  assertEquals(occurrences[0].toISOString(), "2026-05-14T20:00:00.000Z");
  assertEquals(occurrences[4].toISOString(), "2026-06-11T20:00:00.000Z");
});

Deno.test("compute: until_date the day before the next Thursday → excludes it", () => {
  const occurrences = computeNextOccurrences({
    pattern: {
      frequency: "weekly", dayOfWeek: 4, hour: 20, minute: 0,
      startDate: "2026-05-14", endCondition: "until_date",
      untilDate: "2026-06-10",  // Wednesday before next Thursday
    },
    after: null,
    alreadyGenerated: 0,
    now: new Date("2026-05-12T00:00:00.000Z"),
    horizonMs: 365 * 24 * 3600_000,
    maxPerRun: 50,
  });
  // Thursdays from 2026-05-14 through 2026-06-04 = 4 dates.
  assertEquals(occurrences.length, 4);
  assertEquals(occurrences[3].toISOString(), "2026-06-04T20:00:00.000Z");
});

Deno.test("compute: horizon bounds 'never' so we don't generate forever", () => {
  const occurrences = computeNextOccurrences({
    pattern: {
      frequency: "weekly", dayOfWeek: 4, hour: 20, minute: 0,
      startDate: "2026-05-14", endCondition: "never",
    },
    after: null,
    alreadyGenerated: 0,
    now: new Date("2026-05-12T00:00:00.000Z"),
    horizonMs: 14 * 24 * 3600_000,  // 14 days
    maxPerRun: 50,
  });
  // 14 days from 2026-05-12 reaches 2026-05-26. Thursdays in window:
  // 2026-05-14 (Thu), 2026-05-21 (Thu). 05-28 is past horizon.
  assertEquals(occurrences.length, 2);
  assertEquals(occurrences[1].toISOString(), "2026-05-21T20:00:00.000Z");
});

Deno.test("compute: maxPerRun caps a giant horizon", () => {
  const occurrences = computeNextOccurrences({
    pattern: {
      frequency: "weekly", dayOfWeek: 4, hour: 20, minute: 0,
      startDate: "2026-05-14", endCondition: "never",
    },
    after: null,
    alreadyGenerated: 0,
    now: new Date("2026-05-12T00:00:00.000Z"),
    horizonMs: 10 * 365 * 24 * 3600_000,  // 10 years horizon
    maxPerRun: 4,  // but only 4 per run
  });
  assertEquals(occurrences.length, 4);
});

Deno.test("compute: invalid pattern → empty (no garbage out)", () => {
  const occurrences = computeNextOccurrences({
    pattern: {
      frequency: "weekly", dayOfWeek: 99, hour: 99, minute: 99,
      startDate: "bad", endCondition: "never",
    },
    after: null,
    alreadyGenerated: 0,
    now: new Date("2026-05-12T00:00:00.000Z"),
    horizonMs: 60 * 24 * 3600_000,
    maxPerRun: 50,
  });
  assertEquals(occurrences.length, 0);
});

Deno.test("compute: monthly day clamping (Jan 31 → Feb 28 → Mar 31 → Apr 30 …)", () => {
  const occurrences = computeNextOccurrences({
    pattern: {
      frequency: "monthly",
      dayOfWeek: 0,  // not relevant for monthly anchor, just needs valid range
      hour: 20, minute: 0,
      startDate: "2027-01-31", endCondition: "after_count", count: 4,
    },
    after: null,
    alreadyGenerated: 0,
    now: new Date("2026-12-01T00:00:00.000Z"),
    horizonMs: 365 * 24 * 3600_000,
    maxPerRun: 50,
  });
  // Jan 31 (Sunday in 2027) → DOW match? 2027-01-31 is Sunday (DOW=0), so
  // first occurrence is 2027-01-31 (no DOW advance). Subsequent monthly
  // advances respect day-of-month with clamping.
  assertEquals(occurrences.length, 4);
  assertEquals(occurrences[0].toISOString(), "2027-01-31T20:00:00.000Z");
  assertEquals(occurrences[1].toISOString(), "2027-02-28T20:00:00.000Z"); // clamped
  assertEquals(occurrences[2].toISOString(), "2027-03-31T20:00:00.000Z");
  assertEquals(occurrences[3].toISOString(), "2027-04-30T20:00:00.000Z"); // clamped (April has 30 days)
});
