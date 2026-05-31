-- 00085 — list_event_rules_with_inherited RPC (Phase 4 R2).
--
-- Founder framing 2026-05-10: rules are scoped at 5 levels and a user
-- looking at an event needs to see what applies, not just what was
-- authored at the event level. This RPC returns all rules that apply
-- to a single event, drawn from three buckets per Taxonomy §29:
--
--   1. resource scope — rules.resource_id = p_event_id
--   2. series scope    — rules.series_id  = resources.series_id of the event
--                        AND rules.resource_id IS NULL
--   3. group  scope    — rules.group_id   = event's group
--                        AND resource_id IS NULL AND series_id IS NULL
--
-- iOS classifies each returned row by inspecting `resource_id` and
-- `series_id`:
--   - resource_id set                       → resource-scoped
--   - series_id  set AND resource_id null   → series-scoped
--   - both null                              → group-scoped (module_key
--                                              distinguishes user-authored
--                                              from platform defaults)
--
-- Membership scope (`rules.membership_id`) is orthogonal and intersects
-- with any of the three above; the per-event view shows it transparently
-- (a membership-scoped rule that ALSO references this resource still
-- shows up under "resource"). Phase 4b adds a UI affordance to surface
-- the membership constraint.

create or replace function public.list_event_rules_with_inherited(p_event_id uuid)
returns setof public.rules
language sql security definer set search_path = public stable as $$
  -- 1. resource scope
  select r.*
    from public.rules r
   where r.resource_id = p_event_id

  union all

  -- 2. series scope (only fires when the event's resource row has a
  --    series_id set)
  select r.*
    from public.rules r
    join public.resources res on res.id = p_event_id
   where res.series_id is not null
     and r.series_id = res.series_id
     and r.resource_id is null

  union all

  -- 3. group scope (catches both user-authored group rules and
  --    platform-shipped defaults via module_key — caller distinguishes)
  select r.*
    from public.rules r
    join public.resources res on res.id = p_event_id
   where r.group_id = res.group_id
     and r.resource_id is null
     and r.series_id is null;
$$;

revoke execute on function public.list_event_rules_with_inherited(uuid) from public, anon;
grant  execute on function public.list_event_rules_with_inherited(uuid) to authenticated;

comment on function public.list_event_rules_with_inherited(uuid) is
  'Returns all rules applicable to an event in one query: event-scoped, series-scoped (if the event is part of a series), and group-scoped. iOS reads each row''s resource_id/series_id to bucket the result. Phase 4 R2.';
