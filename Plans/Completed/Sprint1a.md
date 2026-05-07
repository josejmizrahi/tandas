# Sprint 1a — Platform Foundation

Goal: lay the **platform** layer (generic Resource/Rule/Trigger/Condition/
Consequence/SystemEvent/UserAction) under the existing event-specific code,
without changing user-visible behavior. Sprint 1b wires the template
"Cena recurrente" on top; Sprint 1c builds Fines + Appeals + Inbox UI.

---

## What ships in Sprint 1a

### 1. Migration `00014_platform_foundation.sql`

Creates the platform tables alongside (NOT replacing) existing event-specific
tables. Dual-write activates in Sprint 1b/1c; `events` legacy table is
dropped in a posterior sprint after 2 weeks of paridad-verified production.

**New tables:**
- `resources` — generic envelope `(id, group_id, resource_type, status,
  metadata jsonb, created_by, created_at, updated_at)`. Empty in 1a; the
  abstraction is laid for 1b/1c to start writing into.
- `system_events` — append-only event log. Every action that may trigger a
  rule writes a row here. The rule engine consumes it.
- `user_actions` — unified inbox queue. Sprint 1c reads from this for the
  `ActionInboxView`.
- `appeals` — fine apelaciones with voting metadata.
- `appeal_votes` — anonymous per-member ballot rows (with aggregate view).
- `fine_review_periods` — 24h grace window for the host to review proposed
  fines before officializing.

**ALTERed tables:**
- `rules` — adds `name text`, `is_active bool`, `conditions jsonb`,
  `consequences jsonb`. Existing columns (`code`, `title`, `trigger`,
  `action`, `enabled`, `status`) preserved for backward compat. Sprint 1b
  starts writing the new shape; we drop the old columns in a posterior
  sprint after migration paridad is verified.

**New views:**
- `events_view` — projects from existing `events` table back to a Resource
  shape `(id as resource_id, 'event' as resource_type, group_id, status,
  metadata jsonb_build_object(...all event columns...), created_by,
  created_at, updated_at)`. In 1b/1c this becomes a UNION with `resources`
  filtered to type='event'; eventually it reads only from `resources`.
- `appeal_vote_counts` — aggregated counts per appeal for anonymity.

**New RPCs:**
- `record_system_event(group_id, event_type, resource_id, member_id, payload)`
- `start_appeal(fine_id, reason)` — creates appeal + appeal_votes for all
  eligible members + emits `appealCreated` system event.
- `cast_appeal_vote(appeal_id, choice)` — updates the row + emits
  `voteCast`.
- `close_appeal_vote(appeal_id)` — resolves based on quorum/threshold +
  emits `appealResolved`.

### 2. Swift platform models

All under `ios/Tandas/Platform/Models/`:
- `Resource.swift` (protocol), `ResourceType.swift`
- `Rule.swift`, `RuleTrigger.swift`, `RuleCondition.swift`,
  `RuleConsequence.swift`
- `SystemEvent.swift`, `SystemEventType.swift`
- `ConditionType.swift`, `ConsequenceType.swift`
- `UserAction.swift`, `ActionType.swift`, `ActionPriority.swift`
- `Appeal.swift`, `AppealVote.swift`, `AppealStatus.swift`

Conventions:
- `Sendable + Hashable + Codable`
- Enums declare ALL cases from the platform vision (24 SystemEventTypes,
  15 ConditionTypes, 14 ConsequenceTypes) so the model is V4-ready.
- Helpers/factory methods live in extensions to keep the type files small.

### 3. Swift platform repositories

`ios/Tandas/Platform/Repositories/`:
- `ResourceRepository.swift` — actor protocol + Mock + Live (Supabase)
- `SystemEventRepository.swift` — actor protocol + Mock + Live
- `UserActionRepository.swift` — actor protocol + Mock + Live
- `AppealRepository.swift` — actor protocol + Mock + Live (consumed in 1c)

