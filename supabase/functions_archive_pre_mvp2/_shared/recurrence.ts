// recurrence.ts — pure pattern → next-occurrences generator.
//
// Used by `auto-generate-events` to compute the timestamps it should
// produce for a given `resource_series.pattern` jsonb. Pure function:
// no DB, no clock side effects (the caller passes `now`). Easy to
// unit test with fixtures.
//
// V1 semantics
// ============
//   - All time math runs in UTC. `pattern.timezone` is stored on the
//     series for display purposes but NOT used for computation.
//     Documented limitation: DST-affected groups will see occurrences
//     drift by 1h twice a year. Tier 8+ will switch to local-time
//     anchoring with Intl.DateTimeFormat once we have e2e coverage of
//     DST edge cases.
//   - `frequency=weekly` advances +7 UTC days.
//   - `frequency=biweekly` advances +14 UTC days.
//   - `frequency=monthly` advances +1 UTC month, keeping the same
//     day-of-month. February overflow uses Postgres-style clamping
//     (Jan 31 → Feb 28 / Feb 29).
//   - `dayOfWeek` is the anchor — the first occurrence is the next
//     date on/after `startDate` whose UTC weekday matches.
//
// End conditions
// ==============
//   - `never`        : generate forever (bounded by `horizonMs`).
//   - `after_count`  : stop after `pattern.count` total occurrences
//                      across the series. The caller passes
//                      `alreadyGenerated` so this batch knows the
//                      starting offset.
//   - `until_date`   : stop on or before `pattern.untilDate`. The
//                      untilDate is interpreted as 23:59:59 UTC of
//                      that date — inclusive of any occurrence
//                      scheduled that day.

export type Frequency = "weekly" | "biweekly" | "monthly";
export type EndCondition = "never" | "after_count" | "until_date";

export interface RecurrencePattern {
  frequency:    Frequency;
  /** 0=Sunday … 6=Saturday (UTC). */
  dayOfWeek:    number;
  /** UTC hour 0-23. */
  hour:         number;
  /** UTC minute 0-59. */
  minute:       number;
  /** ISO date 'YYYY-MM-DD'. Interpreted as UTC midnight, then hour/minute added. */
  startDate:    string;
  endCondition: EndCondition;
  /** Required when endCondition='after_count'. */
  count?:       number;
  /** Required when endCondition='until_date'. ISO date 'YYYY-MM-DD'. */
  untilDate?:   string;
  /** IANA timezone (e.g. "America/Mexico_City"). Stored, not computed. */
  timezone?:    string;
}

export interface ComputeArgs {
  pattern:          RecurrencePattern;
  /** Last `starts_at` generated for this series, or null for first run. */
  after:            Date | null;
  /** Total occurrences already persisted for this series (for after_count). */
  alreadyGenerated: number;
  /** "Now" for horizon bounding. Inject so the function stays pure. */
  now:              Date;
  /** Look-ahead window. The function produces no timestamp beyond now + horizonMs. */
  horizonMs:        number;
  /** Hard safety cap — never produce more than this many in one call. Default 50. */
  maxPerRun?:       number;
}

export interface ValidationError {
  field: string;
  message: string;
}

/**
 * Validates a pattern. Returns the list of issues; empty list = valid.
 * Used both by the generator (defensive) and by the wizard before it
 * persists a series.
 */
export function validatePattern(p: Partial<RecurrencePattern>): ValidationError[] {
  const errs: ValidationError[] = [];
  if (p.frequency !== "weekly" && p.frequency !== "biweekly" && p.frequency !== "monthly") {
    errs.push({ field: "frequency", message: "must be weekly | biweekly | monthly" });
  }
  if (typeof p.dayOfWeek !== "number" || p.dayOfWeek < 0 || p.dayOfWeek > 6) {
    errs.push({ field: "dayOfWeek", message: "must be 0-6" });
  }
  if (typeof p.hour !== "number" || p.hour < 0 || p.hour > 23) {
    errs.push({ field: "hour", message: "must be 0-23" });
  }
  if (typeof p.minute !== "number" || p.minute < 0 || p.minute > 59) {
    errs.push({ field: "minute", message: "must be 0-59" });
  }
  if (!p.startDate || !/^\d{4}-\d{2}-\d{2}$/.test(p.startDate)) {
    errs.push({ field: "startDate", message: "must be YYYY-MM-DD" });
  }
  if (p.endCondition !== "never" && p.endCondition !== "after_count" && p.endCondition !== "until_date") {
    errs.push({ field: "endCondition", message: "must be never | after_count | until_date" });
  } else if (p.endCondition === "after_count") {
    if (typeof p.count !== "number" || p.count < 1) {
      errs.push({ field: "count", message: "required when endCondition=after_count, must be >= 1" });
    }
  } else if (p.endCondition === "until_date") {
    if (!p.untilDate || !/^\d{4}-\d{2}-\d{2}$/.test(p.untilDate)) {
      errs.push({ field: "untilDate", message: "required when endCondition=until_date, YYYY-MM-DD" });
    } else if (p.startDate && p.untilDate <= p.startDate) {
      errs.push({ field: "untilDate", message: "must be after startDate" });
    }
  }
  return errs;
}

