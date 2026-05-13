-- 00137 — Tier 6 slice 19: `fund` resource_type creation path.
--
-- Background
-- ==========
-- `ResourceType.fund` has lived in the iOS enum + the polymorphic
-- `resources` table since BigBang (mig 00078), and the
-- `ResourceTypePickerView` displays it as a "Próximamente" card. But
-- there's been no backend path to materialize one: `create_fund` RPC
-- didn't exist, and `build_resource_from_draft` raised on
-- resource_type='fund' (mig 00101's `else` branch).
--
-- Net effect: any iOS user tapping "Fondo" got the disabled placeholder
-- forever. With Tier 6 slice 18 shipping balance projection (mig 00136),
-- a fund resource is now immediately useful — it gives users a place to
-- record contributions / payouts that aggregate into a real balance.
--
-- Changes
-- =======
--   1. Add `'fundCreated'` to is_known_system_event_type whitelist
--      (Swift enum + TS catalog get the matching change in this
--      commit's iOS / shared/types updates).
--   2. New `create_fund(p_group_id, p_name, p_target_amount_cents?,
--      p_currency?)` RPC. Mirrors `create_asset` (mig 00070). Stores
--      target + currency in metadata. Emits `fundCreated`.
--   3. New `'fund'` branch in `build_resource_from_draft` so the iOS
--      ResourceWizard's submit path lights up.
--
-- Out of scope (intentional, for follow-up slices):
--   - `fundDeposit` / `fundThresholdReached` automatic emitters. The
--     types are in the whitelist (00117) but no edge function fires
--     them yet. Manual recording via `record_ledger_entry` with type=
--     'contribution' targeting the fund's resource_id works today.
--   - Fund-specific UI surface (separate ResourceDetailSheet zones).
--     The polymorphic UniversalResourceDetailView already renders any
--     resource with money/ledger capabilities — fund inherits the
--     balance projection from slice 18 for free.

-- =========================================================
-- 1. Extend is_known_system_event_type with fundCreated
-- =========================================================

create or replace function public.is_known_system_event_type(p_event_type text)
returns boolean
language sql
immutable
parallel safe
set search_path = public
as $$
  -- Keep in sync with
  -- ios/Packages/RuulCore/Sources/RuulCore/PlatformModels/SystemEventType.swift
  -- and supabase/functions/_shared/types/systemEventType.ts.
  select p_event_type = any (array[
    'eventClosed',
    'eventCreated',
    'rsvpDeadlinePassed',
    'hoursBeforeEvent',
    'rsvpSubmitted',
    'rsvpChangedSameDay',
    'checkInRecorded',
    'checkInMissed',
    'eventDescriptionMissing',
    'slotAssigned',
    'slotDeclined',
    'slotExpired',
    'slotSwapRequested',
    'slotSwapApproved',
    'bookingCreated',
    'bookingCancelled',
    'bookingExpired',
    'assetCreated',
    'fineOfficialized',
    'fineVoided',
    'finePaid',
    'fineReminderSent',
    'appealCreated',
    'appealResolved',
    'voteOpened',
    'voteCast',
    'voteResolved',
    'fundCreated',
    'fundDeposit',
    'fundThresholdReached',
    'positionChanged',
    'memberJoined',
    'memberLeft',
    'ruleEnabledChanged',
    'ruleAmountChanged',
    'pendingChangeApplied'
  ]);
$$;

comment on function public.is_known_system_event_type(text) is
  'Whitelist check for system_events.event_type values. Mirrors the SystemEventType Swift enum. Update + redeploy whenever the enum grows. CHECK constraint system_events_event_type_known_chk (00095) enforces this at INSERT time. v6 (00137): added fundCreated.';

-- =========================================================
-- 2. create_fund RPC
-- =========================================================

create or replace function public.create_fund(
  p_group_id            uuid,
  p_name                text,
  p_target_amount_cents bigint  default null,
  p_currency            text    default 'MXN'
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller_id uuid := auth.uid();
  v_fund_id   uuid;
begin
  if v_caller_id is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;

  -- Any group member can create a fund — money is a group activity,
  -- not an admin-only one. The SECURITY DEFINER bypasses RLS on
  -- resources for the insert; membership gate restores authorization.
  if not public.is_group_member(p_group_id, v_caller_id) then
    raise exception 'not a member of this group' using errcode = '42501';
  end if;

  if p_name is null or length(trim(p_name)) = 0 then
    raise exception 'fund name required' using errcode = '22023';
  end if;

  if p_target_amount_cents is not null and p_target_amount_cents < 0 then
    raise exception 'target_amount must be non-negative' using errcode = '22023';
  end if;

  insert into public.resources (group_id, resource_type, status, metadata, created_by)
  values (
    p_group_id,
    'fund',
    'active',
    jsonb_build_object(
      'name',                trim(p_name),
      'target_amount_cents', p_target_amount_cents,
      'currency',            coalesce(p_currency, 'MXN')
    ),
    v_caller_id
  )
  returning id into v_fund_id;

  perform public.record_system_event(
    p_group_id,
    'fundCreated',
    v_fund_id,
    null,
    jsonb_build_object(
      'name',                trim(p_name),
      'target_amount_cents', p_target_amount_cents,
      'currency',            coalesce(p_currency, 'MXN')
    )
  );

  return v_fund_id;
end;
$$;

revoke execute on function public.create_fund(uuid, text, bigint, text) from public, anon;
grant  execute on function public.create_fund(uuid, text, bigint, text) to authenticated;

comment on function public.create_fund(uuid, text, bigint, text) is
  'Tier 6 slice 19: create a fund resource. Any group member may call. Stores name + optional target_amount_cents + currency in resources.metadata. Emits fundCreated. ledger_entries scoped to this resource_id aggregate into member_balances_per_resource (mig 00136).';

-- =========================================================
-- 3. build_resource_from_draft — fund branch
-- =========================================================

create or replace function public.build_resource_from_draft(
  p_group_id              uuid,
  p_resource_type         text,
  p_basic_fields          jsonb,
  p_enabled_capabilities  text[],
  p_capability_configs    jsonb,
  p_series_pattern        jsonb,
  p_initial_rules         jsonb
)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_uid               uuid := auth.uid();
  v_resource_id       uuid;
  v_series_id         uuid;
  v_capability        text;
  v_rule              jsonb;
  v_rule_name         text;
  v_event_starts_at   timestamptz;
  v_event_title       text;
  v_event_duration    int;
  v_event_location    text;
  v_event_description text;
  v_event_deadline    timestamptz;
  v_rsvp_deadline_raw text;
  v_series_metadata   jsonb;
  v_asset_name        text;
  v_asset_capacity    int;
  v_fund_name         text;
  v_fund_target       bigint;
  v_fund_currency     text;
begin
  if v_uid is null then
    raise exception 'auth required';
  end if;

  if not public.is_group_member(p_group_id, v_uid) then
    raise exception 'not a member of this group';
  end if;

  if p_series_pattern is not null and p_series_pattern <> '{}'::jsonb then
    v_series_metadata := coalesce(p_basic_fields, '{}'::jsonb);
    if p_capability_configs is not null and p_capability_configs <> '{}'::jsonb then
      v_series_metadata := v_series_metadata
        || jsonb_build_object('capability_configs', p_capability_configs);
    end if;

    insert into public.resource_series (
      group_id, resource_type, pattern, metadata, created_by
    )
    values (
      p_group_id,
      p_resource_type,
      p_series_pattern,
      v_series_metadata,
      v_uid
    )
    returning id into v_series_id;
  end if;

  case p_resource_type
  when 'event' then
    v_event_title       := p_basic_fields->>'title';
    v_event_starts_at   := (p_basic_fields->>'startsAt')::timestamptz;
    v_event_duration    := coalesce((p_basic_fields->>'durationMinutes')::int, 180);
    v_event_location    := p_basic_fields->>'location';
    v_event_description := p_basic_fields->>'description';

    if v_event_title is null or length(trim(v_event_title)) < 1 then
      raise exception 'event title required';
    end if;
    if v_event_starts_at is null then
      raise exception 'event startsAt required';
    end if;

    if p_capability_configs is not null then
      v_rsvp_deadline_raw := nullif(
        trim(coalesce(p_capability_configs->'rsvp'->>'deadline', '')),
        ''
      );
      if v_rsvp_deadline_raw is not null then
        begin
          v_event_deadline := v_rsvp_deadline_raw::timestamptz;
        exception when others then
          v_event_deadline := null;
        end;
      end if;
    end if;

    select e.id into v_resource_id
      from public.create_event_v2(
        p_group_id            := p_group_id,
        p_title               := v_event_title,
        p_starts_at           := v_event_starts_at,
        p_duration_minutes    := v_event_duration,
        p_location_name       := v_event_location,
        p_location_lat        := null,
        p_location_lng        := null,
        p_host_id             := null,
        p_cover_image_name    := null,
        p_cover_image_url     := null,
        p_description         := v_event_description,
        p_apply_rules         := true,
        p_is_recurring_generated := false,
        p_rsvp_deadline       := v_event_deadline
      ) as e;

  when 'asset' then
    v_asset_name     := p_basic_fields->>'name';
    v_asset_capacity := (p_basic_fields->>'capacity')::int;

    if v_asset_name is null or length(trim(v_asset_name)) < 1 then
      raise exception 'asset name required';
    end if;

    v_resource_id := public.create_asset(
      p_group_id := p_group_id,
      p_name     := v_asset_name,
      p_capacity := v_asset_capacity
    );

  when 'fund' then
    -- Tier 6 slice 19 (mig 00137): wizard-driven fund creation.
    -- Mirrors the asset branch — name required, target_amount_cents
    -- + currency optional in basic_fields. target_amount_cents is a
    -- soft goal (UI shows progress vs target); not a hard limit.
    v_fund_name     := p_basic_fields->>'name';
    v_fund_target   := nullif(p_basic_fields->>'targetAmountCents', '')::bigint;
    v_fund_currency := coalesce(p_basic_fields->>'currency', 'MXN');

    if v_fund_name is null or length(trim(v_fund_name)) < 1 then
      raise exception 'fund name required';
    end if;

    v_resource_id := public.create_fund(
      p_group_id            := p_group_id,
      p_name                := v_fund_name,
      p_target_amount_cents := v_fund_target,
      p_currency            := v_fund_currency
    );

  else
    raise exception 'resource_type % not supported by build_resource_from_draft yet', p_resource_type;
  end case;

  if v_series_id is not null then
    update public.resources
       set series_id = v_series_id
     where id = v_resource_id;
  end if;

  if p_enabled_capabilities is not null then
    foreach v_capability in array p_enabled_capabilities loop
      insert into public.resource_capabilities (
        resource_id,
        capability_block_id,
        config,
        enabled,
        enabled_by
      )
      values (
        v_resource_id,
        v_capability,
        coalesce(p_capability_configs->v_capability, '{}'::jsonb),
        true,
        v_uid
      )
      on conflict (resource_id, capability_block_id)
        do update set
          enabled = excluded.enabled,
          config  = excluded.config,
          enabled_by = excluded.enabled_by,
          enabled_at = now();
    end loop;
  end if;

  if p_initial_rules is not null and jsonb_array_length(p_initial_rules) > 0 then
    for v_rule in
      select * from jsonb_array_elements(p_initial_rules)
    loop
      v_rule_name := coalesce(v_rule->>'name', 'Regla sin nombre');
      insert into public.rules (
        group_id, resource_id, slug, name, is_active,
        trigger, conditions, consequences,
        module_key, series_id, membership_id,
        proposed_by
      )
      values (
        p_group_id,
        v_resource_id,
        v_rule->>'slug',
        v_rule_name,
        coalesce((v_rule->>'isActive')::boolean, true),
        coalesce(v_rule->'trigger', '{}'::jsonb),
        coalesce(v_rule->'conditions', '[]'::jsonb),
        coalesce(v_rule->'consequences', '[]'::jsonb),
        null,
        v_series_id,
        null,
        v_uid
      );
    end loop;
  end if;

  return v_resource_id;
end;
$$;

comment on function public.build_resource_from_draft(uuid, text, jsonb, text[], jsonb, jsonb, jsonb) is
  'Atomic ResourceWizard submit. v4 (00137): added `fund` branch — calls create_fund with name + optional targetAmountCents + currency from basic_fields. Series-level capability_configs envelope (Tier 5) preserved. rsvp.deadline thread (Tier 2) preserved.';
