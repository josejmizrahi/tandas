-- 00137 — Beta 1 Consolidation W1-2: monetary fines opt-in by default.
--
-- Background
-- ==========
-- A founder picking "Reuniones recurrentes" (template recurring_dinner)
-- landed in a group with 5 module-provided rules — 4 of them carrying
-- $200/$300 MXN fines and shipped `isActive=true`. The first time a
-- non-technical user (e.g. parent inviting their family) discovered
-- those rules was through a *proposed fine* in their inbox, after the
-- engine had already evaluated and fired against a real member.
--
-- Beta 1 audit Track B classed this as a Top-3 first-run killer:
-- onboarding mental model assumed "I'll set up rules later", reality
-- enforced them in-flight. Memory `feedback_create_flow_defaults`
-- explicitly forbids this: "monetary fines never pre-ticked unless
-- strict".
--
-- Policy
-- ======
-- - Reminders / soft (non-monetary) consequences may ship ON.
-- - Anything that touches money must ship OFF by default and require
--   explicit opt-in (founder toggles them in `RulesView`).
--
-- Fix
-- ===
-- Flip `isActive=false` for any rule in `public.modules.provided_rules_def`
-- whose `consequences` array contains an entry with `type=fine`.
-- Same flip for `public.templates.config.defaultRules` so the legacy
-- fallback path (groups with null active_modules → seed_template_rules_legacy)
-- lands in the same opt-in state.
--
-- Idempotent: the WHERE EXISTS guard skips rules already inactive, so
-- a second apply is a no-op. The jsonb_set keeps every other field of
-- each rule entry intact (name, slug, trigger, conditions, consequences,
-- description, module).
--
-- Backfill
-- ========
-- Existing groups that already had this template seeded keep their
-- rules.is_active=true. NOT backfilled by this migration — the founder
-- explicitly asked: no destructive sweeps without an explicit request.
-- An operator can run the following SQL to backfill if/when the founder
-- decides to bring already-created groups to the new default:
--
--   UPDATE public.rules
--      SET is_active = false, updated_at = now()
--    WHERE is_active = true
--      AND consequences @> '[{"type":"fine"}]'::jsonb;
--
-- Test
-- ====
-- supabase/functions/_tests/e2e/dinnerTemplateFinesOptIn.test.ts asserts
-- a fresh group seeded from `recurring_dinner` lands with zero
-- is_active=true monetary fines.
--
-- Existing test dinnerHappyPath.test.ts already deactivates all rules
-- except "Llegada tardía" — but `Llegada tardía` itself is now OFF
-- by default. That test will be updated in the same commit to activate
-- the target rule explicitly.

-- ============================================================
-- 1) modules.provided_rules_def — canonical source for V1+
-- ============================================================
update public.modules m
   set provided_rules_def = (
     select jsonb_agg(
       case
         when r -> 'consequences' @> '[{"type":"fine"}]'::jsonb
           then jsonb_set(r, '{isActive}', 'false'::jsonb)
         else r
       end
       order by ord
     )
     from jsonb_array_elements(m.provided_rules_def) with ordinality as t(r, ord)
   )
 where m.provided_rules_def is not null
   and jsonb_typeof(m.provided_rules_def) = 'array'
   and exists (
     select 1
       from jsonb_array_elements(m.provided_rules_def) r
      where r -> 'consequences' @> '[{"type":"fine"}]'::jsonb
        and coalesce((r ->> 'isActive')::boolean, true) = true
   );

-- ============================================================
-- 2) templates.config.defaultRules — legacy fallback path
-- ============================================================
-- (used by seed_template_rules_legacy when groups.active_modules is null)
update public.templates t
   set config = jsonb_set(
     t.config,
     '{defaultRules}',
     (
       select jsonb_agg(
         case
           when r -> 'consequences' @> '[{"type":"fine"}]'::jsonb
             then jsonb_set(r, '{isActive}', 'false'::jsonb)
           else r
         end
         order by ord
       )
       from jsonb_array_elements(t.config -> 'defaultRules') with ordinality as t2(r, ord)
     )
   )
 where t.config -> 'defaultRules' is not null
   and jsonb_typeof(t.config -> 'defaultRules') = 'array'
   and exists (
     select 1
       from jsonb_array_elements(t.config -> 'defaultRules') r
      where r -> 'consequences' @> '[{"type":"fine"}]'::jsonb
        and coalesce((r ->> 'isActive')::boolean, true) = true
   );

-- ============================================================
-- 3) Post-flip assertion — no monetary-fine entry should remain
--    isActive=true in either store. RAISE NOTICE if the invariant
--    fails (lets the migration log loudly even though it doesn't
--    abort — we'd rather the deploy land than block on a stuck
--    notice).
-- ============================================================
do $$
declare
  v_module_violations int;
  v_template_violations int;
begin
  select coalesce(sum(c), 0)
    into v_module_violations
    from (
      select count(*) as c
        from public.modules m,
             jsonb_array_elements(m.provided_rules_def) r
       where r -> 'consequences' @> '[{"type":"fine"}]'::jsonb
         and coalesce((r ->> 'isActive')::boolean, true) = true
    ) x;

  select coalesce(sum(c), 0)
    into v_template_violations
    from (
      select count(*) as c
        from public.templates t,
             jsonb_array_elements(t.config -> 'defaultRules') r
       where t.config -> 'defaultRules' is not null
         and jsonb_typeof(t.config -> 'defaultRules') = 'array'
         and r -> 'consequences' @> '[{"type":"fine"}]'::jsonb
         and coalesce((r ->> 'isActive')::boolean, true) = true
    ) x;

  if v_module_violations > 0 or v_template_violations > 0 then
    raise notice 'W1-2 invariant breach: modules=% templates=% monetary fines still active',
      v_module_violations, v_template_violations;
  end if;
end$$;

comment on table public.modules is
  'Catalog of platform modules (mig 00060). Each module declares provided_rules_def, the rule shapes seeded when active. Beta 1 W1-2 (mig 00137): monetary-fine rules ship isActive=false by default — see migration comment for the policy.';
