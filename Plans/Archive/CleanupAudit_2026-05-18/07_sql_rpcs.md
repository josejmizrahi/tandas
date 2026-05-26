# Ruul Supabase Migration & RPC Audit

## 1. Migration Tally

- **Total forward migrations:** 315 (numbered `00001`..`00326`, with 4 numeric gaps).
- **Last 5 by name:** `00322_has_permission_drop_legacy_role_column.sql`, `00323_finalize_placeholder_member_correct_permission_slug.sql`, `00324_merge_group_members_delete_before_update.sql`, `00325_universal_templates_full_alias_closure.sql`, `00326_merge_group_members_deactivate_not_delete.sql`.
- **Gaps in numbering:** `00044→00049`, `00216→00218`, `00270→00272`, **`00303→00315` (12-mig gap)**. Last gap likely a hand-edit/rebase that landed without backfill notes.
- **Duplicate-numbered pairs (concurrent branches that both landed):** `00285`, `00286`, `00287`, `00288`, `00295`. Each pair has different topics. These exist as parallel-merge artifacts — they are exactly what mig 00293's commentary calls out as a parallel-branch corruption pattern. **Verdict: doctrine/process risk; data still correct because contents differ, but ordering is undefined.**

## 2. Legacy Tables

| Table | Status |
|---|---|
| `events` | DROPPED in **00159** (cascade) |
| `event_attendance` | DROPPED in **00159** |
| `pots`, `pot_entries` | DROPPED in **00064** |
| `expenses`, `expense_shares` | DROPPED in **00064** |
| `payments` | DROPPED in **00064** |
| `appeal_votes`, `appeals` | DROPPED early; **re-created later** (mig in 00100s for fine-appeals) and then **dropped again** in 00285/00286 hardening — currently absent in latest schema |
| `vote_ballots` | DROPPED in favor of `vote_casts` |
| `modules`, `notification_tokens` | DROPPED (capability catalog code-side; notifications consolidated) |
| `capabilities` | DROPPED (catalog moved client-side per audit closeout) |
| `groups.fund_balance` column | DROPPED in **00078 big-bang**; later migrations only reference it in **comments** explaining doctrine ("never write back computed state"). The `fund_balance_view` projection is the canonical read. **No live reads anywhere.** |

**iOS still reads `events_view` and `attendance_view`** (5 call sites in `LiveEventRepository` / `LiveRSVP*`). These are **atom-derived projections** post-00152/00156/00158, so doctrine-compliant. No iOS code or edge function reads from dropped tables.

## 3. RPC Inventory

- **Unique RPCs in latest migrations:** 256 (case-insensitive).
- **Total `CREATE OR REPLACE FUNCTION` statements:** 589 → average **2.3× redeclarations per RPC**, with the heaviest:
  - `is_known_system_event_type` — **37** redeclarations (this is the exact pain mig 00293 was written to end)
  - `create_group_with_admin` — 14
  - `finalize_vote` — 12
  - `set_group_module`, `resolve_governance`, `build_resource_from_draft` — 11 each
  - `issue_manual_fine` — 10
- **RPCs called from iOS Swift Live repos:** 80 unique. **All 80 are defined** in the latest migration set — no missing RPCs from iOS side.
- **"Dead" RPCs in DB (176 unique names not called from iOS):** the bulk are trigger functions, internal guards (`*_atom_guard`, `is_known_*`), atom emitters (`emit_*`, `handle_*`, `on_*`), seeders called from other RPCs, and helpers — **not true dead code**. Truly suspicious: `check_in_attendee`, `create_event`, `create_event_v` (legacy v1 names, superseded by `close_event_no_fines`/`set_rsvp` paths), `cast_ballot`, `close_pot`, `create_expense_with_shares`, `resolve_fine_pending_action`, `resolve_fine_proposal_review`. **Verdict: ~12 legacy RPC declarations still resolvable in pg_proc** because no `DROP FUNCTION` was ever issued for them; risk = misleading surface area, not behavior.

## 4. Atom Guards

All 7 append-only tables have **BEFORE UPDATE OR DELETE** triggers in place:

| Table | Trigger source |
|---|---|
| `system_events` | mig 00162 `system_events_atom_guard` (later hardened mig 00275 with seq + tiebreak) |
| `vote_casts` | mig 00163 |
| `user_actions` | mig 00166 `user_actions_resolution_only_guard` (only `resolution_*` columns mutable) |
| `identity_atoms` | mig 00174/00175 |
| `rsvp_actions` | mig 00153 |
| `check_in_actions` | mig 00154 |
| `notifications_outbox` | dispatcher-only guard |

