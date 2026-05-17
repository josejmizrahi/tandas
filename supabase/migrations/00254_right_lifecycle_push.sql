-- Mig 00208: push notifications for the rest of the right lifecycle.
--
-- Audit follow-up to mig 00207 (rightExpiringSoon push). The other
-- right atoms also have UX value:
--
--   rightCreated      → new holder learns they got the right.
--   rightTransferred  → new holder learns the right was reassigned to them.
--   rightDelegated    → delegate learns they can exercise on holder's behalf.
--   rightRevoked      → previous holder learns their access ended.
--   rightSuspended    → holder learns their access is paused.
--   rightExpired      → holder learns the lapse actually happened (the
--                       expiring-soon push warned earlier; this confirms).
--
-- Skipped on purpose:
--   rightRestored     → restore lifts a suspension or revocation the
--                       holder already knew about. Positive but
--                       expected; pushing risks noise.
--   rightExercised    → holder/delegate did it themselves, no signal
--                       to send.
--
-- One trigger function dispatches all six via a switch on event_type
-- so the system_events table only carries one new AFTER INSERT
-- trigger (cheap; same scan cost as slice 16's dedicated one). Each
-- branch resolves the recipient member_id and builds Spanish copy.

BEGIN;

create or replace function public.on_right_lifecycle_notify()
returns trigger
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  v_recipient_mid    uuid;
  v_recipient_user   uuid;
  v_right_name       text;
  v_actor_user_id    uuid;
  v_title            text;
  v_body             text;
  v_notif_type       text;
begin
  -- Pull the right's name once for the body copy. The payload sometimes
  -- carries it (rightCreated/Expiring); when absent we fall back to the
  -- resource row's metadata.name (every lifecycle event has a
  -- resource_id by construction).
  v_right_name := coalesce(
    new.payload->>'name',
    (select r.metadata->>'name'
       from public.resources r
      where r.id = new.resource_id),
    'Tu derecho'
  );

  case new.event_type
  when 'rightCreated' then
    v_notif_type    := 'rightCreated';
    v_recipient_mid := coalesce(
      (new.payload->>'holder_member_id')::uuid,
      new.member_id
    );
    v_actor_user_id := nullif(new.payload->>'created_by','')::uuid;
    v_title := 'Tienes un nuevo derecho';
    v_body  := v_right_name || ' fue creado a tu nombre.';

  when 'rightTransferred' then
    v_notif_type    := 'rightTransferred';
    v_recipient_mid := coalesce(
      (new.payload->>'to_member_id')::uuid,
      new.member_id
    );
    v_actor_user_id := nullif(new.payload->>'transferred_by','')::uuid;
    v_title := 'Te transfirieron un derecho';
    v_body  := v_right_name || ' es ahora tuyo.';

  when 'rightDelegated' then
    v_notif_type    := 'rightDelegated';
    v_recipient_mid := coalesce(
      (new.payload->>'delegate_member_id')::uuid,
      new.member_id
    );
    v_actor_user_id := nullif(new.payload->>'delegated_by','')::uuid;
    v_title := 'Te delegaron un derecho';
    v_body  := 'Puedes ejercer ' || v_right_name || ' por el titular.';

  when 'rightRevoked' then
    v_notif_type := 'rightRevoked';
    -- The atom doesn't carry the holder — at revoke time the row's
    -- metadata.holder_member_id is still the previous holder (revoke
    -- sets status, not metadata). Resolve from the resource row.
    select (r.metadata->>'holder_member_id')::uuid
      into v_recipient_mid
      from public.resources r
     where r.id = new.resource_id;
    v_actor_user_id := nullif(new.payload->>'revoked_by','')::uuid;
    v_title := 'Tu derecho fue revocado';
    v_body  := v_right_name || ' ya no está activo.';

  when 'rightSuspended' then
    v_notif_type := 'rightSuspended';
    select (r.metadata->>'holder_member_id')::uuid
      into v_recipient_mid
      from public.resources r
     where r.id = new.resource_id;
    v_actor_user_id := nullif(new.payload->>'suspended_by','')::uuid;
    v_title := 'Tu derecho fue suspendido';
    v_body  := v_right_name || ' está temporalmente pausado.';

  when 'rightExpired' then
    v_notif_type    := 'rightExpired';
    v_recipient_mid := coalesce(
      (new.payload->>'holder_member_id')::uuid,
      new.member_id
    );
    v_actor_user_id := null;  -- cron-emitted; no human actor
    v_title := 'Tu derecho venció';
    v_body  := v_right_name || ' ya no está activo.';

  else
    -- Not a lifecycle event we handle; rightRestored / rightExercised /
    -- rightExpiringSoon (slice 16 owns the last one). Skip.
    return new;
  end case;

  if v_recipient_mid is null then
    -- Nothing to address. Atom row still lands so activity feed
    -- shows the event; just no push.
    return new;
  end if;

  -- Verify the member is still active in the group + skip the push
  -- when the recipient IS the actor (don't notify someone about
  -- their own action — they have UI context already).
  select gm.user_id into v_recipient_user
    from public.group_members gm
   where gm.id = v_recipient_mid
     and gm.group_id = new.group_id
     and gm.active = true;
  if v_recipient_user is null then
    return new;
  end if;
  if v_actor_user_id is not null and v_actor_user_id = v_recipient_user then
    return new;
  end if;

  insert into public.notifications_outbox (
    group_id,
    recipient_member_id,
    notification_type,
    payload,
    deep_link
  ) values (
    new.group_id,
    v_recipient_mid,
    v_notif_type,
    jsonb_build_object(
      'title',          v_title,
      'body',           v_body,
      'right_id',       new.resource_id,
      'right_name',     v_right_name,
      'source_atom_id', new.id
    ),
    'ruul://resource/' || new.resource_id::text
  );

  return new;
end;
$$;

revoke execute on function public.on_right_lifecycle_notify() from public, anon, authenticated;

comment on function public.on_right_lifecycle_notify() is
  'Enqueues notifications_outbox rows for right.* lifecycle atoms (Created/Transferred/Delegated/Revoked/Suspended/Expired). Skips self-actions (actor == recipient). Mig 00208.';

drop trigger if exists right_lifecycle_notify on public.system_events;
create trigger right_lifecycle_notify
  after insert on public.system_events
  for each row
  when (new.event_type in (
    'rightCreated',
    'rightTransferred',
    'rightDelegated',
    'rightRevoked',
    'rightSuspended',
    'rightExpired'
  ))
  execute function public.on_right_lifecycle_notify();

COMMIT;
