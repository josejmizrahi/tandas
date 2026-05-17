-- 00242 — System event payload schemas + soft validation.

create table if not exists public.system_event_payload_schemas (
  event_type text primary key,
  schema     jsonb not null,
  mode       text not null default 'warn',
  notes      text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (mode in ('warn','strict')),
  check (jsonb_typeof(schema) = 'object')
);

comment on table public.system_event_payload_schemas is
  'Per-event_type schema for system_events.payload. Consulted by record_system_event (mig 00242). mode=warn → log only; mode=strict → reject.';

revoke all on public.system_event_payload_schemas from public, anon;
grant select on public.system_event_payload_schemas to authenticated, service_role;

create or replace function public.validate_system_event_payload(
  p_event_type text,
  p_payload    jsonb
)
returns text[]
language plpgsql
stable
set search_path = public
as $$
declare
  v_schema    jsonb;
  v_required  jsonb;
  v_props     jsonb;
  v_key       text;
  v_expected  text;
  v_actual    text;
  v_errors    text[] := array[]::text[];
  v_required_keys text[];
begin
  select schema into v_schema from public.system_event_payload_schemas where event_type = p_event_type;
  if v_schema is null then return v_errors; end if;
  if p_payload is null or jsonb_typeof(p_payload) <> 'object' then p_payload := '{}'::jsonb; end if;
  v_required := v_schema -> 'required';
  v_props    := v_schema -> 'properties';
  if v_required is not null and jsonb_typeof(v_required) = 'array' then
    select array(select jsonb_array_elements_text(v_required)) into v_required_keys;
    foreach v_key in array v_required_keys loop
      if not (p_payload ? v_key) then
        v_errors := v_errors || ('missing required key: ' || v_key);
      end if;
    end loop;
  end if;
  if v_props is not null and jsonb_typeof(v_props) = 'object' then
    for v_key in select jsonb_object_keys(v_props) loop
      if not (p_payload ? v_key) then continue; end if;
      v_expected := v_props -> v_key ->> 'type';
      if v_expected is null then continue; end if;
      v_actual := jsonb_typeof(p_payload -> v_key);
      if v_expected = 'integer' then
        if v_actual <> 'number' then v_errors := v_errors || (v_key || ': expected integer, got ' || coalesce(v_actual, 'undefined')); end if;
      elsif v_actual is distinct from v_expected then
        v_errors := v_errors || (v_key || ': expected ' || v_expected || ', got ' || coalesce(v_actual, 'undefined'));
      end if;
    end loop;
  end if;
  return v_errors;
end;
$$;

revoke execute on function public.validate_system_event_payload(text, jsonb) from public, anon;
grant  execute on function public.validate_system_event_payload(text, jsonb) to authenticated, service_role;

comment on function public.validate_system_event_payload(text, jsonb) is
  'Minimal hand-rolled validator (no pg_jsonschema dep). Validates required keys + top-level property leaf types against schema in system_event_payload_schemas.';