Plus newer ones: `resource_links` (00287), `bookings` (00216), `data_deletion_log` (00294). **Verdict: doctrine-compliant.**

## 5. Stale Whitelists

> **CORRECTION 2026-05-18 post-execution** — verified directly via
> `SELECT event_type FROM known_event_types`:
> - `myAtom` is **NOT** in the DB seed. It only appears as a placeholder
>   in mig 00293's `register_event_type()` doc-comment, and that string is
>   already explicitly allowlisted in `orphan-allowlist.txt:21`. The "drop
>   myAtom from seed" recommendation was based on a false reading.
> - Of the 9 "missing" Swift cases, **7 were already explicitly allowlisted**
>   in `orphan-allowlist.txt:28-34` as intentional deferred backlog (commit
>   `16c1329 chore(codegen): allowlist 10 orphan atoms unblocking ios-ci`),
>   each with provenance comments and "promote once iOS consumes" doctrine.
> - Genuinely new/missing post-audit: `eventReopened` (mig 00295) —
>   ✅ promoted to Swift enum in commit `d36cdbc`, AND
>   `memberCapabilityOverrideDeactivated` + 3 dot-notation `member.*`
>   atoms (mig 00314) — allowlisted in the same commit.
>
> See `11_post_execution_corrections.md` §3-4.

- `known_event_types` table (mig 00293, table-backed catalog) has **100 entries** (verified, no `myAtom`).
- Swift `SystemEventType` enum has **93 cases** post-`d36cdbc` (was 92).
- Drift correctly tracked in `scripts/codegen/orphan-allowlist.txt` (now 11 deferred entries with provenance).
- **Verdict: drift management is the doctrine — not a fix-the-enum task.**

## 6. Duplicate Triggers

The only multi-creation trigger name is `fines_after_status_change` (3× across 00016 → 00028 → 00150 → 00151), but each is a sequential `DROP TRIGGER IF EXISTS` + `CREATE TRIGGER` replacement, **not concurrent duplicates**. No silent double-fire risk found.

## 7. Unused Views / Functions

Of 26 views, 12 have **zero references** from iOS or edge fns (counting `_tests/` excluded):

`fund_balance_view`, `asset_current_custodian_view`, `asset_maintenance_status_view`, `asset_usage_history_view`, `asset_valuation_view`, `event_lifecycle_view`, `group_balances`, `group_members_with_founder`, `invite_preview`, `member_balances_per_group`, `member_balances_per_resource`, `my_activity_v`, `right_holders_view`, `slot_state_view` (despite mig 00282), `space_capacity_view`, `space_history_view`, `space_occupancy_view`, `vote_counts_view`. **`fund_balance_view` is referenced only by tests** despite being the canonical balance projection — iOS may be computing balance another way. **Confidence: high for the asset_* and space_* views; medium for fund_balance_view.**

Tables without RLS policy attached: `member_capability_overrides`, `otp_codes`, `system_event_payload_schemas`. **otp_codes is concerning** — should be service-role only by RLS default-deny, but worth verifying.

## 8. Metadata Truth Violations

- **No live writes** of `fund_balance`, `next_host_user_id`, `rotation_index`, `host_user_id`, `current_holder` to `metadata`.
- Mig 00188 enforces a **shape CHECK** on `resources.metadata` per type (event needs `title`+`starts_at`, fund needs `name`+`currency`, etc.) — only requires identity fields, not computed state. Doctrine-compliant.
- Patches via `metadata = metadata || jsonb_build_object(...)` exist for `booking_id`, `assigned_member_id` (slot identity) and for legacy `bookings_locked*` which mig 00284 then **strips back out** and replaces with `asset_booking_lock_view`. Lock state migration to atom-derived is **complete**.
- **Verdict: Article 7 / Projection Doctrine respected.**

## 9. Migration Churn (last 30)

Hot areas, all post-doctrine fixes per ConsistencyAudit:

