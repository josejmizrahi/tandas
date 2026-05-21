-- 00359 — Backfill shared pool to all active legacy groups
-- (SharedMoney Phase 1, brick 4).
--
-- Why this supersedes Option C
-- ============================
-- The original Phase 1 plan ratified Option C: "no auto-migration of
-- existing funds; legacy groups opt-in via seed_shared_pool_for_existing_group".
-- Founder override 2026-05-21: "ahorita no me importan los datos que
-- hay en supabase actualmente. si es mejor para el futuro cambiar
-- algo desde ahorita." → use the green light to make every group's
-- invariant uniform NOW so the downstream phases don't have to branch
-- on "does this group have a shared pool yet?".
--
-- What this brick does
-- ====================
-- For every ACTIVE group (archived_at IS NULL) that doesn't already
-- have a shared-pool fund row, INSERT one. The legacy fund rows
-- (named "Shamiz fondo" etc. in dev — neither is_shared_pool nor
-- is_protected_fund) STAY untouched. They remain user-owned funds
-- alongside the new shared pool. Phase 3 UI will decide how to
-- present them — likely as "Otros fondos" while the new shared pool
-- takes the canonical "Dinero compartido" slot.
--
-- After this migration applies, the invariant "every active group has
-- exactly one is_shared_pool=true fund row" holds platform-wide. The
-- `seed_shared_pool_for_existing_group` RPC introduced in mig 00357
-- stays installed as defensive infrastructure (in case a future race
-- creates a group without a pool, e.g., test fixtures bypassing
-- create_group_with_admin), but is no longer the primary onboarding
-- path for legacy groups.
--
-- Provenance stamps
-- =================
-- Backfilled rows get an extra `backfilled: true` flag so future audit
-- can distinguish "born at group-create time" (mig 00357 path) from
-- "retroactively seeded" (this mig). Other stamps:
--   * is_shared_pool   : true  (matches partial unique index in mig 00357)
--   * seeded_by_system : true
--   * seeded_at        : now() at backfill time
--   * backfilled       : true  (NEW — only on this path)
--   * currency         : groups.currency (founder § 9.1)
--   * name             : 'Dinero compartido' (founder § 9.2)
--
-- created_by is set to the group's original creator — semantically
-- correct (the creator caused both the group AND, indirectly via
-- doctrine 2026-05-21, its shared pool).
--
-- No atom emission (founder § 9.5): the backfill is not human
-- intent; the activity feed must not show "Daniel creó un fondo" for
-- every legacy group all at once.
--
-- Pre-flight (2026-05-21)
-- =======================
-- 3 active groups in DB, 0 with shared pool, all 3 have legacy fund(s).
-- Backfill creates 3 new fund rows. Existing 6 legacy fund rows stay.
-- Total expected post-mig fund count: 9. The partial unique index from
-- mig 00357 guarantees no double-seed if this mig is re-run.
--
-- Rollback
-- ========
-- _rollbacks/20260521154500_rollback.sql deletes ONLY the rows
-- stamped backfilled=true. Legacy funds untouched. Safe.

insert into public.resources (
  group_id, resource_type, status, metadata, created_by
)
select
  g.id,
  'fund',
  'active',
  jsonb_build_object(
    'name',                'Dinero compartido',
    'currency',            coalesce(g.currency, 'MXN'),
    'target_amount_cents', null,
    'is_shared_pool',      true,
    'seeded_by_system',    true,
    'seeded_at',           to_jsonb(now()),
    'backfilled',          true
  ),
  g.created_by
  from public.groups g
 where g.archived_at is null
   and not exists (
     select 1 from public.resources r
      where r.group_id = g.id
        and r.resource_type = 'fund'
        and (r.metadata->>'is_shared_pool') = 'true'
        and r.archived_at is null
   );
