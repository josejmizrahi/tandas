-- 00050 — issue_manual_fine accepts polymorphic resource_id.
-- (Originally numbered 00044 when applied to prod; file renamed to 00050 in repo
-- to resolve collision with parallel session 00044_auto_resolve_user_actions.
-- Migration name in prod supabase_migrations table remains
-- "00044_issue_manual_fine_resource_id" — applied 2026-05-08 22:25 UTC.)
--
-- V1 manual fines target Events. The dual-write trigger (00039) guarantees
-- resources.id == events.id for events, so existing callers passing only
-- p_event_id continue to work — the function now also writes that UUID
-- into fines.resource_id (the polymorphic FK added in 00041).
--
-- Phase 2+ callers can pass p_resource_id directly when the target is a
-- non-event resource (slot, fund, position, …). p_event_id may be NULL in
-- that case, since it's the legacy column being phased out.
--
-- Behavior change vs. 00028:
--   - new optional last parameter  p_resource_id uuid default null
--   - INSERT now writes BOTH event_id (legacy cohabitation) AND
--     resource_id  (canonical polymorphic FK).
--   - resource_id resolution: coalesce(p_resource_id, p_event_id)
--     V1 callers that pass only p_event_id get correct resource_id for free.
--     Phase 2+ callers that pass only p_resource_id leave event_id NULL.
--
-- Audit § 5.3 item 9 (pre-Fase 2 must) — closes the last polymorphism gap
-- in the fines write path. Auto-generated fines from the rule engine
-- already wrote resource_id (process-system-events:220).

drop function if exists public.issue_manual_fine(uuid, uuid, numeric, text, uuid, uuid);

create or replace function public.issue_manual_fine(
  p_group_id uuid,
  p_user_id uuid,
  p_amount numeric,
  p_reason text,
  p_rule_id uuid,
  p_event_id uuid,
  p_resource_id uuid default null
)
returns public.fines
language plpgsql security definer set search_path = public as $$
declare
  f             public.fines;
  r             public.rules;
  v_snapshot    jsonb;
  v_resource_id uuid;
begin
  if auth.uid() is null then raise exception 'auth required'; end if;
  if not public.is_group_admin(p_group_id, auth.uid()) then raise exception 'admin only'; end if;
  if not public.is_group_member(p_group_id, p_user_id) then raise exception 'target user not a member'; end if;
  if p_amount < 0 then raise exception 'amount must be non-negative'; end if;
  if length(coalesce(p_reason, '')) < 2 then raise exception 'reason required'; end if;

  if p_rule_id is not null then
    select * into r from public.rules where id = p_rule_id;
    if found then
      v_snapshot := jsonb_build_object(
        'trigger',     coalesce(r.trigger, to_jsonb(r.conditions)),
        'action',      coalesce(r.action,  to_jsonb(r.consequences)),
        'rule_title',  coalesce(r.title,   r.name),
        'rule_slug',   r.slug
      );
    end if;
  end if;

  -- Polymorphic backfill: resource_id is the canonical FK; event_id is V1
  -- cohabitation (legacy). For events the dual-write trigger ensures
  -- resources.id == events.id, so coalesce gives the right value with no
  -- extra lookup.
  v_resource_id := coalesce(p_resource_id, p_event_id);

  -- Sanity: when both are non-null, they must agree (or p_resource_id wins).
  -- Skipping a hard equality check here — Phase 2+ callers may legitimately
  -- pass a non-event resource_id alongside a NULL event_id; we'd only error
  -- if both are non-null AND different, which is an iOS bug, not a server
  -- concern. Treat p_resource_id as the source of truth.

  insert into public.fines (
    group_id, user_id, amount, reason, rule_id, event_id, resource_id,
    auto_generated, issued_by, rule_snapshot, status
  )
  values (
    p_group_id, p_user_id, p_amount, p_reason, p_rule_id, p_event_id, v_resource_id,
    false, auth.uid(), v_snapshot, 'officialized'
  )
  returning * into f;
  return f;
end;
$$;

revoke execute on function public.issue_manual_fine(uuid, uuid, numeric, text, uuid, uuid, uuid) from public, anon;
grant  execute on function public.issue_manual_fine(uuid, uuid, numeric, text, uuid, uuid, uuid) to authenticated;

comment on function public.issue_manual_fine(uuid, uuid, numeric, text, uuid, uuid, uuid) is
  'Issues a manual fine. Writes both event_id (legacy cohabitation) and resource_id (polymorphic FK, 00041). For V1 events these are the same UUID via dual-write trigger; Phase 2+ callers may pass p_resource_id for non-event resources with p_event_id NULL.';
