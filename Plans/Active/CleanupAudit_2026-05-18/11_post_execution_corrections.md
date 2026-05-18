# Post-Execution Corrections — Cleanup Audit 2026-05-18

> Written after starting to fix audit findings one by one. Several audit
> claims turned out to be wrong when cross-checked against the live Supabase
> project (via `mcp__supabase__list_edge_functions`, `cron.job`,
> `known_event_types` table, `orphan-allowlist.txt`). This doc enumerates
> the corrections so anyone re-reading the audit gets the accurate picture.

## False positives — items the audit flagged but were not actual problems

### 1. `generate-wallet-pass` is NOT dead
**Audit said:** Edge function dead (no caller, no cron) → delete the folder.
**Reality:** The function is an **intentional 503 stub**. Its docstring
documents the wallet creds wiring procedure and states the stub returns 503
specifically so iOS `WalletPassService.isAvailable` reports false. Deleting
it would break that contract (404 instead of 503 confuses iOS error
handling) and erase the implementation-readiness guide.
**Action taken:** None — DO NOT delete.

### 2. `send-fine-reminders` is NOT dead
**Audit said:** Edge function dead (no caller, no cron) → delete the folder.
**Reality:** Production-quality function that hasn't been scheduled yet. Its
own docstring says "Suggested schedule: `0 12 * * *` (daily at noon UTC)".
The implementation is complete: reads unpaid officialized fines, records
reminders idempotently in `fines.details.reminders[]`, emits
`fineReminderSent` via the V8-correct `record_system_event` RPC path. The
"missing cron" is a deployment gap, not dead code.
**Action taken:** None — DO NOT delete. Schedule decision is a product call.

### 3. `myAtom` is NOT in the production seed
**Audit said:** `myAtom` literal seeded into `known_event_types` —
"doctrinal smell — example value leaked into production seed".
**Reality:** `myAtom` does NOT exist in the `known_event_types` table
(verified via `SELECT event_type FROM known_event_types`). It only appears
as a placeholder in a doc-comment inside mig 00293's `register_event_type()`
documentation, and that single string is already explicitly allowlisted in
`scripts/codegen/orphan-allowlist.txt:21` with the comment "Doc-comment
placeholder in mig 00293 register_event_type() example".
**Action taken:** None — no seed entry to drop.

### 4. The "9 missing SystemEventType cases" was 7 already-allowlisted + 2 actually-missing
**Audit said:** 9 atoms in DB not in Swift enum, "Beta-1 surface gap".
**Reality:** Cross-check against `orphan-allowlist.txt`:
- **7 of 9** (`slotCreated`, `slotReleased`, `assetBookingsLocked`,
  `assetBookingsUnlocked`, `identityPromoted`, `rightMetadataUpdated`,
  `groupRolesChanged`) were ALREADY explicitly allowlisted as intentional
  deferred backlog by commit `16c1329 chore(codegen): allowlist 10 orphan
  atoms unblocking ios-ci` with per-line provenance and a "promote to
  Swift case once iOS consumes" doctrine.
- **`memberCapabilityOverrideDeactivated`** was genuinely missing and not
  allowlisted.
- **`eventReopened`** (introduced by mig 00295) was genuinely missing.
- **3 dot-notation atoms** (`member.claimed`, `member.merge_declined`,
  `member.placeholder_created` — mig 00314) cannot be Swift enum cases
  at all because `scripts/codegen/parser.ts` CASE_RE only matches
  camelCase identifiers. Would need either a DB rename or a parser
  extension to support `case name = "raw.value"` mapping.

**Action taken:** commit `d36cdbc` promoted `eventReopened` to the Swift
enum (full propagation: case + humanLabel + isImplementedInV1 +
HistoryItemPresentation arm + regenerated `SystemEventType+Codable.swift`
via `make gen`), and allowlisted the 4 others with explanatory comments.

## True new findings — discovered during fix execution

### 5. Three deployed edge functions are NOT in `supabase/functions/`
`mcp__supabase__list_edge_functions` returned 22 ACTIVE functions; only 19
exist in the repo. The 3 orphans:

- **`finalize-appeal-votes`** (v6, ACTIVE) — distinct from `finalize-votes`.
  Reads the `appeals` table, calls `close_appeal_vote()` RPC, handles
  quorum + threshold + fine voiding. The audit thought its cron was hitting
  a 404 because the audit only grepped the repo. Cron is real.
  **Action taken**: source restored to `supabase/functions/finalize-appeal-votes/index.ts`. Self-contained (no `_shared/` deps); matches the prod-deployed bytes exactly.

- **`export-user-data`** (v1, ACTIVE) — GDPR/CCPA/LFPDPPP data portability
  feature. JWT-gated. Returns the calling user's data as a JSON payload for
  the iOS share-sheet flow. Referenced by `RuulCore/Repositories/ProfileRepository.swift`
  but no current iOS `functions.invoke("export-user-data")` callsite was
  found — likely awaiting iOS plumbing.
  **Action taken**: source restored to `supabase/functions/export-user-data/index.ts`.
  Known drift caveat documented in its docstring: SELECT reads
  `group_members.role` (dropped in mig 00303 — column is now `roles` jsonb).
  Returns null for that field on every row; doesn't crash. Fix scoped as a
  follow-up.

