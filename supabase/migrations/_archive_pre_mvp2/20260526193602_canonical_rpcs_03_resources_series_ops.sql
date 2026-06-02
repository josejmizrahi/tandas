-- §6. Resources — envelope
create or replace function public.create_resource(
  p_group_id        uuid,
  p_resource_type   text,
  p_name            text,
  p_subtype_payload jsonb default '{}'::jsonb,
  p_visibility      text default 'members',
  p_ownership_kind  text default 'group',
  p_series_id       uuid default null,
  p_metadata        jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_id uuid; v_payload jsonb;
begin
  perform public.assert_permission(p_group_id, 'resources.create');
  v_payload := coalesce(p_subtype_payload, '{}'::jsonb);

  insert into public.group_resources (
    group_id, resource_type, name, visibility, ownership_kind, series_id, metadata, created_by
  ) values (
    p_group_id, p_resource_type, p_name, p_visibility, p_ownership_kind, p_series_id,
    coalesce(p_metadata, '{}'::jsonb), auth.uid()
  ) returning id into v_id;

  if p_resource_type = 'event' then
    insert into public.group_resource_events (
      resource_id, starts_at, ends_at, location, location_geo, capacity, host_membership_id, rsvp_deadline
    ) values (
      v_id,
      coalesce((v_payload->>'starts_at')::timestamptz, now() + interval '1 day'),
      nullif(v_payload->>'ends_at','')::timestamptz,
      v_payload->>'location',
      v_payload->'location_geo',
      nullif(v_payload->>'capacity','')::int,
      nullif(v_payload->>'host_membership_id','')::uuid,
      nullif(v_payload->>'rsvp_deadline','')::timestamptz
    );
  elsif p_resource_type = 'fund' then
    insert into public.group_resource_funds (resource_id, fund_kind, currency, is_shared_pool, is_in_kind, threshold_target)
    values (
      v_id,
      coalesce(v_payload->>'fund_kind', 'pool'),
      coalesce(v_payload->>'currency', 'MXN'),
      coalesce((v_payload->>'is_shared_pool')::boolean, false),
      coalesce((v_payload->>'is_in_kind')::boolean, false),
      nullif(v_payload->>'threshold_target','')::numeric
    );
  elsif p_resource_type = 'slot' then
    insert into public.group_resource_slots (resource_id, slot_starts_at, slot_ends_at, assigned_membership_id)
    values (
      v_id,
      coalesce((v_payload->>'slot_starts_at')::timestamptz, now()),
      nullif(v_payload->>'slot_ends_at','')::timestamptz,
      nullif(v_payload->>'assigned_membership_id','')::uuid
    );
  elsif p_resource_type = 'space' then
    insert into public.group_resource_spaces (resource_id, address, geo, capacity, rules)
    values (
      v_id, v_payload->>'address', v_payload->'geo',
      nullif(v_payload->>'capacity','')::int, v_payload->>'rules'
    );
  elsif p_resource_type = 'asset' then
    insert into public.group_resource_assets (
      resource_id, asset_kind, serial_number, current_value, current_value_unit, condition, custodian_membership_id
    ) values (
      v_id, v_payload->>'asset_kind', v_payload->>'serial_number',
      nullif(v_payload->>'current_value','')::numeric,
      v_payload->>'current_value_unit', v_payload->>'condition',
      nullif(v_payload->>'custodian_membership_id','')::uuid
    );
  elsif p_resource_type = 'right' then
    insert into public.group_resource_rights (
      resource_id, right_kind, holder_membership_id, expires_at, transferable, conditions
    ) values (
      v_id, v_payload->>'right_kind',
      nullif(v_payload->>'holder_membership_id','')::uuid,
      nullif(v_payload->>'expires_at','')::timestamptz,
      coalesce((v_payload->>'transferable')::boolean, false),
      v_payload->>'conditions'
    );
  end if;

  perform public.record_system_event(
    p_group_id, 'resource.created', 'resource', v_id,
    p_name, jsonb_build_object('resource_type', p_resource_type)
  );
  return v_id;
end;
$$;

create or replace function public.update_resource(
  p_resource_id     uuid,
  p_name            text default null,
  p_description     text default null,
  p_visibility      text default null,
  p_metadata        jsonb default null,
  p_subtype_payload jsonb default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_r public.group_resources%rowtype;
begin
  select * into v_r from public.group_resources where id = p_resource_id for update;
  if v_r.id is null then raise exception 'resource not found'; end if;
  perform public.assert_permission(v_r.group_id, 'resources.update');

  update public.group_resources
     set name        = coalesce(p_name, name),
         description = coalesce(p_description, description),
         visibility  = coalesce(p_visibility, visibility),
         metadata    = case when p_metadata is null then metadata else metadata || p_metadata end
   where id = p_resource_id;

  if p_subtype_payload is not null then
    if v_r.resource_type = 'event' then
      update public.group_resource_events
         set starts_at = coalesce(nullif(p_subtype_payload->>'starts_at','')::timestamptz, starts_at),
             ends_at   = coalesce(nullif(p_subtype_payload->>'ends_at','')::timestamptz, ends_at),
             location  = coalesce(p_subtype_payload->>'location', location),
             capacity  = coalesce(nullif(p_subtype_payload->>'capacity','')::int, capacity),
             host_membership_id = coalesce(nullif(p_subtype_payload->>'host_membership_id','')::uuid, host_membership_id),
             rsvp_deadline = coalesce(nullif(p_subtype_payload->>'rsvp_deadline','')::timestamptz, rsvp_deadline)
       where resource_id = p_resource_id;
    elsif v_r.resource_type = 'fund' then
      update public.group_resource_funds
         set fund_kind = coalesce(p_subtype_payload->>'fund_kind', fund_kind),
             currency  = coalesce(p_subtype_payload->>'currency', currency),
             is_shared_pool = coalesce((p_subtype_payload->>'is_shared_pool')::boolean, is_shared_pool),
             threshold_target = coalesce(nullif(p_subtype_payload->>'threshold_target','')::numeric, threshold_target)
       where resource_id = p_resource_id;
    end if;
  end if;

  perform public.record_system_event(
    v_r.group_id, 'resource.updated', 'resource', p_resource_id,
    'Recurso actualizado', '{}'::jsonb
  );
end;
$$;

create or replace function public.set_resource_ownership(
  p_resource_id        uuid,
  p_ownership_kind     text,
  p_owner_membership_id uuid default null,
  p_metadata           jsonb default '{}'::jsonb
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_r public.group_resources%rowtype;
begin
  select * into v_r from public.group_resources where id = p_resource_id for update;
  if v_r.id is null then raise exception 'resource not found'; end if;
  perform public.assert_permission(v_r.group_id, 'resources.transfer');

  update public.group_resources
     set ownership_kind = p_ownership_kind,
         owner_membership_id = p_owner_membership_id,
         ownership_metadata = coalesce(p_metadata, '{}'::jsonb)
   where id = p_resource_id;

  perform public.record_system_event(
    v_r.group_id, 'resource.ownership_changed', 'resource', p_resource_id,
    'Propiedad transferida',
    jsonb_build_object('to_kind', p_ownership_kind, 'to_member', p_owner_membership_id)
  );
end;
$$;

create or replace function public.archive_resource(p_resource_id uuid, p_reason text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_r public.group_resources%rowtype; v_open int;
begin
  select * into v_r from public.group_resources where id = p_resource_id for update;
  if v_r.id is null then raise exception 'resource not found'; end if;
  perform public.assert_permission(v_r.group_id, 'resources.archive');

  select count(*) into v_open from public.group_obligations
   where source_resource_id = p_resource_id and status in ('open','partially_settled');
  if v_open > 0 then raise exception 'resource has % open obligations', v_open; end if;

  update public.group_resources
     set status = 'archived', archived_at = now()
   where id = p_resource_id;

  perform public.record_system_event(
    v_r.group_id, 'resource.archived', 'resource', p_resource_id, 'Recurso archivado',
    jsonb_build_object('reason', p_reason)
  );
end;
$$;

create or replace function public.revert_archive_resource(p_resource_id uuid, p_reason text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_r public.group_resources%rowtype;
begin
  select * into v_r from public.group_resources where id = p_resource_id for update;
  if v_r.id is null then raise exception 'resource not found'; end if;
  perform public.assert_permission(v_r.group_id, 'resources.update');
  update public.group_resources set status = 'active', archived_at = null where id = p_resource_id;

  perform public.record_system_event(
    v_r.group_id, 'resource.unarchived', 'resource', p_resource_id, 'Recurso reactivado',
    jsonb_build_object('reason', p_reason)
  );
end;
$$;

-- §7. Resource series & capabilities
create or replace function public.create_resource_series(
  p_group_id        uuid,
  p_resource_type   text,
  p_cadence         text,
  p_pattern         jsonb default '{}'::jsonb,
  p_starts_on       date default null,
  p_ends_on         date default null,
  p_ritual_meaning  text default null,
  p_ritual_marker_kind text default null,
  p_template_payload jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_id uuid;
begin
  perform public.assert_permission(p_group_id, 'resources.create');
  insert into public.group_resource_series (
    group_id, resource_type, cadence, pattern, starts_on, ends_on,
    ritual_meaning, ritual_marker_kind, template_payload, created_by
  ) values (
    p_group_id, p_resource_type, p_cadence,
    coalesce(p_pattern, '{}'::jsonb), p_starts_on, p_ends_on,
    p_ritual_meaning, p_ritual_marker_kind,
    coalesce(p_template_payload, '{}'::jsonb), auth.uid()
  )
  returning id into v_id;

  perform public.record_system_event(
    p_group_id, 'resource_series.created', 'resource_series', v_id, 'Serie creada',
    jsonb_build_object('cadence', p_cadence, 'resource_type', p_resource_type)
  );
  return v_id;
end;
$$;

create or replace function public.update_resource_series(
  p_series_id        uuid,
  p_pattern          jsonb default null,
  p_ritual_meaning   text  default null,
  p_ritual_marker_kind text default null,
  p_template_payload jsonb default null,
  p_ends_on          date default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_group uuid;
begin
  select group_id into v_group from public.group_resource_series where id = p_series_id for update;
  if v_group is null then raise exception 'series not found'; end if;
  perform public.assert_permission(v_group, 'resources.update');

  update public.group_resource_series
     set pattern             = coalesce(p_pattern, pattern),
         ritual_meaning      = coalesce(p_ritual_meaning, ritual_meaning),
         ritual_marker_kind  = coalesce(p_ritual_marker_kind, ritual_marker_kind),
         template_payload    = coalesce(p_template_payload, template_payload),
         ends_on             = coalesce(p_ends_on, ends_on)
   where id = p_series_id;

  perform public.record_system_event(
    v_group, 'resource_series.updated', 'resource_series', p_series_id, 'Serie actualizada', '{}'::jsonb
  );
end;
$$;

create or replace function public.enable_resource_capability(
  p_resource_id  uuid,
  p_capability_key text,
  p_config       jsonb default '{}'::jsonb
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_group uuid;
begin
  select group_id into v_group from public.group_resources where id = p_resource_id;
  if v_group is null then raise exception 'resource not found'; end if;
  perform public.assert_permission(v_group, 'resources.update');

  insert into public.group_resource_capabilities (resource_id, capability_key, enabled, config, enabled_by)
  values (p_resource_id, p_capability_key, true, coalesce(p_config, '{}'::jsonb), auth.uid())
  on conflict (resource_id, capability_key) do update
    set enabled = true, config = excluded.config, enabled_by = auth.uid();

  perform public.record_system_event(
    v_group, 'resource.capability_enabled', 'resource', p_resource_id, p_capability_key, '{}'::jsonb
  );
end;
$$;

create or replace function public.disable_resource_capability(
  p_resource_id    uuid,
  p_capability_key text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_group uuid;
begin
  select group_id into v_group from public.group_resources where id = p_resource_id;
  if v_group is null then raise exception 'resource not found'; end if;
  perform public.assert_permission(v_group, 'resources.update');

  update public.group_resource_capabilities
     set enabled = false
   where resource_id = p_resource_id and capability_key = p_capability_key;

  perform public.record_system_event(
    v_group, 'resource.capability_disabled', 'resource', p_resource_id, p_capability_key, '{}'::jsonb
  );
end;
$$;

-- §8. Resource ops
create or replace function public.book_resource(
  p_resource_id uuid,
  p_starts_at   timestamptz,
  p_ends_at     timestamptz default null,
  p_reason      text default null,
  p_client_id   text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_r public.group_resources%rowtype; v_membership uuid; v_id uuid;
begin
  select * into v_r from public.group_resources where id = p_resource_id;
  if v_r.id is null then raise exception 'resource not found'; end if;
  perform public.assert_permission(v_r.group_id, 'bookings.create');
  v_membership := public.assert_member_of_group(v_r.group_id);

  if p_client_id is not null then
    select id into v_id from public.group_resource_bookings
     where group_id = v_r.group_id and metadata->>'client_id' = p_client_id;
    if v_id is not null then return v_id; end if;
  end if;

  insert into public.group_resource_bookings (
    group_id, resource_id, booked_by_membership_id, starts_at, ends_at, status, reason, metadata
  ) values (
    v_r.group_id, p_resource_id, v_membership, p_starts_at, p_ends_at, 'confirmed',
    p_reason,
    case when p_client_id is null then '{}'::jsonb else jsonb_build_object('client_id', p_client_id) end
  )
  returning id into v_id;

  perform public.record_system_event(
    v_r.group_id, 'booking.created', 'booking', v_id, p_reason,
    jsonb_build_object('resource_id', p_resource_id, 'starts_at', p_starts_at)
  );
  return v_id;
end;
$$;

create or replace function public.cancel_booking(
  p_booking_id uuid,
  p_reason     text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_b public.group_resource_bookings%rowtype; v_new uuid; v_is_owner boolean;
begin
  select * into v_b from public.group_resource_bookings where id = p_booking_id;
  if v_b.id is null then raise exception 'booking not found'; end if;
  v_is_owner := exists (
    select 1 from public.group_memberships m
    where m.id = v_b.booked_by_membership_id and m.user_id = auth.uid()
  );
  if not v_is_owner and not public.has_group_permission(v_b.group_id, 'bookings.cancel') then
    raise exception 'caller cannot cancel this booking';
  end if;

  insert into public.group_resource_bookings (
    group_id, resource_id, booked_by_membership_id, starts_at, ends_at, status, reason, metadata
  ) values (
    v_b.group_id, v_b.resource_id, v_b.booked_by_membership_id, v_b.starts_at, v_b.ends_at,
    'cancelled', p_reason,
    jsonb_build_object('cancels_booking_id', p_booking_id)
  ) returning id into v_new;

  perform public.record_system_event(
    v_b.group_id, 'booking.cancelled', 'booking', p_booking_id, p_reason, '{}'::jsonb
  );
  return v_new;
end;
$$;

create or replace function public.submit_rsvp(
  p_resource_id uuid,
  p_rsvp_status text,
  p_note        text default null,
  p_client_id   text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_r public.group_resources%rowtype; v_m uuid; v_id uuid;
begin
  select * into v_r from public.group_resources where id = p_resource_id;
  if v_r.id is null then raise exception 'resource not found'; end if;
  perform public.assert_permission(v_r.group_id, 'rsvp.submit');
  v_m := public.assert_member_of_group(v_r.group_id);

  insert into public.group_rsvp_actions (
    group_id, resource_id, membership_id, user_id, rsvp_status, note
  ) values (
    v_r.group_id, p_resource_id, v_m, auth.uid(), p_rsvp_status, p_note
  )
  returning id into v_id;

  perform public.record_system_event(
    v_r.group_id, 'rsvp.submitted', 'resource', p_resource_id, p_rsvp_status,
    jsonb_build_object('membership_id', v_m, 'rsvp_status', p_rsvp_status)
  );
  return v_id;
end;
$$;

create or replace function public.submit_check_in(
  p_resource_id        uuid,
  p_check_in_method    text default 'self',
  p_location_verified  boolean default null,
  p_client_id          text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_r public.group_resources%rowtype; v_m uuid; v_id uuid;
begin
  select * into v_r from public.group_resources where id = p_resource_id;
  if v_r.id is null then raise exception 'resource not found'; end if;
  perform public.assert_permission(v_r.group_id, 'check_in.submit');
  v_m := public.assert_member_of_group(v_r.group_id);

  insert into public.group_check_in_actions (
    group_id, resource_id, membership_id, check_in_method, location_verified
  ) values (
    v_r.group_id, p_resource_id, v_m, p_check_in_method, p_location_verified
  ) returning id into v_id;

  perform public.record_system_event(
    v_r.group_id, 'check_in.submitted', 'resource', p_resource_id, p_check_in_method, '{}'::jsonb
  );
  return v_id;
end;
$$;

create or replace function public.mark_no_show(
  p_resource_id   uuid,
  p_membership_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_r public.group_resources%rowtype; v_event_uuid uuid;
begin
  select * into v_r from public.group_resources where id = p_resource_id;
  if v_r.id is null then raise exception 'resource not found'; end if;
  perform public.assert_permission(v_r.group_id, 'resources.update');

  select rse.uuid_id into v_event_uuid from public.record_system_event(
    v_r.group_id, 'check_in.missed', 'resource', p_resource_id,
    'Miembro no se presentó',
    jsonb_build_object('membership_id', p_membership_id)
  ) rse;
  perform public.evaluate_rules_for_event(v_event_uuid);
end;
$$;
