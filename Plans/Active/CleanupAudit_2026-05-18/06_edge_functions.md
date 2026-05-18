# Edge Functions Audit — Ruul (read-only, 2026-05-18)

## 1. Function inventory

| Function | Trigger | LOC | Tests? | Verdict |
|---|---|---:|---|---|
| `process-system-events/index.ts` | none registered in DB (mig missing) | 687 | indirect (e2e dinnerHappyPath / autoCloseAndDeadline / palco / fund*) | Heart of engine, **no cron schedule found** |
| `dispatch-notifications` | cron `* * * * *` (mig 00030) | 374 | none direct | OK, uses claim RPC + RPC marks |
| `auto-close-events` | none registered | 112 | e2e autoCloseAndDeadline | OK; uses `bulk_close_stale_events` + `record_system_events_batch` RPCs |
| `auto-generate-events` | none registered | 307 | e2e recurrenceGenerator | OK; calls `create_event_v2`; mutates `resource_series.generated_until` (expected) |
| `finalize-votes` | none registered | 70 | e2e voteCastRace / appealQuorumFailed | OK, pure RPC |
| `finalize-fine-reviews` | none registered | 157 | none direct | **Direct INSERT into ledger_entries** bypasses `record_ledger_entry` RPC; direct INSERT into notifications_outbox |
| `send-fine-reminders` | none registered | 143 | none direct | Mutates `fines.details` directly (metadata write) |
| `send-event-notification` | iOS RPC (`EventNotificationDispatcher`) | 267 | none direct | JWT-gated, OK; direct INSERT into notifications_outbox |
| `emit-event-started-atoms` | cron `*/5 * * * *` (mig 00214) | 195 | none direct | Idempotent; pure |
| `emit-event-reminder-events` | cron `*/5 * * * *` (mig 00131) | 216 | e2e emitEventReminderEvents | OK |
| `emit-deadline-events` | **no cron** (suggested in comment only) | 106 | e2e autoCloseAndDeadline | Looks fine, but cron not scheduled |
| `emit-slot-system-events` | cron `*/5 * * * *` (mig 00069) | 144 | e2e palcoSharedResource | **Direct UPDATE `resources.status='expired'`** — doctrinal violation |
| `emit-asset-overdue-events` | cron mig 00227 (referenced in 00225 comment) | 248 | tests/asset_rules.test.ts | OK |
| `emit-space-no-check-in-events` | cron `*/5 * * * *` (mig 00270) | 203 | none direct | OK |
| `create-placeholder-member` | iOS RPC | 200 | none direct | JWT-gated, fan-out to send-whatsapp-invite |
| `send-otp` | iOS RPC | 147 | none direct | OK |
| `verify-otp` | iOS RPC | 247 | none direct | OK; mutates `otp_codes.attempts/consumed_at` (own non-atom table, fine) |
| `send-whatsapp-invite` | iOS RPC + internal fan-out | 203 | none direct | OK |
| `generate-wallet-pass` | **no caller** in iOS (`WalletPassService`) | 43 | none | **DEAD** — stub returning 503, no Swift consumer found |

## 2. Duplication map — emit-* family

Every emitter repeats the same scaffold (~50 LOC):

1. `createClient(SUPABASE_URL, SERVICE_ROLE_KEY)` + `withSentry` boot
2. Time window math (`now`, `cutoff`, ISO conversions)
3. Candidate `SELECT` (varies per source table)
4. **Dedup pattern** — read `system_events WHERE event_type=X AND resource_id IN (...)` → build `Set` → filter
5. Build row payloads
6. `supabase.rpc("record_system_events_batch", { p_events: rows })`
7. `console.log` stats + JSON response

`emit-asset-overdue-events` runs the pattern twice in one file (checkout + maintenance). `emit-space-no-check-in-events` runs it with a 3-way filter (bookings retired / checked-in / dedup). The fan-out → filter → dedup → batch-insert is the canonical shape; should be extracted to `_shared/atomEmitter.ts` exposing something like:

