# SharedMoney — Phase 1 (Data model alignment)

**Status:** PLAN (no SQL yet)
**Sourced from:** founder doctrine 2026-05-21 (19 sections) + locked decisions:
1. Shared pool = default `resources(type='fund')` row, `metadata.is_shared_pool=true`.
2. Obligations are V1 but Phase 5 — Phase 1 does NOT touch them.
3. Existing funds in prod are NOT auto-migrated (Option C).

**Doctrine memory:** `doctrine_shared_money.md`. Re-read before touching this.

---

## 0. Phase 1 goals & non-goals

### In scope
- Schema: promote `metadata.source_event_id` → first-class `source_resource_id` column on `ledger_entries`. Add covering indexes.
- Seed: `create_group_with_admin` auto-seeds the shared pool row.
- Markers: `metadata.is_shared_pool=true` (new groups) + `metadata.is_protected_fund=true` (advanced create flow, Phase 6 surface — flag introduced now so the data model is forward-stable).
- Views: introduce the *base* projections needed by Phase 3/4 UI. Concretely:
  - `group_money_summary_view` (one row per group → balance compartido, total aportado, total gastado).
  - `resource_money_view` (one row per `source_resource_id` → spent / contributed / participants).
- Compatibility layer for `source_event_id` so old metadata + the existing 7-arg client surface keep working through the transition.

### Out of scope (Phase 2+)
- Any new RPC name (`record_shared_expense`, `contribute_to_shared_money`, `mark_obligation_paid`, `confirm_settlement`) — Phase 2.
- Obligations primitive (split, "tú debes", mark-paid, confirm) — Phase 5. **No tables, no views, no RPCs for obligations in Phase 1.**
- iOS UX vocab sweep (fondo → dinero compartido) — Phase 3.
- Resource Money Block UI — Phase 4.
- Protected Funds advanced create flow — Phase 6 (marker flag only in Phase 1).
- Auto-migration of existing funds in prod — Option C ratified. No data touched.

---

## 1. Backend audit (state today, 2026-05-21)

### `public.ledger_entries`
| Column | Type | Notes |
|---|---|---|
| `id` | uuid | pk |
| `group_id` | uuid NOT NULL | scoping |
| `resource_id` | uuid NULL | the **fund row** the money lives in (≠ source) |
| `type` | text NOT NULL | 'expense' / 'contribution' / 'settlement' / 'payout' / 'fine_issued' / 'fine_paid' / 'reimbursement' |
| `amount_cents` | bigint NOT NULL | always positive |
| `currency` | text NOT NULL default 'MXN' | |
| `from_member_id` | uuid NULL | money source (member). NULL when source is the pot. |
| `to_member_id` | uuid NULL | money recipient. |
| `metadata` | jsonb default `{}` | carries: `note`, `client_id` (idempotency), `source_event_id` (mig 00344), `paid_by_member_id` (mig 00355). |
| `occurred_at`, `recorded_at`, `recorded_by` | tz / uuid | bookkeeping |

**Today's data:** 31 entries in prod. **Zero** with `metadata.source_event_id`, **zero** with `metadata.paid_by_member_id`. No backfill burden.

### Existing money RPCs
- `fund_contribute(p_fund_id, p_amount_cents, p_currency, p_note, p_source_event_id, p_client_id)` — 6 args, mig 00351.
- `fund_record_expense(p_fund_id, p_amount_cents, p_to_member_id, p_currency, p_note, p_source_event_id, p_client_id, p_paid_by_member_id)` — 8 args, mig 00355 (just shipped).
- `fund_lock(p_fund_id, p_reason)` / `fund_unlock(p_fund_id)`.
- `record_settlement(p_group_id, p_from_member_id, p_to_member_id, p_amount_cents, p_currency, p_resource_id, p_note)`.
- `record_ledger_entry(...)` + `record_ledger_entry_system(...)` — generic inserters.