create or replace function public.record_system_event(
  p_group_id    uuid,
  p_event_type  text,
  p_resource_id uuid default null,
  p_member_id   uuid default null,
  p_payload     jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_event_id uuid;
  v_uid      uuid := auth.uid();
  v_errors   text[];
  v_mode     text;
begin
  if p_event_type is null or length(trim(p_event_type)) = 0 then
    raise exception 'record_system_event: event_type required';
  end if;

  if v_uid is not null then
    if not exists (
      select 1
        from public.group_members gm
       where gm.group_id = p_group_id
         and gm.user_id  = v_uid
         and gm.active   = true
    ) then
      raise exception 'record_system_event: caller % is not an active member of group %', v_uid, p_group_id;
    end if;
  end if;

  if not public.is_known_system_event_type(p_event_type) then
    raise notice 'record_system_event: unknown event_type % (group=% resource=%) — row inserted but no rule engine evaluator will match; either ship a whitelist update or fix the caller.',
      p_event_type, p_group_id, p_resource_id;
  end if;

  -- Mig 00242: payload schema validation.
  v_errors := public.validate_system_event_payload(p_event_type, p_payload);
  if array_length(v_errors, 1) is not null and array_length(v_errors, 1) > 0 then
    select mode into v_mode
      from public.system_event_payload_schemas
     where event_type = p_event_type;
    if coalesce(v_mode, 'warn') = 'strict' then
      raise exception 'record_system_event: payload schema violation for %: %',
        p_event_type, array_to_string(v_errors, '; ')
        using errcode = '22023';
    else
      raise notice 'record_system_event: payload schema warn for % (group=%): %',
        p_event_type, p_group_id, array_to_string(v_errors, '; ');
    end if;
  end if;

  insert into public.system_events (group_id, event_type, resource_id, member_id, payload)
  values (p_group_id, p_event_type, p_resource_id, p_member_id, p_payload)
  returning id into v_event_id;
  return v_event_id;
end;
$$;

revoke execute on function public.record_system_event(uuid, text, uuid, uuid, jsonb) from public, anon;
grant  execute on function public.record_system_event(uuid, text, uuid, uuid, jsonb) to authenticated, service_role;

comment on function public.record_system_event(uuid, text, uuid, uuid, jsonb) is
  'v2 (mig 00242): consults system_event_payload_schemas before insert. warn-mode → NOTICE, strict-mode → EXCEPTION. Unknown event_types still pass through (no schema = no validation).';

insert into public.system_event_payload_schemas (event_type, schema, mode, notes) values
  ('eventClosed',
    jsonb_build_object(
      'required',   jsonb_build_array('title','closed_at','status'),
      'properties', jsonb_build_object(
        'title',     jsonb_build_object('type', 'string'),
        'closed_at', jsonb_build_object('type', 'string'),
        'status',    jsonb_build_object('type', 'string')
      )
    ),
    'warn',
    'Emitted by close_event/close_event_no_fines (mig 00007 + 00027 + 00235).'
  ),
  ('fineOfficialized',
    jsonb_build_object(
      'required',   jsonb_build_array('fine_id','amount'),
      'properties', jsonb_build_object(
        'fine_id',  jsonb_build_object('type', 'string'),
        'amount',   jsonb_build_object('type', 'number'),
        'rule_id',  jsonb_build_object('type', 'string'),
        'reason',   jsonb_build_object('type', 'string')
      )
    ),
    'warn',
    'Emitted when a fine is officialized via rule engine or manual issue.'
  ),
  ('finePaid',
    jsonb_build_object(
      'required',   jsonb_build_array('fine_id','amount'),
      'properties', jsonb_build_object(
        'fine_id', jsonb_build_object('type', 'string'),
        'amount',  jsonb_build_object('type', 'number'),
        'paid_by', jsonb_build_object('type', 'string')
      )
    ),
    'warn',
    'Emitted when a fine is paid (self or admin-marked).'
  ),
  ('fineVoided',
    jsonb_build_object(
      'required',   jsonb_build_array('amount','reason'),
      'properties', jsonb_build_object(
        'amount',           jsonb_build_object('type', 'number'),
        'reason',           jsonb_build_object('type', 'string'),
        'voided_by_user_id',jsonb_build_object('type', 'string')
      )
    ),
    'warn',
    'Emitted by void_fine (mig 00142+00232) — manual void only.'
  ),
  ('voteResolved',
    jsonb_build_object(
      'required',   jsonb_build_array('vote_type','resolution'),
      'properties', jsonb_build_object(
        'vote_type',     jsonb_build_object('type', 'string'),
        'reference_id',  jsonb_build_object('type', 'string'),
        'resolution',    jsonb_build_object('type', 'string')
      )
    ),
    'warn',
    'Emitted by finalize_vote (mig 00163+00241). Resolution in {passed, failed, quorum_failed}.'
  )
on conflict (event_type) do nothing;