`RuleRepository` already exists at `ios/Tandas/Supabase/Repos/`. Sprint 1a
extends it to support the new Rule shape (with `conditions`/`consequences`).

### 4. SystemEventEmitter service

`ios/Tandas/Platform/Services/SystemEventEmitter.swift` — convenience actor
that wraps SystemEventRepository. Used by every flow that may trigger a
rule (event closed, RSVP submitted, check-in recorded, etc.) so the call
site reads `await emitter.emit(.eventClosed, eventId: id, payload: ...)`.

### 5. Edge Functions — rule engine

TypeScript / Deno. Lives under `supabase/functions/`:

**`_shared/ruleEngine.ts`** — pure rule engine core, no Supabase calls:
- TriggerEvaluator interface + 4 V1 implementations (eventClosed,
  checkInRecorded, rsvpChangedSameDay, hoursBeforeEvent)
- ConditionEvaluator interface + 5 V1 implementations (alwaysTrue,
  responseStatusIs, checkInExists, checkInMinutesLate, eventDescriptionMissing)
- ConsequenceExecutor interface + 1 V1 implementation (fine)
- `runRule(rule, target, context) → ExecutionResult` orchestrator

**`process-system-events/index.ts`** — cron every minute. Picks
unprocessed `system_events`, finds matching rules, runs them, marks
processed.

**`evaluate-event-rules/index.ts`** — callable directly. Used when host
closes an event so fines appear immediately (no cron wait).

The other planned edge functions (`finalize-fine-reviews`,
`finalize-appeal-votes`, `start-appeal-voting`, `send-fine-payment-reminders`,
`auto-close-events` — last one already exists) ship in Sprint 1c when the
fines/appeals UI lands. Wiring them earlier creates dead code.

### 6. AppState wiring

`ios/Tandas/Shell/AuthGate.swift` — adds the new repos as `let` properties
with constructor injection. `TandasApp.swift` instantiates Live versions;
test/preview code uses Mock. Existing repos untouched.

### 7. Tests

- `Platform/Models/RuleCodableTests.swift` — round-trip Codable for the
  rich Rule shape (trigger/conditions/consequences as JSONB).
- `Platform/Repositories/SystemEventEmitterTests.swift` — emitter forwards
  to repo correctly.
- `supabase/functions/_shared/ruleEngine.test.ts` — Deno.test for each
  evaluator + the 5 default Cena rules end-to-end.

---

## What does NOT ship in Sprint 1a (intentional)

- **No UI changes.** No new views, no new tabs, no onboarding step changes.
  Sprint 1b owns this.
- **No data migration.** `events` table keeps all current data; nothing
  copies to `resources` yet. Sprint 1b/1c starts dual-write.
- **No fines/appeals UI.** Models + tables exist, no view consumes them.
  Sprint 1c.
- **No Inbox view.** UserAction model + table exist; no rendering. Sprint 1c.
- **Other consequence types** (loseTurn, serviceCompensation, etc.) —
  enum cases declared, executors throw `NotImplementedError`. Future phases.
- **Other condition types** (memberHasMultipleFines, fundBalanceAbove, etc.)
  — enum cases declared, evaluators throw `NotImplementedError`.

---

## Order of execution

1. Migration 00014 + rollback → apply via MCP
2. Swift platform models (pure types, no logic)
3. Swift repositories + SystemEventEmitter
4. AppState wiring
5. Edge Function rule engine + 2 critical functions
6. Tests
7. Commit + push to main

Each step compiles independently; nothing breaks existing user flows.

---

## Verification checklist before Sprint 1b starts

- [ ] Migration applied to Supabase prod, rollback tested in branch
- [ ] All existing event flows still work end-to-end (smoke test in sim)
- [ ] `record_system_event` RPC callable from Swift — manual test inserts
      a row with non-null `occurred_at`, null `processed_at`
- [ ] `process-system-events` cron picks it up within 1 min, marks
      `processed_at`
- [ ] Rule engine unit tests pass (`deno test`)
- [ ] Swift tests pass (`xcodebuild test`)
