-- 00076 — Backfill `rules.module_key` from `modules.provided_rules`.
--
-- Phase A step 6 of L1 rules-architecture refactor (audit doc:
-- Plans/Active/L1_Audit_2026-05-10.md, Hallazgo 1).
--
-- After mig 00071 added the `module_key` column and 00072-00075 made
-- modules the canonical source of rule definitions, every rule that
-- was inserted before this refactor still has `module_key = null`.
-- The engine + archive cascade need that field set so they can
-- identify ownership.
--
-- Backfill strategy: join `public.rules` to `public.modules` where the
-- rule's slug appears in the module's `provided_rules` array. For V1
-- this resolves all 5 dinner_* rules to `basic_fines`. Phase 2+
-- modules will populate provided_rules in their seed migrations and
-- this same backfill pattern will work without code change.
--
-- Idempotent: only updates rows where module_key is null.

update public.rules r
   set module_key = m.id,
       updated_at = now()
  from public.modules m
 where r.module_key is null
   and r.slug = any(m.provided_rules);

-- Sanity: surface any rules that didn't get a module_key. These are
-- either platform-level (no module) or have a slug not registered in
-- any module's provided_rules. Log via raise notice — non-fatal.
do $$
declare
  v_orphans integer;
begin
  select count(*) into v_orphans
    from public.rules
   where module_key is null;

  if v_orphans > 0 then
    raise notice 'mig 00076: % rules remain with module_key=null (likely group-level or unknown slug)', v_orphans;
  end if;
end;
$$;