1. **Roles & permissions (10+ migrations 00262 → 00322):** culminating in dropping `group_members.role` column (00303) and `has_permission` jsonb-only (00322). Long-running migration to remove a legacy column.
2. **Whitelist remediation (5+ migrations):** `00285_role_lifecycle_atom_whitelist_v2` → `_v3_reunion` → `_v4_reunion` → `00293_known_event_types_as_table` — explicitly documented as 4 failed parallel-branch reconciliations of the literal-array whitelist. mig 00293 finally moves to a table-based catalog. **Healthy fix, but the v2/v3/v4 sequence proves the problem.**
3. **Placeholder member merge (00315 → 00317 → 00323 → 00324 → 00326):** 5 migrations in 1-2 days fixing the same `_merge_group_members` RPC. **Active hot fix area.**
4. **Universal templates (00295 → 00321 → 00325):** Universal-template alias closure still incomplete (00325 = "full alias closure", but 00320/00321 added new ones after).

## 10. Doctrine Fit

| Doctrine | State |
|---|---|
| 6 frozen resource types | `is_known_resource_status` enforced; `resources.metadata` shape constraint in 00188 |
| Atoms append-only | All 7 atom tables guarded |
| `groups.roles` jsonb canonical | mig 00303 (drops `role` col), mig 00322 (drops legacy column from `has_permission`) |
| `fund_balance` column gone | Confirmed dropped 00078; only legacy in comments |
| `templates` not vertical | Aliasing in progress (00297, 00325) to replace `dinner_*`/etc. with universal names |
| `rule_evaluations` audit-only | Atom guard `rule_evaluations_atom_guard` present |
| `rule_shapes` runtime | Created (mig 00170+) — populated by templates |

## 11. Verdicts per Finding

| Finding | Severity | Class |
|---|---|---|
| Parallel duplicate-numbered migrations (5 pairs) | **MEDIUM** | Process / ordering |
| 12-migration gap 00303→00315 | LOW | Process |
| ~~Swift `SystemEventType` enum drift (9 missing cases)~~ | ✅ FIXED `d36cdbc` | 1 genuine promotion + 4 allowlisted with provenance |
| ~~`myAtom` literal in `known_event_types` seed~~ | **FALSE POSITIVE** | Not in seed; already allowlisted as doc-comment ref |
| Placeholder merge: 5 fixes in 2 days | MEDIUM | Hot fix — still settling |
| Universal-template aliasing not closed | MEDIUM | Doctrine in flight |
| Legacy RPC names (~12) never DROP'd | LOW | Surface noise |
| Views: `fund_balance_view` unused by iOS | MEDIUM | Either dead or iOS computing balance elsewhere — investigate |
| 17 other asset/space views unused | LOW | Likely premature |
| Tables without policy: `otp_codes`, `member_capability_overrides`, `system_event_payload_schemas` | MEDIUM | RLS gap (default-deny acceptable for `otp_codes` if used service-role-only) |
| 37 redeclarations of `is_known_system_event_type` | RESOLVED | mig 00293 fixed the pattern |

## 12. Beta Blockers

1. ~~`SystemEventType` Swift drift~~ ✅ FIXED in `d36cdbc`. Drift is now correctly managed via `orphan-allowlist.txt` for the 11 atoms iOS doesn't consume yet (per-line provenance), plus `eventReopened` was promoted to a real case. Rule templates targeting the deferred atoms still need iOS plumbing — that's a feature decision, not a drift bug.
2. **Placeholder merge stability** — 00324→00326 in the same direction (DELETE vs deactivate) means real-world reproduction is still happening. Needs a smoke test sign-off before Beta-1 demo.
3. **`fund_balance_view` not consumed by iOS** — if balance display is expected for Beta-1 fund verticals, the view must wire up or a divergent code path must be located.
4. **RLS verify on `otp_codes`** — confirm default-deny is sufficient.
5. **Universal-template aliasing still landing** (00325 = "full alias closure" then 00321 adds more) — confirm the *current* template seed matches `TemplateRegistry.swift` exactly before demo.

## Key Files

- `/Users/jj/code/tandas/supabase/migrations/00293_known_event_types_as_table.sql` — table-based whitelist (canonical pattern going forward)
- `/Users/jj/code/tandas/supabase/migrations/00188_resources_metadata_shape.sql` — type-aware metadata CHECK
- `/Users/jj/code/tandas/supabase/migrations/00326_merge_group_members_deactivate_not_delete.sql` — latest placeholder fix
- `/Users/jj/code/tandas/ios/Packages/RuulCore/Sources/RuulCore/PlatformModels/SystemEventType.swift` — needs 9 missing cases added
- `/Users/jj/code/tandas/ios/Packages/RuulCore/Sources/RuulCore/Capabilities/CapabilityCatalog.swift` — catalog ids healthy
