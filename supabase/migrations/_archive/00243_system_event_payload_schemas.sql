-- 00242 — System event payload schemas + soft validation.
--
-- Closes governance-review item #7 (partial). Today
-- record_system_event accepts ANY jsonb payload. The 83 known event
-- types each have implicit shape expectations (e.g. eventClosed must
-- carry title/closed_at/status), but nothing enforces them.
-- Consumers (rule engine, iOS, notifications) read payload keys with
-- null-coalesce — missing keys silently downgrade to nulls and the
-- downstream feature looks broken with no signal.
--
-- This migration ships
-- ====================
--   1. system_event_payload_schemas table — per-event_type schema
--      registry with a mode column (warn | strict).
--   2. validate_system_event_payload(event_type, payload) — minimal
--      hand-rolled validator. Returns text[] of errors, empty if
--      valid. Hand-rolled (no pg_jsonschema dependency) because the
--      validation we need is small: required keys + leaf types.
--   3. record_system_event wrapper that consults the registry and
--      either RAISE NOTICE (mode='warn', default) or RAISE EXCEPTION
--      (mode='strict') on validation failures.
--   4. Seed schemas for 5 high-impact event types: eventClosed,
--      fineOfficialized, finePaid, fineVoided, voteResolved. All
--      seeded as mode='warn' so this migration is non-breaking —
--      bad payloads in flight will be logged but not rejected. Devs
--      can flip individual schemas to strict once telemetry is clean.
--
-- Adding a schema for another event_type
-- ======================================
--   insert into public.system_event_payload_schemas (event_type, schema, mode)
--   values ('myEventType', '{"required":["x"],"properties":{"x":{"type":"string"}}}'::jsonb, 'warn');
--
-- Supported leaf types in schema.properties.<key>.type: string,
-- number, integer, boolean, object, array, null. Nested schemas not
-- supported — validate the top level only.
--
-- Idempotent: CREATE TABLE IF NOT EXISTS, ON CONFLICT DO NOTHING for
-- seeds, CREATE OR REPLACE for functions.
--
-- Rollback: _rollbacks/00242_rollback.sql drops the validator, the
-- wrapped record_system_event, and the table.

-- =========================================================
-- 1. Schema registry table
-- =========================================================
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
comment on column public.system_event_payload_schemas.schema is
  'Minimal JSON-Schema-ish object: {"required": ["k1","k2"], "properties": {"k1": {"type": "string"}, "k2": {"type": "integer"}}}. No nested schemas — top-level only.';
comment on column public.system_event_payload_schemas.mode is
  'warn (default): violations RAISE NOTICE but allow insert. strict: RAISE EXCEPTION. Flip per-type once telemetry is clean.';

-- Read-only for app role; writes require service_role / migrations.
revoke all on public.system_event_payload_schemas from public, anon;
grant select on public.system_event_payload_schemas to authenticated, service_role;

-- =========================================================
-- 2. Validator function
-- =========================================================
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
  select schema into v_schema
    from public.system_event_payload_schemas
   where event_type = p_event_type;

  -- No schema registered → not validated (empty errors).
  if v_schema is null then
    return v_errors;
  end if;

  -- Treat null/non-object payload as empty object for validation
  -- purposes; the required-key check below will then flag missing
  -- top-level keys.
  if p_payload is null or jsonb_typeof(p_payload) <> 'object' then
    p_payload := '{}'::jsonb;
  end if;

  v_required := v_schema -> 'required';
  v_props    := v_schema -> 'properties';

  -- Required keys.
  if v_required is not null and jsonb_typeof(v_required) = 'array' then
    select array(select jsonb_array_elements_text(v_required)) into v_required_keys;
    foreach v_key in array v_required_keys loop
      if not (p_payload ? v_key) then
        v_errors := v_errors || ('missing required key: ' || v_key);
      end if;
    end loop;
  end if;

  -- Per-property type checks. Only validates keys present in payload.
  if v_props is not null and jsonb_typeof(v_props) = 'object' then
    for v_key in select jsonb_object_keys(v_props) loop
      if not (p_payload ? v_key) then
        continue;
      end if;
      v_expected := v_props -> v_key ->> 'type';
      if v_expected is null then
        continue;
      end if;
      v_actual := jsonb_typeof(p_payload -> v_key);
      -- JSON Schema's 'integer' is a subtype of 'number'; accept either.
      if v_expected = 'integer' then
        if v_actual <> 'number' then
          v_errors := v_errors || (v_key || ': expected integer, got ' || coalesce(v_actual, 'undefined'));
        end if;
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
  'Minimal hand-rolled validator (no pg_jsonschema dep). Validates required keys + top-level property leaf types against schema in system_event_payload_schemas. Returns text[] of human-readable errors. Empty array = valid OR no schema registered.';