### Existing money views
- `fund_balance_view` — per `(fund_id, currency)` projection. Read by `LiveFundRepository`.
- `fund_lock_view` — atom-derived lock state.
- `member_balances_per_group` / `member_balances_per_resource` — already exist; check if they cover Phase 1's `group_money_summary_view` needs (likely a partial overlap; the new view will JOIN to `resources` for shared-pool filtering).

### `create_group_with_admin`
Today: 7 args, 3,077 chars body, **does NOT seed any fund row**. The shared pool seed has to land inside it (or in a paired RPC called from it) so the invariant "every new group has exactly one shared pool" is enforced at the only group-creation entry point.

### `source_event_id` consumers (full surface)
- **Server:** only the two RPC bodies (`fund_contribute`, `fund_record_expense`) write to `metadata.source_event_id`. No view, no projection, no trigger reads it today.
- **iOS:** 3 files reference it — `FundRepository.swift`, `RecordExpenseFromFundSheet.swift`, `ContributeToFundSheet.swift`. Param name `sourceEventId`.
- **Activity feed:** `HistoryItemPresentation.swift` does not read it.

Net: the rename surface is tiny. Promoting `source_event_id` → `source_resource_id` touches **5 files** total (2 server + 3 iOS) and **0 rows** of production data.

---

## 2. Migration list (names + purpose — no SQL yet)

Numbered after mig 00355.

### Mig 00356 — `ledger_entries_source_resource_id`
- ADD COLUMN `source_resource_id uuid NULL` on `public.ledger_entries`.
- Foreign key to `public.resources(id)` ON DELETE SET NULL.
- Partial index on `source_resource_id WHERE source_resource_id IS NOT NULL`.
- Covering index on `(group_id, source_resource_id)` to back the resource_money_view.
- **No backfill** — zero existing rows have `metadata.source_event_id` (audited).
- Comment doc explains: "Context, not flow. The event/asset/space the movement RELATES TO. Distinct from `resource_id` (the fund the money LIVES IN)."

### Mig 00357 — `shared_pool_marker_and_seed`
- Add helper `seed_shared_pool_for_group(p_group_id uuid)` SECURITY DEFINER. Inserts the canonical shared pool fund row with metadata stamps:
  - `is_shared_pool: true`
  - `seeded_by_system: true`
  - `seeded_at: now()`
  - `currency: <group's p_currency>` (locked § 9.1)
  - `name: 'Dinero compartido'` (locked § 9.2)
  - NO `fundCreated` atom emission (locked § 9.5).
- Idempotent: skip if a row with `is_shared_pool=true` already exists for the group.
- Patch `create_group_with_admin` to call the helper after admin seed, before commit.
- **Existing groups NOT seeded** (Option C). Add a separate ad-hoc RPC `seed_shared_pool_for_existing_group(p_group_id)` that admins can invoke later — Phase 3 will surface this via "Activar dinero compartido" if/when the user opts in. Not auto-run.

