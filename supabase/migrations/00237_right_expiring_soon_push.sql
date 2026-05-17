-- Mig 00207: enqueue push notification when a right enters its
-- pre-expiry warning window.
--
-- Bug closed
-- ==========
-- Mig 00203 shipped the `rightExpiringSoon` atom + the daily cron
-- that emits it. The activity feed renders the event (slice 11 wired
-- actor names), but the atom never reached APNs — the holder only
-- learned their right was about to expire next time they happened to
-- open the app. Audit flagged this as a missing UX surface.
--
-- Fix
-- ===
-- AFTER INSERT trigger on `system_events` filtered to event_type =
-- 'rightExpiringSoon'. Resolves the holder's `group_members.id` from
-- payload.holder_member_id and inserts a notifications_outbox row.
-- The `dispatch-notifications-every-minute` cron picks it up and
-- pushes via APNs. Deep link: `ruul://resource/<right_id>`.
--
-- Cadence: at most ONE push per right per expiration cycle, because
-- the atom emission itself is idempotent (mig 00203's
-- `metadata.expiration_warning_emitted` flag short-circuits subsequent
-- cron passes on the same right).
--
-- Why on rightExpiringSoon and not on the emitWarning consequence
-- =============================================================
-- The `right_expiration_warning` rule template uses emitWarning →
-- writes an activity-feed entry, but that's a passive surface.
-- Pushing on the atom itself ensures the holder gets notified even
-- when no rule template is active (the default UX expectation —
-- "tell me before my access vanishes" — shouldn't require an admin
-- to wire a rule). If groups want richer behavior (e.g. notify
-- ALSO the priority-next holder), they can author rules with
-- emitNotification or a custom consequence; that's additive.
--
-- Out of scope
-- ============
-- - Notify when right is transferred / revoked / suspended. Those
--   atoms fire on member-driven actions and the recipient typically
--   has UI context already (they just transferred it themselves, or
--   the admin who revoked sees the action sheet feedback). A future
--   slice can opt those in selectively if user testing flags missing
--   signals.
-- - Throttle / digest. Single right-per-day cadence is low enough
--   that batching adds complexity without payoff.

BEGIN;

create or replace function public.on_right_expiring_soon_notify()
returns trigger
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  v_holder_member_id uuid;
  v_recipient_user   uuid;
  v_right_name       text;
  v_days_left        int;
  v_expires_at       text;
  v_title            text;
  v_body             text;
begin
  if new.event_type <> 'rightExpiringSoon' then
    return new;
  end if;

  -- The mig 00203 cron always populates payload.holder_member_id;
  -- defensively fall back to event.member_id which the cron also
  -- sets to the same value.
  v_holder_member_id := coalesce(
    (new.payload->>'holder_member_id')::uuid,
    new.member_id
  );

  if v_holder_member_id is null then
    -- No holder to notify — skip. The atom row still lands so the
    -- activity feed renders the warning; nothing else to do.
    return new;
  end if;

  -- Verify the member is still active in the group. A right whose
  -- holder left the group keeps its atom emission but shouldn't
  -- queue a push that no token will accept.
  select gm.user_id into v_recipient_user
    from public.group_members gm
   where gm.id = v_holder_member_id
     and gm.group_id = new.group_id
     and gm.active = true;
  if v_recipient_user is null then
    return new;
  end if;

  v_right_name := coalesce(new.payload->>'name', 'Tu derecho');
  v_days_left  := nullif(new.payload->>'days_until_expiry','')::int;
  v_expires_at := new.payload->>'expires_at';

  -- Days-aware copy. The dispatch-notifications fn reads
  -- payload.title + payload.body for the APNs alert (index.ts:199);
  -- including them inline avoids the generic "ruul" / empty body
  -- fallback that triggers without them would surface.
  v_title := 'Tu derecho está por vencer';
  v_body := case
    when v_days_left is null or v_days_left > 1 then
      v_right_name || ' vence en ' || coalesce(v_days_left, 0) || ' días.'
    when v_days_left = 1 then
      v_right_name || ' vence mañana.'
    when v_days_left = 0 then
      v_right_name || ' vence hoy.'
    else
      v_right_name || ' está por vencer.'
  end;

  insert into public.notifications_outbox (
    group_id,
    recipient_member_id,
    notification_type,
    payload,
    deep_link
  ) values (
    new.group_id,
    v_holder_member_id,
    'rightExpiringSoon',
    jsonb_build_object(
      'title',              v_title,
      'body',               v_body,
      'right_id',           new.resource_id,
      'right_name',         v_right_name,
      'days_until_expiry',  v_days_left,
      'expires_at',         v_expires_at,
      'source_atom_id',     new.id
    ),
    'ruul://resource/' || new.resource_id::text
  );

  return new;
end;
$$;

revoke execute on function public.on_right_expiring_soon_notify() from public, anon, authenticated;

comment on function public.on_right_expiring_soon_notify() is
  'Enqueues a notifications_outbox row for each rightExpiringSoon atom — drives the APNs push so holders learn about pending expirations before next app open. v2 (00207b): includes title + body in payload for meaningful alert copy. Mig 00207.';

drop trigger if exists right_expiring_soon_notify on public.system_events;
create trigger right_expiring_soon_notify
  after insert on public.system_events
  for each row
  when (new.event_type = 'rightExpiringSoon')
  execute function public.on_right_expiring_soon_notify();

COMMIT;
