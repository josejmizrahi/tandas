create or replace function public.on_rsvp_action_inserted_emit_atom()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_resource        public.resources;
  v_starts_at       timestamptz;
  v_title           text;
  v_prior_count     int;
  v_previous_status text;
  v_payload         jsonb;
begin
  select * into v_resource from public.resources where id = NEW.resource_id;
  if not found then
    return NEW;
  end if;

  v_starts_at := (v_resource.metadata->>'starts_at')::timestamptz;
  v_title     := v_resource.metadata->>'title';

  v_payload := jsonb_strip_nulls(jsonb_build_object(
    'status',            NEW.status,
    'plus_ones',         NEW.metadata->'plus_ones',
    'waitlist_position', NEW.metadata->'waitlist_position',
    'cancelled_reason',  NEW.metadata->'cancelled_reason',
    'via',               NEW.metadata->>'via',
    'starts_at',         case when v_starts_at is not null
                              then to_char(v_starts_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
                              else null end,
    'title',             v_title
  ));

  perform public.record_system_event(
    p_group_id    => v_resource.group_id,
    p_event_type  => 'rsvpSubmitted',
    p_resource_id => NEW.resource_id,
    p_member_id   => NEW.member_id,
    p_payload     => v_payload
  );

  select count(*), (
    select status from public.rsvp_actions
     where resource_id = NEW.resource_id
       and member_id   = NEW.member_id
       and id <> NEW.id
     order by recorded_at desc
     limit 1
  )
    into v_prior_count, v_previous_status
    from public.rsvp_actions
   where resource_id = NEW.resource_id
     and member_id   = NEW.member_id
     and id <> NEW.id;

  if v_prior_count > 0
     and v_starts_at is not null
     and v_starts_at - now() < interval '24 hours'
     and v_starts_at - now() > interval '-24 hours'
     and v_previous_status is distinct from NEW.status
  then
    perform public.record_system_event(
      p_group_id    => v_resource.group_id,
      p_event_type  => 'rsvpChangedSameDay',
      p_resource_id => NEW.resource_id,
      p_member_id   => NEW.member_id,
      p_payload     => v_payload || jsonb_build_object('previous_status', v_previous_status)
    );
  end if;

  return NEW;
end;
$$;

revoke execute on function public.on_rsvp_action_inserted_emit_atom() from public, anon;
grant  execute on function public.on_rsvp_action_inserted_emit_atom() to authenticated, service_role;

drop trigger if exists trg_on_rsvp_action_emit_system_event on public.rsvp_actions;
create trigger trg_on_rsvp_action_emit_system_event
  after insert on public.rsvp_actions
  for each row
  execute function public.on_rsvp_action_inserted_emit_atom();

comment on function public.on_rsvp_action_inserted_emit_atom() is
  'mig 00337: emits system_event(rsvpSubmitted) on every rsvp_actions insert. Additionally emits rsvpChangedSameDay when (a) prior atom exists for same (resource,member) and (b) event starts within 24h. Unblocks late_cancellation_consequence (mig 00320).';

comment on trigger trg_on_rsvp_action_emit_system_event on public.rsvp_actions is
  'Materializes rsvpSubmitted + rsvpChangedSameDay atoms in system_events for rule engine + activity feed.';;
