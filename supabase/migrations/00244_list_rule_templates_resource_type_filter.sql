-- 00244 — list_rule_templates accepts optional p_resource_type filter.
--
-- Closes the server-side half of the "asset-shouldn't-offer-late-arrival"
-- fix landed on iOS in 4822eb0. iOS already filters the gallery
-- client-side using the locally-cached rule_shapes registry; this
-- migration makes the same filter available server-side so:
--
--   1. Future clients without the iOS shape cache get the right list
--      out of the box (single canonical source of truth).
--   2. The filter is exercised in iOS tests that go through the repo
--      rather than reaching into the registry.
--   3. A future tightening of publish_rule_version can reuse the same
--      compatibility check to REJECT incompatible publications instead
--      of letting them land as dormant rules.
--
-- Signature
-- =========
-- list_rule_templates(p_resource_type text default null)
--   - null  → returns every active template (current behaviour;
--             backward-compatible for callers that pass no args).
--   - 'asset' / 'event' / 'fund' / etc. → filters templates whose
--             composition.trigger_shape_id resolves to a shape whose
--             valid_resource_types either:
--               * is empty (universal trigger), or
--               * contains the requested resource_type.
--
-- The check is on the trigger shape only. Conditions / consequences
-- operate on the rule target (which the trigger emits), so they
-- inherit compatibility from the trigger and don't need their own
-- type gate.
--
-- Data sanity guard: a template whose trigger_shape_id points at a
-- non-existent rule_shape gets filtered out when a resource_type is
-- specified (the EXISTS join returns false). That's the safe default —
-- a misconfigured template shouldn't surface in a scoped picker.
--
-- Idempotent: DROP the prior 0-arg overload first so the new 1-arg
-- signature (with `p_resource_type text default null`) accepts both
-- `list_rule_templates()` and `list_rule_templates('asset')` calls
-- without ambiguity. Without the drop, postgres would keep both
-- overloads and the 0-arg call resolution would be ambiguous.
--
-- Rollback: _rollbacks/00244_rollback.sql restores the prior 0-arg
-- body.

drop function if exists public.list_rule_templates();

create or replace function public.list_rule_templates(
  p_resource_type text default null
)
returns setof public.rule_templates
language sql
security invoker
stable
set search_path = public
as $$
  select rt.*
  from public.rule_templates rt
  where rt.status = 'active'
    and (
      p_resource_type is null
      or exists (
        select 1 from public.rule_shapes rs
        where rs.id   = rt.composition->>'trigger_shape_id'
          and rs.kind = 'trigger'
          and (
            rs.valid_resource_types = '{}'::text[]
            or p_resource_type = any (rs.valid_resource_types)
          )
      )
    )
  order by rt.sort_order, rt.display_name_es;
$$;

revoke execute on function public.list_rule_templates(text) from public, anon;
grant  execute on function public.list_rule_templates(text) to authenticated;

comment on function public.list_rule_templates(text) is
  'v2 (mig 00244): optional p_resource_type filters templates whose trigger shape doesn''t support the resource type. Null returns all (backward-compatible).';