### Mig 00358 — `protected_fund_flag_no_op_today`
- Pure forward-compat marker. Documents the convention `metadata.is_protected_fund=true` for fund rows that should surface under the Protected Funds advanced surface (Phase 6). Adds a CHECK that `is_shared_pool` and `is_protected_fund` are mutually exclusive (a fund can't be both).
- No data change. No RPC change. Pure schema invariant + doc. Lets Phase 6 land without re-touching the data model.

### Mig 00359 — `source_event_id_to_source_resource_id_compat`
- Patch `fund_contribute` + `fund_record_expense` to **also write** the `source_resource_id` column (not only metadata) when `p_source_event_id` is supplied. Keep writing the legacy `metadata.source_event_id` key for one cycle so a stale iOS client doesn't break.
- Add `p_source_resource_id` as a new alias param (positional after `p_paid_by_member_id`) accepting the genericized id. When both `p_source_event_id` and `p_source_resource_id` are passed, prefer `p_source_resource_id`; raise on conflict.
- Drop the legacy 8-arg overload (`fund_record_expense(uuid,bigint,uuid,text,text,uuid,uuid,uuid)`) and the legacy 6-arg `fund_contribute` after CREATE OR REPLACE of the new 9-arg / 7-arg shapes. Mirrors the mig 00352 / 00354 overload-limbo guard.

### Mig 00360 — `group_money_summary_view`
- New view scoped per `(group_id, currency)`.
- Columns: `group_id`, `currency`, `shared_pool_balance_cents`, `shared_pool_in_cents`, `shared_pool_out_cents`, `last_activity_at`, `entry_count`. Reads `ledger_entries` filtered to the group's `is_shared_pool=true` fund row.
- Does NOT include protected fund balances (those still surface via `fund_balance_view`).
- Does NOT include obligations (Phase 5).
- Indexes: leverages mig 00356's `(group_id, source_resource_id)` and the existing `resource_id` index.

### Mig 00361 — `resource_money_view`
- New view scoped per `(group_id, source_resource_id, currency)`.
- Columns: `group_id`, `source_resource_id`, `currency`, `spent_cents`, `contributed_cents`, `entry_count`, `last_activity_at`, `payer_count` (distinct `paid_by_member_id`).
- Aggregates ledger entries where `source_resource_id IS NOT NULL`. Resource Money Block on Event/Asset/Space (Phase 4) reads this directly with `eq('source_resource_id', X)`.

---

## 3. RPC impact

| RPC | Phase 1 change | Why |
|---|---|---|
| `create_group_with_admin` | + call `seed_shared_pool_for_group` after admin seed | invariant: every new group has 1 shared pool |
| `seed_shared_pool_for_group` (NEW) | inserts the canonical fund row | reused by both create-flow + opt-in for existing groups |
| `seed_shared_pool_for_existing_group` (NEW) | admin-gated, idempotent opt-in | Option C migration path for old groups |
| `fund_contribute` | accept `p_source_resource_id`, write column + legacy metadata key | compat bridge |
| `fund_record_expense` | accept `p_source_resource_id`, write column + legacy metadata key | compat bridge |
| `record_settlement` | no change Phase 1 | Phase 2 will rename + adapt |
| `record_ledger_entry`, `record_ledger_entry_system` | no change Phase 1 | generic inserter — Phase 2 will add `p_source_resource_id` pass-through |

**No Phase 1 changes to:** `fund_lock`, `fund_unlock`, `record_settlement`, fine/vote RPCs.

**Permission gates:** unchanged. `is_group_member()` only on writers. `registrar ≠ aprobar` doctrine still holds. No new permission slugs introduced in Phase 1.

---

## 4. View impact

| View | Phase 1 action |
|---|---|
| `fund_balance_view` | unchanged. Continues backing `LiveFundRepository.listForGroup` / `get`. Both shared pool + protected funds surface here transparently — UX filters by `metadata.is_shared_pool` / `is_protected_fund` client-side. |
| `fund_lock_view` | unchanged |
| `member_balances_per_group` | unchanged Phase 1. Will be revisited in Phase 5 when obligations land. |
| `member_balances_per_resource` | unchanged Phase 1. Likely deprecated or folded into `resource_money_view` once Phase 4 lands. **Decision deferred to Phase 4.** |
| `group_money_summary_view` (NEW) | mig 00360 |
| `resource_money_view` (NEW) | mig 00361 |

**Deferred to later phases (not in Phase 1):**
- `member_obligations_view` → Phase 5.
- `group_money_activity_view` → Phase 3 (UI) or Phase 4 — activity feed already exists via `system_events` + `ledgerEntryCreated` atom. A dedicated view may not be needed if we extend the existing feed projection.

---

## 5. Compatibility with `source_event_id`

The old shape stays valid for one cycle. Concretely:

| Call shape | Behavior post-mig 00359 |
|---|---|
| client passes only `p_source_event_id` (old) | RPC writes to both `source_resource_id` column AND `metadata.source_event_id`. View reads from the column. No-op for the client; new view works for it. |
| client passes only `p_source_resource_id` (new) | RPC writes column. Does NOT write `metadata.source_event_id` (it's a generic ref now, may not be an event). |
| client passes both | RPC raises if values differ; if same, prefers `p_source_resource_id` and writes the column. |
| client passes neither | column NULL, metadata key absent. Legacy expense behavior. |

**Cycle-2 cleanup (Phase 2 candidate, not Phase 1):**
- Drop the `metadata.source_event_id` write path once iOS is on the new param everywhere.
- iOS rename `sourceEventId` → `sourceResourceId` in `FundRepository` + the two sheets (3 files).

---

## 6. ~~No auto-migration~~ → Backfill applied 2026-05-21 (Option C superseded)

**Original Option C posture** (kept for historical record): no auto-migration; legacy groups opt-in via admin RPC.

**Founder override 2026-05-21:** "ahorita no me importan los datos que hay en supabase actualmente. si es mejor para el futuro cambiar algo desde ahorita." → green-lit a one-time backfill. Mig 00359 applied: every active group now has its canonical shared pool row.

**What the backfill DID:**
- Inserted one `is_shared_pool=true` fund row per active group, stamped `backfilled=true` for audit distinguishability.
- `created_by` copied from the group's original creator (semantically correct provenance).
- Currency copied from `groups.currency`; name = "Dinero compartido".
- No `fundCreated` system_event emission (founder § 9.5 still holds).

**What the backfill did NOT do:**
- Touch the 6 legacy fund rows ("Shamiz fondo", etc.). Those stay as user-owned funds alongside the new shared pool. Phase 3 UI decides how to present them — likely "Otros fondos" while the new pool takes the canonical surface.
- Touch any `ledger_entries`.

**Post-backfill invariant:** every active group has exactly one `is_shared_pool=true` fund row. Phase 3 UI no longer needs a "Activar dinero compartido" affordance. The `seed_shared_pool_for_existing_group` RPC stays installed as defensive infrastructure (catches edge cases / future races) but is not on the happy path.

---

## 7. Shared pool as default fund row (canonical shape)

Schema invariant after mig 00357 lands for **new groups**:

```
resources row:
  resource_type = 'fund'
  group_id      = <group>
  metadata.is_shared_pool   = true
  metadata.is_protected_fund (absent)
  metadata.currency = <group default currency>
  metadata.name     = "Dinero compartido"     (default; user-renameable later)
```

Constraints (mig 00358):
- For any given group, AT MOST one row may have `is_shared_pool=true`.
- A row CANNOT have both `is_shared_pool=true` and `is_protected_fund=true`.
- `is_protected_fund=true` rows surface only in the Protected Funds advanced UI (Phase 6).
- Rows with neither flag = legacy funds in existing groups (Option C). They behave as today.

---

## 8. Obligations deferred to Phase 5 (but still V1)

Phase 1 explicitly does NOT introduce:
- An `obligations` table.
- A `member_obligations_view`.
- Any RPC named `mark_obligation_paid` / `confirm_settlement` / `record_shared_expense_with_split`.
- Any "split strategy" param on `fund_record_expense`.

Reasoning: the data model in Phase 1 must be load-bearing for Phase 2/3/4 *without* requiring Phase 5 to exist. By landing `source_resource_id` + the shared pool first, Phase 3 (Group Money UI) and Phase 4 (Resource Money Block) can ship and be testable even if obligations slip. When Phase 5 lands, the obligations table will be a pure ADDITION over the Phase 1 substrate — no Phase 1 columns need to change.

Phase 5 will:
- Add `obligations` table (or a derived view, decision deferred).
- Add `record_shared_expense` RPC with a `participants[]` + `split[]` shape that, on insert, both records the ledger entry AND generates one obligation row per participant.
- Add `mark_obligation_paid` / `confirm_settlement` RPCs.
- iOS: "Tú debes / Te deben" surface on Group Money + Resource Money Block.

---

## 9. Founder decisions (locked 2026-05-21)

1. **Currency on shared pool seed.** ✅ Copy `p_currency` from `create_group_with_admin` into `metadata.currency` of the shared pool. Stored at seed time, never re-derived.

2. **Naming of the seeded shared pool row.** ✅ Hard-coded "Dinero compartido" (V1 Spanish-only). Revisit when i18n lands.

3. **"Crear fondo por evento" path.** ✅ Gradual deprecation, not destructive kill:
   - **Phase 1:** backend keeps the legacy path alive so in-flight clients don't break. Add `@deprecated` comments in code + docs.
   - **Phase 3:** UI removes "crear fondo para evento" — replace with "registrar gasto relacionado con este evento" against the shared pool.
   - **Phase 6:** "Crear fondo separado" only inside the Advanced / Protected Funds surface.

4. **`member_balances_per_resource` view fate.** Deferred to Phase 4 plan. No Phase 1 action.

5. **Atom emission on shared pool seed.** ✅ NO `fundCreated` atom — auto-seed is not a human action and must not pollute the activity feed. BUT technical traceability is required: the seeded row stamps `metadata.is_shared_pool=true`, `metadata.seeded_by_system=true`, `metadata.seeded_at=now()`. Any future debug/audit needs to be able to tell user-created from system-seeded rows.

---

## 10. Phase 1 DoD

- [ ] Migrations 00356–00361 applied (in order, each with rollback file).
- [ ] `create_group_with_admin` seeds exactly one shared pool per new group; idempotent on retry.
- [ ] Existing 31 ledger entries in prod untouched; existing funds untouched.
- [ ] `group_money_summary_view` returns a row for every new group with balance 0 + counts 0.
- [ ] `resource_money_view` returns an empty rowset for a group with no expense activity; returns aggregated rows once a fund_record_expense with `p_source_resource_id` lands.
- [ ] `fund_contribute` / `fund_record_expense` accept both legacy `p_source_event_id` and new `p_source_resource_id`; mutual-exclusion guard raises on conflicting values.
- [ ] iOS still builds & ships unchanged (no client work in Phase 1 — backend backward compat absorbs everything).
- [ ] One smoke test per migration in a Supabase preview branch before applying to prod.

---

## 11. Phase 2 handoff

What Phase 2 (RPCs) needs from Phase 1 to start:
- `source_resource_id` column exists + indexed.
- Shared pool row exists for new groups (deterministic to look up by `(group_id, metadata.is_shared_pool=true)`).
- `group_money_summary_view` + `resource_money_view` exist so the new RPC names (`record_shared_expense`, `contribute_to_shared_money`) have something to project against.

What Phase 2 introduces:
- Wrapper RPCs `record_shared_expense(p_group_id, ...)` + `contribute_to_shared_money(p_group_id, ...)` that resolve the group's shared pool id internally and call into `fund_record_expense` / `fund_contribute`. iOS no longer needs to know the shared pool's `fund_id`.
- Compatibility layer: the old fund-targeting RPCs stay live (Protected Funds + legacy groups still use them).
- Phase 2 docs the deprecation timeline for the legacy iOS sheets.

---

## 12. Risks

- **Overload limbo on PostgREST** — mitigated by the mig 00352 / 00354 pattern (drop the prior overload after CREATE OR REPLACE the new shape). Re-applied in mig 00359.
- **Stale iOS clients** during the compat window — mitigated by writing both `source_resource_id` column AND `metadata.source_event_id` for one cycle.
- **Double-seed of shared pool** under create_group retry — mitigated by `is_shared_pool` partial unique index inside mig 00358 (one shared pool per group).
- **Hidden assumption that `resource_id` ≡ source** — code review of `fund_balance_view` and `member_balances_per_resource` before mig 00360/00361 to confirm they don't conflate.

---

**Next step:** founder answers § 9 open questions; I then start mig 00356 (the smallest, most reversible brick) as a standalone PR. After 00356 lands + verifies in prod, mig 00357 next. No big-bang.