/**
 * The next occurrence at or after the pattern's startDate that lands
 * on the requested dayOfWeek, at the requested hour:minute UTC.
 */
export function firstOccurrence(pattern: RecurrencePattern): Date {
  const [y, m, d] = pattern.startDate.split("-").map(Number);
  // UTC midnight of startDate + hour:minute.
  const anchor = new Date(Date.UTC(y, m - 1, d, pattern.hour, pattern.minute, 0, 0));
  // Advance forward (never backward) to land on pattern.dayOfWeek.
  // (Math: (target - current + 7) % 7 gives 0-6 forward days.)
  const currentDow = anchor.getUTCDay();
  const delta = (pattern.dayOfWeek - currentDow + 7) % 7;
  if (delta > 0) anchor.setUTCDate(anchor.getUTCDate() + delta);
  return anchor;
}

/**
 * Advances `date` by one period of `frequency`, in UTC.
 *
 * Monthly uses iCal-style anchoring: the result lands on `anchorDay`
 * (or the last day of the target month if anchorDay overflows). This
 * means a series anchored on Jan 31 produces Jan 31 → Feb 28 → Mar 31
 * → Apr 30 → … (each month uses the requested day, clamped). Without
 * the anchor we'd get Jan 31 → Feb 28 → Mar 28 (sticky to the clamped
 * value), which feels broken to users.
 *
 * `anchorDay` defaults to the date's own day-of-month so weekly /
 * biweekly callers don't have to know about it.
 */
export function advance(
  date: Date,
  frequency: Frequency,
  anchorDay: number = date.getUTCDate(),
): Date {
  const d = new Date(date);
  switch (frequency) {
    case "weekly":   d.setUTCDate(d.getUTCDate() + 7);  break;
    case "biweekly": d.setUTCDate(d.getUTCDate() + 14); break;
    case "monthly":  {
      // Move to the first of next month (avoids JS month wrap on day
      // overflow), then set the requested day clamped to the last
      // day of that month.
      const totalMonth = d.getUTCMonth() + 1;
      const targetYear = d.getUTCFullYear() + (totalMonth >= 12 ? 1 : 0);
      const targetMonth = totalMonth % 12;
      // Last day of target month: day 0 of (target+1) in normalized form.
      const lastDay = new Date(Date.UTC(targetYear, targetMonth + 1, 0)).getUTCDate();
      const targetDay = Math.min(anchorDay, lastDay);
      d.setUTCFullYear(targetYear);
      d.setUTCMonth(targetMonth, targetDay);
      break;
    }
  }
  return d;
}

/**
 * Computes the next occurrences for `pattern` that should be created
 * starting after `after`, bounded by horizon + end condition.
 *
 * Returns occurrences sorted ascending. Empty array when nothing to
 * generate (already at horizon / past end condition / maxPerRun hit).
 */
export function computeNextOccurrences(args: ComputeArgs): Date[] {
  const { pattern, after, alreadyGenerated, now, horizonMs } = args;
  const maxPerRun = args.maxPerRun ?? 50;
  const horizon  = new Date(now.getTime() + horizonMs);

  // Validate before consuming — refuse to return garbage.
  const errs = validatePattern(pattern);
  if (errs.length > 0) return [];

  const first = firstOccurrence(pattern);
  // iCal-style anchor for monthly: every occurrence lands on
  // first.day-of-month, clamped to month length. Stored once so the
  // loop doesn't drift after a February clamp.
  const anchorDay = first.getUTCDate();
  let occurrence = first;
  // If we already have generations, walk forward to the first
  // occurrence strictly after `after`.
  if (after !== null) {
    while (occurrence.getTime() <= after.getTime()) {
      occurrence = advance(occurrence, pattern.frequency, anchorDay);
    }
  }

  // Resolve end condition into an absolute upper bound on
  // occurrenceIndex (0-based) and absolute upper bound on time.
  const remainingByCount = (() => {
    if (pattern.endCondition !== "after_count") return Number.POSITIVE_INFINITY;
    const total = pattern.count ?? 0;
    return Math.max(0, total - alreadyGenerated);
  })();
  const untilTime = (() => {
    if (pattern.endCondition !== "until_date" || !pattern.untilDate) return Number.POSITIVE_INFINITY;
    // Inclusive: the entire untilDate day in UTC.
    const [y, m, d] = pattern.untilDate.split("-").map(Number);
    return Date.UTC(y, m - 1, d, 23, 59, 59, 999);
  })();

  const results: Date[] = [];
  while (
    results.length < maxPerRun &&
    results.length < remainingByCount &&
    occurrence.getTime() <= horizon.getTime() &&
    occurrence.getTime() <= untilTime
  ) {
    results.push(new Date(occurrence));
    occurrence = advance(occurrence, pattern.frequency, anchorDay);
  }
  return results;
}
