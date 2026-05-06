-- 00029 — void_fine adds status guard, reason guard, and emits
--          user_action(fineVoided) + system_event(fineVoided).
--
-- Two latent gaps in the original 00016 void_fine RPC:
--
--   1. No status guard. Voiding a paid fine succeeded silently — the row
--      flipped to status='voided' but `paid=true` stayed, leaving an
--      inconsistent state. Refunds are out-of-scope here; if you want to
--      undo a paid fine, use a separate restitution flow.
--
--   2. No reason guard. The contract requires a human-readable motive for
--      audit + the fined user's notification body. Empty reason produced
--      a notification with empty body.
--
--   3. Zero emissions. The fined user got NO user_action and NO
--      system_event when their fine was voided. They'd just notice the
--      fine moved to "Resueltas" the next time they refreshed.
--
-- Fix:
--   - Reject status not in (proposed, officialized).
--   - Reject reason of length < 2 (after coalesce).
--   - Insert user_action(action_type='fineVoided', priority='normal') for
--     the fined user.
--   - Emit system_event(event_type='fineVoided') with payload
--     {amount, reason, voided_by_user_id} for audit. The
--     voided_by_user_id key carries auth.uid() of the admin who voided
--     the fine — required for V2 multi-admin attribution; backfilling
--     this later from logs is ugly, so capture it at emit time.

create or replace function public.void_fine(p_fine_id uuid, p_reason text default null)
returns public.fines
language plpgsql security definer set search_path = public as $$
declare
  f public.fines;
  uid uuid := auth.uid();
begin
  if uid is null then raise exception 'not authenticated'; end if;
  select * into f from public.fines where id = p_fine_id;
  if f.id is null then raise exception 'fine not found'; end if;
  if not public.is_group_admin(f.group_id, uid) then
    raise exception 'only admins can void fines';
  end if;
  -- New guards (00029):
  if f.status not in ('proposed','officialized') then
    raise exception 'cannot void fine with status %', f.status;
  end if;
  if length(coalesce(p_reason, '')) < 2 then
    raise exception 'reason required';
  end if;

  update public.fines
     set status = 'voided',
         waived = true,
         waived_at = now(),
         waived_reason = p_reason
   where id = p_fine_id
   returning * into f;

  -- New emissions (00029):
  insert into public.user_actions (
    user_id, group_id, action_type, reference_id,
    title, body, priority
  ) values (
    f.user_id, f.group_id, 'fineVoided', f.id,
    'Multa anulada por admin: $' || trim(to_char(f.amount, 'FM999G999D00')),
    p_reason,
    'normal'
  );

  perform public.record_system_event(
    f.group_id,
    'fineVoided',
    f.id,
    null,
    jsonb_build_object(
      'amount', f.amount,
      'reason', p_reason,
      'voided_by_user_id', uid
    )
  );

  return f;
end;
$$;
revoke execute on function public.void_fine(uuid, text) from public, anon;
grant  execute on function public.void_fine(uuid, text) to authenticated;
