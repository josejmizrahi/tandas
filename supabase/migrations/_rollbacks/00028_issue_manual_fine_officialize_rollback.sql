-- 00028 rollback — revert to pre-00028 state.
-- Order is reverse of forward (Part C → B → A) so the trigger and function
-- bodies match expectations at each intermediate step.

-- Part C reverted: issue_manual_fine without explicit status (falls through
-- to column default 'proposed').
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
declare
  f public.fines;
  r public.rules;
  v_snapshot jsonb;
begin
  if auth.uid() is null then raise exception 'auth required'; end if;
  if not public.is_group_admin(p_group_id, auth.uid()) then raise exception 'admin only'; end if;
  if not public.is_group_member(p_group_id, p_user_id) then raise exception 'target user not a member'; end if;
  if p_amount < 0 then raise exception 'amount must be non-negative'; end if;
  if length(coalesce(p_reason, '')) < 2 then raise exception 'reason required'; end if;

  if p_rule_id is not null then
    select * into r from public.rules where id = p_rule_id;
    if found then
      v_snapshot := jsonb_build_object('trigger', r.trigger, 'action', r.action, 'rule_title', r.title);
    end if;
  end if;

  insert into public.fines (
    group_id, user_id, amount, reason, rule_id, event_id,
    auto_generated, issued_by, rule_snapshot
  )
  values (
    p_group_id, p_user_id, p_amount, p_reason, p_rule_id, p_event_id,
    false, auth.uid(), v_snapshot
  )
  returning * into f;
  return f;
end;
$$;
revoke execute on function public.issue_manual_fine(uuid, uuid, numeric, text, uuid, uuid) from public, anon;
grant  execute on function public.issue_manual_fine(uuid, uuid, numeric, text, uuid, uuid) to authenticated;

-- Part B reverted: trigger fires only on UPDATE of status.
drop trigger if exists fines_after_status_change on public.fines;
create trigger fines_after_status_change
  after update of status on public.fines
  for each row execute function public.on_fine_officialized();

-- Part A reverted: on_fine_officialized body matches old.status='proposed' AND new.status='officialized'.
create or replace function public.on_fine_officialized()
returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if old.status = 'proposed' and new.status = 'officialized' then
    insert into public.user_actions (
      user_id, group_id, action_type, reference_id,
      title, body, priority
    ) values (
      new.user_id, new.group_id, 'finePending', new.id,
      'Multa pendiente: $' || trim(to_char(new.amount, 'FM999G999D00')),
      new.reason,
      'high'
    );

    perform public.record_system_event(
      new.group_id,
      'fineOfficialized',
      new.id,
      null,
      jsonb_build_object('amount', new.amount, 'rule_id', new.rule_id)
    );
  end if;
  return new;
end;
$$;
