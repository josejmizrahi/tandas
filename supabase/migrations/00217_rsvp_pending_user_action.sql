-- 00145 — Beta 1 Consolidation W2-D5: rsvpPending inbox actions.
--
-- Bug
-- ===
-- iOS `ActionType.rsvpPending` has lived in the Swift enum and been
-- routed by 5 view files since the original platform layer — but no
-- migration ever INSERTed a single `rsvpPending` row. Dead code on
-- the client; missing surface on the server.
--
-- Founder's mental model (per Beta1Consolidation §3): the Inbox is
-- where pending RSVPs nag the user to confirm. Audit Track D #1
-- ranked this the #1 inbox-feels-broken risk: family beta WILL ask
-- "where's my RSVP nag list?"
--
-- Fix
-- ===
-- Trigger on `public.event_attendance` covering both directions:
--
--   INSERT case
--   -----------
--   When `create_event_v2` materializes one event_attendance row per
--   active member, fire an rsvpPending user_action for every member
--   whose RSVP starts as 'pending' (the default) AND who is not the
--   event host. The host is presumed to be going.
--
--   UPDATE case
--   -----------
--   When the member responds (rsvp_status flips from 'pending' to
--   anything else: going / maybe / declined / waitlisted), resolve
--   the user_action so it leaves the inbox immediately. Mirrors the
--   existing mig 00043 auto-resolve trigger for votes/fines.
--
-- The cancel-event cascade from W2-D4 (mig 00144) already includes
-- 'rsvpPending' in its dependent-action list — so cancelling an
-- event also wipes the open RSVP nag rows.
--
-- Body copy: "¿Vas a <title>? — Confirma tu asistencia."
-- Priority: 'medium' — actionable but not urgent.
--
-- Idempotency
-- ===========
-- event_attendance has a UNIQUE constraint on (event_id, user_id),
-- so the INSERT branch fires at most once per (event, user). The
-- UPDATE branch is guarded by `old.rsvp_status = 'pending' AND
-- new.rsvp_status <> 'pending'` — re-running with no transition is
-- a no-op.

create or replace function public.on_event_attendance_rsvp_action()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_host_id     uuid;
  v_group_id    uuid;
  v_event_title text;
begin
  -- INSERT path: new pending row, member is not the host → nudge.
  if tg_op = 'INSERT' and new.rsvp_status = 'pending' then
    select host_id, group_id, title
      into v_host_id, v_group_id, v_event_title
      from public.events
     where id = new.event_id;

    if v_group_id is null then
      -- Event row not found (orphan attendance row, shouldn't happen);
      -- silently bail rather than fail the INSERT.
      return new;
    end if;

    if v_host_id is null or v_host_id <> new.user_id then
      insert into public.user_actions (
        user_id, group_id, action_type, reference_id,
        title, body, priority
      ) values (
        new.user_id,
        v_group_id,
        'rsvpPending',
        new.event_id,
        '¿Vas a ' || coalesce(nullif(trim(v_event_title), ''), 'el evento') || '?',
        'Confirma tu asistencia.',
        'medium'
      );
    end if;

    return new;
  end if;

  -- UPDATE path: member responded → resolve the nag row.
  if tg_op = 'UPDATE'
     and old.rsvp_status = 'pending'
     and new.rsvp_status <> 'pending' then
    update public.user_actions
       set resolved_at = now()
     where user_id      = new.user_id
       and reference_id = new.event_id
       and action_type  = 'rsvpPending'
       and resolved_at  is null;
  end if;

  return new;
end;
$$;

revoke execute on function public.on_event_attendance_rsvp_action() from public, anon;
grant  execute on function public.on_event_attendance_rsvp_action() to authenticated, service_role;

drop trigger if exists trg_on_event_attendance_rsvp_action on public.event_attendance;
create trigger trg_on_event_attendance_rsvp_action
  after insert or update on public.event_attendance
  for each row
  execute function public.on_event_attendance_rsvp_action();

comment on function public.on_event_attendance_rsvp_action() is
  'W2-D5 (mig 00145): bidirectional trigger on event_attendance. INSERT path: nudges non-host members with rsvpPending user_action when create_event_v2 materializes their pending attendance row. UPDATE path: resolves the action when rsvp_status transitions out of pending.';
