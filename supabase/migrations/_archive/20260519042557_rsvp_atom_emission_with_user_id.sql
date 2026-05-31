-- Mig 00339: extend the rsvp_actions trigger to include the host's
-- auth.users.id in the system_event payload so the rule engine has
-- the actor_id (FK to auth.users) without needing a separate lookup.
-- Without this, rule_evaluations.actor_id was nil/wrong and the FK
-- violation cascade broke iOS RSVP confirm (regression from mig 00337).

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
  v_user_id         uuid;
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

  -- Resolve user_id from member_id (group_members.id -> auth.users.id)
  -- so the rule engine can use it as actor_id without an extra join.
  select user_id into v_user_id
    from public.group_members
   where id = NEW.member_id
   limit 1;

  v_payload := jsonb_strip_nulls(jsonb_build_object(
    'status',            NEW.status,
    'user_id',           v_user_id,
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
      p_payload     => v_payload || jsonb_build_object(
        'previous_status', v_previous_status,
        'from',            v_previous_status,
        'to',              NEW.status
      )
    );
  end if;

  return NEW;
end;
$$;

comment on function public.on_rsvp_action_inserted_emit_atom() is
  'mig 00339: now includes payload.user_id (resolved from group_members) so the rule engine has actor_id without crashing the FK on rule_evaluations. Also adds from/to keys to rsvpChangedSameDay payload for evaluator compatibility.';;
