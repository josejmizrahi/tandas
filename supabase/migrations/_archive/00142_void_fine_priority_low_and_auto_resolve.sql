-- 00142 — Beta 1 Consolidation W2-D1: void_fine emits correct priority
-- and stale fineVoided inbox rows auto-resolve.
--
-- Two related fixes.
--
-- 1. Wrong priority enum value
-- ============================
-- mig 00029:67 inserted `priority = 'normal'` into user_actions when a
-- fine was voided. `ActionPriority` (iOS Codable, RuulCore) is
-- {low, medium, high, urgent} — there is no `normal`. The Swift
-- decoder would have thrown on first encounter; the only reason it
-- never did is that no `fineVoided` row exists in prod (verified
-- 2026-05-13). Replaced with `'low'`: an anuled fine is informational,
-- not actionable.
--
-- 2. No resolver → permanent ghost rows
-- =====================================
-- `fineVoided` is an info-only action: there's no tap target, no
-- workflow to resolve. Pre-W2 the row would linger forever in the
-- user's inbox, with no way to dismiss except mass-archive. After
-- two months of real use the inbox would look corrupted.
--
-- Audit Track D #3 recommended either dropping the inbox write OR
-- giving the row a resolver. We keep the row (iOS has 7+ touchpoints
-- that render it — icon, label, history, attention sections) and
-- add a daily cron that auto-resolves rows older than 7 days. The
-- 7-day window gives the fined member enough time to notice "alguien
-- anuló mi multa" without leaving the inbox cluttered.
--
-- Idempotency: cron.schedule is upsert-by-name; void_fine is CREATE
-- OR REPLACE. Safe to re-apply.

-- =====================================================
-- 1. void_fine v2 — priority='low'
-- =====================================================

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

  -- W2-D1: priority='low' (was 'normal', not in ActionPriority enum).
  insert into public.user_actions (
    user_id, group_id, action_type, reference_id,
    title, body, priority
  ) values (
    f.user_id, f.group_id, 'fineVoided', f.id,
    'Multa anulada por admin: $' || trim(to_char(f.amount, 'FM999G999D00')),
    p_reason,
    'low'
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

comment on function public.void_fine(uuid, text) is
  'v2 (W2-D1, mig 00142): inserts user_action(fineVoided) with priority=''low'' (was ''normal'' which is not in ActionPriority enum). Pair with daily cron resolve-stale-fine-voided that auto-resolves rows older than 7 days.';

-- =====================================================
-- 2. resolve_stale_fine_voided — auto-resolver
-- =====================================================
--
-- Resolves any unresolved user_action with action_type='fineVoided'
-- older than 7 days. Returns the count of rows resolved so the cron's
-- log entry tells us how much sweeping happened.
--
-- SECURITY DEFINER: needs to bypass user-scoped RLS on user_actions
-- (the cron runs without an auth.uid()). The narrow WHERE clause
-- limits blast radius to one action_type.

create or replace function public.resolve_stale_fine_voided()
returns int
language plpgsql security definer set search_path = public as $$
declare
  v_count int;
begin
  with resolved as (
    update public.user_actions
       set resolved_at = now()
     where action_type = 'fineVoided'
       and resolved_at is null
       and created_at  < now() - interval '7 days'
    returning 1
  )
  select count(*) into v_count from resolved;

  return v_count;
end;
$$;

revoke execute on function public.resolve_stale_fine_voided() from public, anon, authenticated;

comment on function public.resolve_stale_fine_voided() is
  'W2-D1 (mig 00142): cron-only sweeper that resolves stale fineVoided user_actions older than 7 days. Returns row count for observability.';

-- =====================================================
-- 3. Daily cron
-- =====================================================
--
-- 03:20 UTC = 21:20 CDT (winter) / 22:20 CDT (DST). Off-peak for
-- the Mexico audience; matches other late-night sweepers.

select cron.schedule(
  'resolve-stale-fine-voided-daily',
  '20 3 * * *',
  $$select public.resolve_stale_fine_voided();$$
);
