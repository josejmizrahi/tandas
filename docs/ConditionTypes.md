# ConditionTypes — Catalog

A `Rule` AND-combines conditions. Each condition has a `type` + `config`
jsonb. The engine evaluates them server-side via
`_shared/ruleEngine.ts:ConditionEvaluator`.

Defined in `Platform/Models/ConditionType.swift`.

## V1 implemented

| Case | What it checks | Config |
|---|---|---|
| `alwaysTrue` | No preconditions | `{}` |
| `responseStatusIs` | Member's RSVP equals a value | `{ "status": "pending" \| "going" \| "maybe" \| "declined" \| "waitlisted" }` |
| `checkInExists` | A check-in row exists (or doesn't) for the member on this event | `{ "exists": true \| false }` |
| `checkInMinutesLate` | Member's check-in late by ≥ threshold minutes | `{ "thresholdMinutes": Int }` — true when `lateMinutes >= threshold` |
| `eventDescriptionMissing` | Event description / menú is empty | `{}` |

## Reserved for later phases

| Case | Reason |
|---|---|
| `minutesAfterScheduled` | Time-based, future scheduler |
| `hoursBeforeEvent` | Used as synthetic trigger config in V1, not a standalone condition |
| `memberHasMultipleFines` | Behavioral history (V2+) |
| `memberFinesAbove` | "" |
| `memberMissedConsecutive` | "" |
| `eventDayOfWeek` | Calendar conditions |
| `eventTimeWindow` | "" |
| `fundBalanceAbove` | Fase posterior — fund module |
| `fundBalanceBelow` | "" |
| `rotationPositionEquals` | Rotation-aware (Fase 2+) |

Conditions of these types throw `NotImplementedError` server-side. The
engine logs structured + skips the rule. The architecture is V4-ready
without silently failing in production.

**Adding a condition**:
1. Add the case to the Swift enum.
2. Document the config schema in this file.
3. Implement `ConditionEvaluator` in `_shared/ruleEngine.ts`.
4. Update `isImplementedInV1` if it ships in V1.
5. Write a unit test under `_shared/ruleEngine.test.ts`.

## Combining conditions

Rules combine conditions with **AND**. There is no OR primitive — emulate
by splitting into separate Rules with the same trigger, each carrying one
of the OR branches.

Why no OR: keeps the engine deterministic + the rule UI simple. If you
need OR you usually want two distinct rules anyway.
