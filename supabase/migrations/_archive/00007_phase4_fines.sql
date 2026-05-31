-- Phase 4: fines
--
-- 1. Update close_event to invoke evaluate_event_rules so closing an event
--    auto-generates fines per the active rule engine.
-- 2. Add issue_manual_fine RPC for admin to assign a fine ad-hoc
--    (covers rule.trigger.type='manual' + arbitrary one-off cases).

create or replace function public.close_event(p_event_id uuid)
returns public.events
language plpgsql security definer set search_path = public as $$
declare
  e public.events;
  next_id uuid;
begin
  select * into e from public.events where id = p_event_id;
  if not found then raise exception 'event not found'; end if;
  if not public.is_group_admin(e.group_id, auth.uid()) then raise exception 'admin only'; end if;

  -- Run the rule engine FIRST so fines reference the still-scheduled event.
  -- evaluate_event_rules is idempotent (skips fines already created for the
  -- same (event_id, rule_id, user_id)), and it sets status='completed' at the
  -- end. We don't need to set status here.
  perform public.evaluate_event_rules(p_event_id);

  -- Re-read because evaluate_event_rules updated status + rules_evaluated_at
  select * into e from public.events where id = p_event_id;

  -- Roll the next event in the series (idempotent via parent_event_id)
  next_id := public.roll_event_series(p_event_id);
  return e;
end;
$$;

-- =========================================================
-- issue_manual_fine: admin issues a fine ad-hoc.
-- Used for rule.trigger.type='manual' rules and for one-off fines without
-- a backing rule (rule_id passed as null).
-- =========================================================
create or replace function public.issue_manual_fine(
  p_group_id uuid,
  p_user_id uuid,
  p_amount numeric,
  p_reason text,
  p_rule_id uuid,
  p_event_id uuid
)
returns public.fines
language plpgsql security definer set search_path = public as $$
declare f public.fines;
begin
  if auth.uid() is null then raise exception 'auth required'; end if;
  if not public.is_group_admin(p_group_id, auth.uid()) then raise exception 'admin only'; end if;
  if not public.is_group_member(p_group_id, p_user_id) then raise exception 'target user not a member'; end if;
  if p_amount < 0 then raise exception 'amount must be non-negative'; end if;
  if length(coalesce(p_reason, '')) < 2 then raise exception 'reason required'; end if;

  insert into public.fines (
    group_id, user_id, amount, reason, rule_id, event_id,
    auto_generated, issued_by
  )
  values (
    p_group_id, p_user_id, p_amount, p_reason, p_rule_id, p_event_id,
    false, auth.uid()
  )
  returning * into f;
  return f;
end;
$$;
revoke execute on function public.issue_manual_fine(uuid, uuid, numeric, text, uuid, uuid) from public, anon;
grant  execute on function public.issue_manual_fine(uuid, uuid, numeric, text, uuid, uuid) to authenticated;