```ts
emitAtoms(supabase, {
  eventType: "rsvpDeadlinePassed",
  candidates: [...],
  dedupBy: "resource_id" | "payload->>booking_id",
  dedupWindowMs?: number,
  buildPayload: (c) => ({...}),
})
```

Plus `recordSystemEventsBatch(supabase, rows)` wrapper to centralize the RPC call (currently the literal `record_system_events_batch` string is repeated in 5 files + `auto-close-events`).

The repetition has produced **inconsistent dedup semantics**: some use `(resource_id, event_type)` (event-started, deadline), others use `payload->>booking_id` (space-no-check-in, asset-maintenance), others use `(resource_id, event_type, occurred_at>cutoff)` (asset-overdue). A shared helper would force the choice to be explicit per call site.

## 3. Idempotency findings

| Function | Verdict | Notes |
|---|---|---|
| process-system-events | OK | v1.1 pre-dispatch dedup via `rule_evaluations.idempotency_key` UNIQUE (engine §4); per-sink fallbacks |
| dispatch-notifications | OK | RPC `claim_pending_outbox` uses FOR UPDATE SKIP LOCKED |
| auto-close-events | OK | `bulk_close_stale_events` RPC + status filter; emit step has no dedup but only fires once per row |
| auto-generate-events | OK | partial UNIQUE `uniq_events_series_starts_at` (mig 00126) |
| finalize-votes | OK | `finalize_vote` RPC returns cached resolution |
| finalize-fine-reviews | WARN | `officialized_at` set-once gate prevents reprocess; **but ledger insert is NOT idempotent** — a crash between atom insert and `officialized_at` mark could double-emit on retry. No `idempotency_key` on `ledger_entries.metadata.fine_id` lookup |
| send-fine-reminders | OK | reminders[] array check before insert |
| send-event-notification | WARN | No outbox dedup; repeated call from iOS will fan-out duplicate pushes (collapse-id in dispatcher saves UX but not DB) |
| emit-event-started-atoms | OK | exact dedup `(resource_id, event_type='eventStarted')` |
| emit-event-reminder-events | OK | dedup `(resource_id, payload->>hours)` |
| emit-deadline-events | OK | dedup `(resource_id, event_type)` |
| emit-slot-system-events | OK | dedup + status flip |
| emit-asset-overdue-events | OK | 24h dedup window |
| emit-space-no-check-in-events | OK | 24h dedup window |
| create-placeholder-member | OK | `finalize_placeholder_member` RPC is atomic |
| send-otp / verify-otp | OK | hash + consumed_at |
| send-whatsapp-invite | unknown (not read) | |

## 4. Doctrinal violations

