-- R.6.C.2/3/4 — 3 detectores virtual events más (extiende R.6.C overdue pattern).
--
-- Cada detector:
--   - SELECT rows que matchean window + NOT marked
--   - INSERT activity_event con payload completo + r6_virtual:true
--   - UPDATE metadata.r6_<kind>_emitted_at = now() (idempotency)
--
-- Trigger R.6.B `_r6_dispatch_rule_eval` AFTER INSERT activity_events ya recoge
-- → cualquier rule subscribed dispara emit_attention al subject.
--
-- Smoke verde 2026-06-08:
--   - document.expiring: 1 doc backdated → emit 1 → 2do tick 0 (idempotency).
--   - reservation.starting_soon + right.expiring: 0 demo data en window —
--     detector standby, listo cuando hay datos.

------------------------------------------------------------------------
-- R.6.C.2 — document.expiring (metadata.expires_at < now() + 30d)
------------------------------------------------------------------------
create or replace function public._r6_emit_expiring_documents()
returns integer
language plpgsql
security definer
set search_path to public, auth
set row_security to off
as $$
declare
  v_d record;
  v_count integer := 0;
  v_expires_at timestamptz;
  v_days_until integer;
begin
  for v_d in
    select id, context_actor_id, owner_actor_id, title, document_type, metadata
      from public.documents
     where archived_at is null
       and metadata ? 'expires_at'
       and not coalesce(metadata ? 'r6_expiring_emitted_at', false)
       and (metadata->>'expires_at')::timestamptz < now() + interval '30 days'
       and (metadata->>'expires_at')::timestamptz > now()
     order by (metadata->>'expires_at')::timestamptz asc
     limit 200
  loop
    v_expires_at := (v_d.metadata->>'expires_at')::timestamptz;
    v_days_until := greatest(0, extract(day from (v_expires_at - now()))::int);

    insert into public.activity_events
      (context_actor_id, actor_id, event_type, subject_type, subject_id, payload)
    values
      (v_d.context_actor_id, v_d.owner_actor_id,
       'document.expiring',
       'document', v_d.id,
       jsonb_build_object(
         'document_id', v_d.id,
         'document_type', v_d.document_type,
         'title', v_d.title,
         'expires_at', v_expires_at,
         'days_until_expiry', v_days_until,
         'r6_virtual', true));

    update public.documents
       set metadata = coalesce(metadata, '{}'::jsonb)
                      || jsonb_build_object('r6_expiring_emitted_at', now())
     where id = v_d.id;

    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

------------------------------------------------------------------------
-- R.6.C.3 — reservation.starting_soon (starts_at < now() + 24h)
------------------------------------------------------------------------
create or replace function public._r6_emit_starting_soon_reservations()
returns integer
language plpgsql
security definer
set search_path to public, auth
set row_security to off
as $$
declare
  v_r record;
  v_count integer := 0;
  v_hours_until integer;
begin
  for v_r in
    select id, context_actor_id, requested_by_actor_id, reserved_for_actor_id,
           resource_id, starts_at, ends_at, status, metadata
      from public.resource_reservations
     where status in ('approved', 'confirmed')
       and starts_at > now()
       and starts_at < now() + interval '24 hours'
       and not coalesce(metadata ? 'r6_starting_soon_emitted_at', false)
     order by starts_at asc
     limit 200
  loop
    v_hours_until := greatest(0, extract(hour from (v_r.starts_at - now()))::int);

    insert into public.activity_events
      (context_actor_id, actor_id, event_type, subject_type, subject_id, resource_id, payload)
    values
      (v_r.context_actor_id,
       coalesce(v_r.reserved_for_actor_id, v_r.requested_by_actor_id),
       'reservation.starting_soon',
       'reservation', v_r.id, v_r.resource_id,
       jsonb_build_object(
         'reservation_id', v_r.id,
         'resource_id', v_r.resource_id,
         'starts_at', v_r.starts_at,
         'ends_at', v_r.ends_at,
         'hours_until_start', v_hours_until,
         'status', v_r.status,
         'r6_virtual', true));

    update public.resource_reservations
       set metadata = coalesce(metadata, '{}'::jsonb)
                      || jsonb_build_object('r6_starting_soon_emitted_at', now())
     where id = v_r.id;

    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

------------------------------------------------------------------------
-- R.6.C.4 — right.expiring (ends_at < now() + 7d + not revoked/expired)
------------------------------------------------------------------------
create or replace function public._r6_emit_expiring_rights()
returns integer
language plpgsql
security definer
set search_path to public, auth
set row_security to off
as $$
declare
  v_rt record;
  v_count integer := 0;
  v_days_until integer;
  v_context_actor_id uuid;
begin
  for v_rt in
    select id, resource_id, holder_actor_id, right_kind, ends_at, metadata
      from public.resource_rights
     where revoked_at is null
       and expired_at is null
       and ends_at is not null
       and ends_at > now()
       and ends_at < now() + interval '7 days'
       and not coalesce(metadata ? 'r6_expiring_emitted_at', false)
     order by ends_at asc
     limit 200
  loop
    v_days_until := greatest(0, extract(day from (v_rt.ends_at - now()))::int);

    select canonical_owner_actor_id into v_context_actor_id
      from public.resources where id = v_rt.resource_id;

    if v_context_actor_id is null then
      continue;
    end if;

    insert into public.activity_events
      (context_actor_id, actor_id, event_type, subject_type, subject_id, resource_id, payload)
    values
      (v_context_actor_id, v_rt.holder_actor_id,
       'right.expiring',
       'resource_right', v_rt.id, v_rt.resource_id,
       jsonb_build_object(
         'right_id', v_rt.id,
         'resource_id', v_rt.resource_id,
         'right_kind', v_rt.right_kind,
         'ends_at', v_rt.ends_at,
         'days_until_expiry', v_days_until,
         'r6_virtual', true));

    update public.resource_rights
       set metadata = coalesce(metadata, '{}'::jsonb)
                      || jsonb_build_object('r6_expiring_emitted_at', now())
     where id = v_rt.id;

    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

------------------------------------------------------------------------
-- Schedules pg_cron
------------------------------------------------------------------------

do $$
begin
  perform cron.unschedule('r6-expiring-documents');
exception when others then null; end $$;
select cron.schedule(
  'r6-expiring-documents',
  '0 * * * *',
  $$select public._r6_emit_expiring_documents();$$
);

do $$
begin
  perform cron.unschedule('r6-starting-soon-reservations');
exception when others then null; end $$;
select cron.schedule(
  'r6-starting-soon-reservations',
  '*/30 * * * *',
  $$select public._r6_emit_starting_soon_reservations();$$
);

do $$
begin
  perform cron.unschedule('r6-expiring-rights');
exception when others then null; end $$;
select cron.schedule(
  'r6-expiring-rights',
  '0 * * * *',
  $$select public._r6_emit_expiring_rights();$$
);