-- =========================================================
-- 3. record_system_event wrapped to validate
-- =========================================================
-- Capture the current body and prepend a validation pass. The function
-- signature is unchanged — wrappers update transparently for callers.
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

  -- Membership gate: enforced for authenticated callers; service_role
  -- (no auth.uid()) skips because edge functions / cron jobs emit events
  -- on behalf of the platform without a user identity.
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

-- =========================================================
-- 4. Seed schemas for 5 high-impact event types (warn mode)
-- =========================================================
-- eventClosed: three observed shapes in prod (drift discovered
-- 2026-05-17 when this validator was first run): manual close_event
-- RPC, auto-close cron, and rule-engine results writeback. Loosened
-- to no-required + type-only checks until the emitters converge on a
-- single shape. The drift itself is a separate cleanup.
insert into public.system_event_payload_schemas (event_type, schema, mode, notes)
values (
  'eventClosed',
  jsonb_build_object(
    'required',   jsonb_build_array(),
    'properties', jsonb_build_object(
      'title',       jsonb_build_object('type','string'),
      'closed_at',   jsonb_build_object('type','string'),
      'status',      jsonb_build_object('type','string'),
      'host_id',     jsonb_build_object('type','string'),
      'starts_at',   jsonb_build_object('type','string'),
      'auto_closed', jsonb_build_object('type','boolean'),
      'results',     jsonb_build_object('type','array')
    )
  ),
  'warn',
  'Three observed shapes in prod (drift discovered 2026-05-17): manual close (title/closed_at/status), auto-close cron (host_id/starts_at/auto_closed), and rule engine writeback (results[]). No required keys until emitters converge — type checks only.'
) on conflict (event_type) do nothing;

-- fineOfficialized: emitted by rule engine consequence (proposeFine).
-- Verified against prod 2026-05-17: shape is {amount, rule_id};
-- fine_id is set only by manual issue paths (which today don't emit
-- this atom).
insert into public.system_event_payload_schemas (event_type, schema, mode, notes)
values (
  'fineOfficialized',
  jsonb_build_object(
    'required',   jsonb_build_array('amount','rule_id'),
    'properties', jsonb_build_object(
      'amount',  jsonb_build_object('type', 'number'),
      'rule_id', jsonb_build_object('type', 'string'),
      'fine_id', jsonb_build_object('type', 'string')
    )
  ),
  'warn',
  'Emitted by rule engine consequence (proposeFine). Prod shape: {amount, rule_id}. fine_id is optional and only set by manual issue paths.'
) on conflict (event_type) do nothing;

-- finePaid: emitted by pay_fine.
insert into public.system_event_payload_schemas (event_type, schema, mode, notes)
values (
  'finePaid',
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
) on conflict (event_type) do nothing;

-- fineVoided: emitted by void_fine + on_fine_appeal_resolved.
insert into public.system_event_payload_schemas (event_type, schema, mode, notes)
values (
  'fineVoided',
  jsonb_build_object(
    'required',   jsonb_build_array('amount','reason'),
    'properties', jsonb_build_object(
      'amount',           jsonb_build_object('type', 'number'),
      'reason',           jsonb_build_object('type', 'string'),
      'voided_by_user_id',jsonb_build_object('type', 'string')
    )
  ),
  'warn',
  'Emitted by void_fine (mig 00142+00232) — manual void. Appeal-passed voiding goes through ledger_entry(fine_voided) instead and does NOT emit a fineVoided system_event (verify before flipping to strict).'
) on conflict (event_type) do nothing;

-- voteResolved: emitted by finalize_vote.
insert into public.system_event_payload_schemas (event_type, schema, mode, notes)
values (
  'voteResolved',
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
) on conflict (event_type) do nothing;