- **`evaluate-event-rules`** (v9, ACTIVE) — **DEAD on prod, restored as a 410 stub.**
  Reads the `events` and `event_attendance` tables, both DROPPED in mig 00159.
  Per `Plans/Completed/Phase1.md` and `Plans/Active/Constitution.md` §5c-iii.C,
  this function was the V1 on-demand rule evaluator path, superseded by the
  `process-system-events` cron + atom-driven model. The deployed bytes
  would 500 on every invocation now (no `events` table to SELECT from).
  Zero active callers in code or migrations (only doc/spec mentions of the
  pre-Phase-2 RPC of the same name).
  **Action taken**: source restored as a tiny 410 Gone stub
  (`supabase/functions/evaluate-event-rules/index.ts`) so any rogue caller
  learns fast and the function appears in version control with a clear
  DEPRECATED marker + retrieval breadcrumb to the original 200-LOC body
  via `mcp__supabase__get_edge_function`. Dashboard undeploy still
  pending (task #20).

### 6. The "cron missing for process-system-events" worry was false alarm
**Audit said:** "no DB cron schedule found for `process-system-events` in
any migration grep. If true, the rule engine is dormant."
**Reality:** Cron `process-system-events-every-minute` is ACTIVE in prod
(verified via `SELECT * FROM cron.job`). It was set up via the Supabase
dashboard before the migration-tracked cron pattern (mig 00030+) was
adopted. Same applies to `auto-close-events-hourly`,
`emit-asset-overdue-events-5min`, `expire-due-rights-every-hour`,
`fail-stale-data-rights-every-5-minutes`, `finalize-appeal-votes-15min`
(pre-correction), `finalize-fine-reviews-hourly`,
`notify-rights-expiring-soon-daily`, `reconcile-stuck-appeals-30min`,
`reset-stale-outbox-every-5-minutes`, `resolve-stale-fine-voided-daily`.

**Cron inventory at 2026-05-18** (post-mig-00327/00328):

| Job | Schedule | Calls |
|---|---|---|
| process-system-events-every-minute | `* * * * *` | edge fn |
| dispatch-notifications-every-minute | `* * * * *` | edge fn (mig 00030) |
| auto-close-events-hourly | `0 * * * *` | edge fn |
| emit-asset-overdue-events-5min | `*/5 * * * *` | edge fn |
| emit-event-reminder-events-5min | `*/5 * * * *` | edge fn (mig 00131) |
| emit-event-started-atoms-5min | `*/5 * * * *` | edge fn (mig 00214) |
| emit-slot-system-events-5min | `*/5 * * * *` | edge fn (mig 00069) |
| emit-space-no-check-in-events-5min | `*/5 * * * *` | edge fn (mig 00270) |
| expire-due-rights-every-hour | `17 * * * *` | RPC `expire_due_rights()` |
| fail-stale-data-rights-every-5-minutes | `*/5 * * * *` | RPC `fail_stale_data_rights_requests()` |
| finalize-appeal-votes-15min | `*/15 * * * *` | edge fn `finalize-appeal-votes` (deployed-not-in-repo) |
| finalize-fine-reviews-hourly | `0 * * * *` | edge fn |
| finalize-votes-every-15min | `*/15 * * * *` | edge fn (added by mig 00327) |
| notify-rights-expiring-soon-daily | `7 12 * * *` | RPC `notify_rights_expiring_soon(14)` |
| reconcile-stuck-appeals-30min | `*/30 * * * *` | RPC `reconcile_stuck_appeals()` |
| reset-stale-outbox-every-5-minutes | `*/5 * * * *` | RPC `reset_stale_outbox_claims()` |
| resolve-stale-fine-voided-daily | `20 3 * * *` | RPC `resolve_stale_fine_voided()` |

Not scheduled (dead OR awaiting scheduling decision):
- `emit-deadline-events` — exists in repo, no cron. Docstring suggests `*/5 * * * *`.
- `auto-generate-events` — exists in repo, no cron.
- `send-fine-reminders` — exists in repo, no cron. Suggested `0 12 * * *`.
- `send-event-notification` — exists in repo, RPC-triggered (no cron needed).
- `send-otp` / `verify-otp` / `send-whatsapp-invite` — RPC-triggered.
- `create-placeholder-member` — RPC-triggered.
- `generate-wallet-pass` — intentional stub returning 503.

## Process correction for future audits

The audit was generated by 10 parallel agents grepping the repo. Several
false negatives arose because the agents only saw the source tree. Going
forward:

1. **Cross-check edge fn "dead" verdicts with `list_edge_functions`** — a
   function in prod with no caller is still deployed and reachable.
2. **Cross-check cron "missing" verdicts with `SELECT * FROM cron.job`** —
   crons predating the migration-tracked pattern live in dashboard only.
3. **Cross-check seed claims with `SELECT * FROM <seed_table>`** — comment
   placeholders are not seed entries.
4. **Cross-check enum drift with `orphan-allowlist.txt`** — explicitly
   allowlisted "missing" cases are intentional deferred backlog, not bugs.

The 4 corrections above were caught only because each fix attempt
double-checked the underlying assumption before deleting/modifying.

## Commits produced 2026-05-18 (fix-by-fix execution)

| Commit | Audit ref | Verdict at time of audit | Reality |
|---|---|---|---|
| `bc5a806` fix(engine) markProcessed | §6 #4 BLOCKER-hard | Real bug | Confirmed real bug. Fixed. |
| `8b1ba97` fix(cron) repoint | §10 inferred 404 | 404 claim wrong | Reverted by 94592e1. |
| `94592e1` fix(cron) restore appeals | — | Self-correction | Net positive: kept the legitimate finalize-votes-every-15min addition. |
| `bb89e35` chore(cleanup) UI primitives | §4 dead code HIGH | Confirmed dead | -234 LOC deleted. |
| `acf7959` fix(ui) FUNDADOR label | §6 #12 | Confirmed | Label fixed. |
| `d36cdbc` fix(codegen) SystemEventType | §11 myAtom + 9 cases | Mostly wrong | Did the genuine 1 + allowlisted the rest. |
| `9f15d7e` refactor(core) folder move | §3 16 loose files | Confirmed | 14 moved (AppState + JSONCoding stay). |
| `c8ce9ec` docs(audit) deliverable | — | New | 12-file audit + corrections committed. |
| `2db41bd` chore(infra) restore edge fns | §6 finding | Drift discovered | finalize-appeal-votes + export-user-data restored to repo. |
| `c36b4a5` refactor(core) CapabilityID Wave-1 | §5 #4 BLOCKER-soft | Confirmed | Namespace introduced + V1Modules migrated. |
| `fdee2f4` refactor(core) CapabilityID Wave-2 | §5 #4 | — | CapabilityCatalog 35 declarations + 7 dependency arrays. |
| `b82da76` feat(resources) Variants/Intents | §3 25% landed | Confirmed | 2138 LOC infra + 321 LOC tests committed. |
| `fd96505` fix(slots) mark_slots_expired_batch | §6.4.1 BLOCKER-soft | Confirmed | Mig 00329 unifies atom + status flip transactionally. |
| `6b3fea8` fix(ledger) record_ledger_entry_system | §6.4.2 | Confirmed (partial) | Mig 00330. Service-role variant; 10 other system inserts deferred. |
| `6b78a1c` refactor(core) RuleScope | §5 §8 | Confirmed | RuleScope typed namespace + sweep. |
| `3ae034b` refactor(core) RuleTemplateCatalog extract | §4 §3 | Confirmed | -369 LOC from RuleTemplateRepository. |
| `0a426e7` refactor(core) RuleGovernanceCoordinator | §4 §3 | Confirmed | Service moved out of Repositories/. |
| `b8f0b63` test(repos) ResourceLinkRepositoryTests | §8 §9.1 BLOCKER | Confirmed | 10 @Test cases passing. |
| `8100fde` refactor(ui) drop Group+AmbientPalette | §1 §2.2 | Confirmed | UI no longer extends RuulCore.Group. |
| `332f32a` chore(infra) evaluate-event-rules stub | §6 §5 | New (post-audit) | 3rd deployed-not-in-repo restored as 410 Gone stub. |
| `7530671` refactor(core) CapabilityID Wave-3 | §5 #4 (cont.) | Confirmed | Variants + Intents migrated (post user unblock). |
| `c9e66ef` refactor(core) CapabilityID Wave-4 | §5 #4 (cont.) | Confirmed | RuleTemplateCatalog requiredCapabilities. |
| `576af81` refactor(features) CapabilityID Wave-5 (cherry) | §5 #4 (closure) | Confirmed | 19 Detail/Sections files migrated; sweep complete. |
| `0722967` Merge feature/post-create-intent → main | — | Integration | Sprint 2+3 + Detail toolbar + Wave-5 land on main. |
| `550aee2` Merge chore/atom-and-resource-integrity → main | — | Integration | Integrity chore on main. |

**Migrations applied to prod (2026-05-18):** 00327, 00328, 00329, 00330.

**Open items deferred to user:**
- Task #20: undeploy `evaluate-event-rules` from Supabase dashboard (no MCP delete tool).
- 10 system-side `ledger_entries` direct inserts inside plpgsql functions (mig 00148/00150/00155/00163/00196) — would benefit from migration to `record_ledger_entry_system` but each requires its own `CREATE OR REPLACE FUNCTION` migration; deferred.
- 3 out-of-namespace cap-id literals (`"expenses"`, `"contributions"`, `"payouts"`) in MoneySectionView + ResourceSummaryView — either catalog or remove.