1. **`emit-slot-system-events:121`** — direct `.from("resources").update({ status: "expired" })`. Should be a `mark_slot_expired(slot_id)` RPC that emits the atom + flips state in a transaction. The current shape splits truth from atom: status moves outside the atom's transaction.
2. **`finalize-fine-reviews:100-117`** — direct `.from("ledger_entries").insert(...)`. `record_ledger_entry` RPC exists since mig 00082; bypassing it skips whatever validation/trigger choreography that RPC composes.
3. **`process-system-events:117-121`** — `markProcessed` writes `payload = { results }` alongside `processed_at`. The append-only guard at mig 00162 only permits `processed_at: null → ts` with everything else unchanged. **The DB will reject this UPDATE whenever `results` is non-empty**, and the `await` swallows the error (no `.error` capture). Effect: `processed_at` never advances when rules fired; events re-process forever (or the guard hasn't shipped to prod; either way, contradiction).
4. **`send-fine-reminders:94-97`** — direct `.from("fines").update({ details: ... })` mutates a stored projection column. The "reminders[]" record should arguably be an atom (`fineReminderSent`) plus a derived projection, not a destructive merge into `details`.
5. **`process-system-events:489-505` `resolveResourceHostMember`** — reads `resources.metadata.host_id` instead of consulting an `event_host_view` / canonical host projection. Drift risk if host_id mechanism changes.
6. **`emit-asset-overdue-events`** uses `.in("payload->>maintenance_event_id", loggedIds.map(id => id.toString()))` — PostgREST nested JSON `IN` filter is brittle (depends on jsonb text quoting). Same pattern at `emit-space-no-check-in-events:121/159`.

## 5. Dead functions

> **CORRECTION 2026-05-18 post-execution** — re-verified against deployed
> state via `list_edge_functions` + reading the docstrings:
> - `generate-wallet-pass` is **NOT dead**: it's an *intentional* 503 stub
>   that exists so iOS `WalletPassService.isAvailable` reports false. The
>   docstring is a self-implementation guide for when wallet creds are
>   configured. Deleting it would break the iOS contract (404 vs 503).
> - `send-fine-reminders` is **NOT dead**: production-quality, just
>   un-scheduled (suggested `0 12 * * *`). The "missing cron" is a
>   deployment gap, not dead code.
>
> See `11_post_execution_corrections.md` §1-2.

No truly dead functions found — every function in `supabase/functions/`
has at least one of: cron schedule, iOS caller, or an intentional-stub
contract documented in its docstring.

## 6. Naming inconsistencies

Current verbs in use:
- `emit-*` (5): emit-event-started-atoms, emit-event-reminder-events, emit-slot-system-events, emit-deadline-events, emit-asset-overdue-events, emit-space-no-check-in-events — but one is suffixed `-atoms` (the rest are `-events`).
- `auto-*` (2): auto-close-events, auto-generate-events
- `finalize-*` (2): finalize-votes, finalize-fine-reviews
- `process-*` (1): process-system-events
- `dispatch-*` (1): dispatch-notifications
- `send-*` (4): send-event-notification, send-fine-reminders, send-otp, send-whatsapp-invite
- `create-*` (1): create-placeholder-member
- `verify-*` (1): verify-otp
- `generate-*` (1): generate-wallet-pass

Proposed normalization:
- All scan-and-emit crons → `emit-<atom>` (drop `-events` / `-atoms` suffix):
  - `emit-event-started-atoms` → `emit-event-started`
  - `emit-event-reminder-events` → `emit-event-reminder`
  - `emit-slot-system-events` → `emit-slot-expired`
  - `emit-deadline-events` → `emit-rsvp-deadline-passed`
  - `emit-space-no-check-in-events` → `emit-space-no-check-in`
- `auto-close-events` is conceptually `emit-event-closed-stale` — same family, awkward to rename without code churn; OK to keep `auto-*` for "deadline-driven side effect" verb.
- `finalize-*` vs `auto-close-*` overlap — both close lifecycle. Acceptable distinction: `finalize-*` calls an RPC per row, `auto-close-*` runs a bulk RPC. Worth documenting.

Renaming requires migration churn (`cron.schedule` names) so this is housekeeping not blocking.

## 7. `_shared/ruleEngine.ts` audit

Scope hierarchy + precedence: **implemented and exported for tests** (`selectMostSpecificPerSlug`, `ruleScopeRank` lines 647-682). Order: occurrence > series > module > group; membership is orthogonal. Matches doctrine.

Idempotency contract (lines 405-431, 838-859): pre-dispatch `tryRecordEvaluation` writes `rule_evaluations` with UNIQUE on `idempotency_key`. Sink returns false on conflict → engine skips. **Sound**, but two failure modes:

- Lines 638-640: if the audit insert ERRORs (not just conflicts), sink returns `true` (permit dispatch). Logged as warning. Means transient DB errors yield duplicate consequences on retry. Acceptable trade-off documented inline.
- Lines 612-616: legacy rules with no `rule_versions` row also return `true`. Per-sink ad-hoc dedup (e.g. `proposeFine` checks fines_view) is the fallback. Coverage gap: `emitWarning`, `bumpWaitlistPriority` have payload-level dedup; `startVote`, `transferRight`, `revokeRight`, `suspendRight`, `setBookingsLocked`, `expireBooking` rely entirely on server-side RPC idempotency. Mostly OK because each cited RPC short-circuits on already-applied state, but `startVote` has NO server-side dedup for "rule X already opened a vote on entity Y this hour" — re-firing on the same atom for a legacy (no version) rule would open dup votes.

Brittle spots:
- `payload->>priority_bumped_by` filter in `bumpWaitlistPriority` (line 654) — same nested-JSON filter pattern flagged in emit-* functions.
- `resolveConsequenceTargets` only handles `$trigger.actor`, `$resource.host`, `$role.<id>` selectors. Unknown selector falls through to `$trigger.actor` with a warn log — fail-open.
- Condition tree walker (`evalConditionNode`) treats empty NOT child as empty AND (vacuous true → NOT → false). Documented but surprising.
- `failure()` helper duplicated between `ruleEngine.ts` and `ruleEngineConsequences.ts` (acknowledged in comment to avoid import cycle; minor smell).

`module_id` is hardcoded to null on the rule shape (lines 947-948 comment "Rules don't carry module_id in V1"). The phase_target maps (TRIGGER_PHASE/CONDITION_PHASE/CONSEQUENCE_PHASE) drift risk: adding a SystemEventType enum case without slotting it requires the codegen drift check to catch.

## 8. Beta blockers

1. **`process-system-events markProcessed` will be silently rejected by the atom guard whenever results are recorded.** ✅ FIXED in commit `bc5a806` (2026-05-18). Dropped the `update.payload = { results }` write; per-rule audit stays in `rule_evaluations` per RuleEngineDoctrine §4.
2. ~~No DB cron schedule found for `process-system-events`~~ **FALSE ALARM** — verified via `SELECT * FROM cron.job`. Cron `process-system-events-every-minute` is ACTIVE; was set up in Supabase dashboard before the mig 00030+ pattern was adopted. Same for 10+ other "missing" crons. See `11_post_execution_corrections.md` §6 for full inventory.
3. **`emit-slot-system-events` direct status mutation** — violates atom-truth doctrine; refactor to RPC that emits `slotExpired` + flips `resources.status` atomically. Currently the atom and the truth can diverge if either side fails. (Not yet fixed.)
4. **`finalize-fine-reviews` direct `ledger_entries` insert** — use `record_ledger_entry` RPC. (Not yet fixed.)
5. **Dedup helper extraction** (low priority) — 5+ emit-* functions duplicate the candidate→dedup→batch shape; centralize before adding more.
6. **`finalize-votes` (generic finalizer) had no cron pre-2026-05-18** ✅ FIXED in commit `94592e1` via mig 00327. New cron `finalize-votes-every-15min` co-exists with `finalize-appeal-votes-15min` (which calls a deployed-not-in-repo edge fn — see task #18).
7. **3 deployed edge functions missing from repo source** — `finalize-appeal-votes`, `evaluate-event-rules`, `export-user-data`. Source/prod drift. Tracked as task #18. Audit didn't see these because it only grepped the repo. See `11_post_execution_corrections.md` §5.

## Key file paths
- `/Users/jj/code/tandas/supabase/functions/_shared/ruleEngine.ts`
- `/Users/jj/code/tandas/supabase/functions/_shared/ruleEngineConsequences.ts`
- `/Users/jj/code/tandas/supabase/functions/process-system-events/index.ts` (markProcessed bug line 117-121)
- `/Users/jj/code/tandas/supabase/functions/emit-slot-system-events/index.ts` (line 121 direct status update)
- `/Users/jj/code/tandas/supabase/functions/finalize-fine-reviews/index.ts` (line 100 direct ledger insert)
- `/Users/jj/code/tandas/supabase/functions/generate-wallet-pass/index.ts` (dead stub)
- `/Users/jj/code/tandas/supabase/migrations/00162_system_events_atom_guard.sql` (the guard that flags item #1)
- `/Users/jj/code/tandas/supabase/migrations/00030_dispatch_notifications_cron.sql` + 00069/00131/00214/00270 (only crons confirmed in repo)
