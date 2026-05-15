-- 00203 — space resource_type writer + capability foundation.
--
-- Next canonical resource_type after fund (mig 00202). `space` is the
-- persistent administrable place primitive (cancha, salón, casa, oficina) —
-- distinct from `event` (temporal occurrence inside a space) and `slot`
-- (momentary capacity unit a space exposes). Per Constitution §2 it is
-- frozen in the ResourceType enum (mig 00147) but had no creation path
-- until this slice — analogous to fund pre-mig 00139.
--
-- Doctrine
-- ========
-- Constitution §2: polymorphic via `resources.resource_type`. No new
-- table — name / capacity / location / description live in
-- `resources.metadata` jsonb.
--
-- Constitution §5: capabilities are universal platform primitives.
-- Space inherits the existing booking / scheduling / check_in /
-- capacity / location / guest_access capability rows by adding
-- 'space' to each `enabled_resource_types` array — no fund-style
-- "space-only capability" gets invented.
--
-- HierarchyReference.md §3 — expected capabilities for space:
--   booking, schedule, check_in, capacity, location, guest_access,
--   availability, access_control
-- Of these, the catalog (mig 00165) currently exposes: booking, schedule,
-- check_in, capacity, location, guest_access. Those six get 'space' added.
-- `availability` and `access_control` are doctrinal placeholders without
-- catalog rows yet; they wait for their own demand-pull slices.
--
-- Changes
-- =======
--   1. `spaceCreated` added to is_known_system_event_type whitelist.
--      Whitelist snapshot mirrors the post-mig 00202 prod state — every
--      omitted entry would silently drop INSERT support for that event
--      type, so the full array is reproduced wholesale.
--
--   2. Catalog extension: six existing capability rows get 'space' added
--      to `enabled_resource_types` if missing. Idempotent — re-running
--      the migration is a no-op. Catalog write-lock (mig 00191) doesn't
--      apply to migration role.
--
--   3. `create_space(p_group_id, p_name, p_capacity?, p_location_name?,
--      p_location_lat?, p_location_lng?, p_description?)` RPC. Any group
--      member may call (matches mig 00144 create_asset doctrine — money
--      / venue creation is a group activity, not admin-gated). Stores
--      all knobs in `resources.metadata`. Emits `spaceCreated`.
--
--   4. `build_resource_from_draft` extended with `when 'space'` branch
--      so the iOS ResourceWizard's atomic submit path lights up for
--      space the same way it already works for event / asset / fund /
--      right.
--
-- Out of scope (intentional, follow-up slices):
--   - Bookings atom + projection. Per Constitution §7 the `bookings`
--     append-only table is Phase 2 work. Without it, a `spaces_view`
--     wouldn't have flows to project. Skip until demand-pull lands.
--   - Space-scoped governance templates (capacity-based vote, access
--     approval) — mirrors fund's deferred fund-scoped templates.
--   - Multi-room composite spaces. A space with sub-spaces would need
--     a parent_space_id column; today every space is independent.
--   - `availability` + `access_control` capability catalog rows.

-- =============================================================================
-- 1. Extend SystemEventType whitelist with spaceCreated
-- =============================================================================

create or replace function public.is_known_system_event_type(p_event_type text)
returns boolean
language sql
immutable parallel safe
set search_path = pg_catalog
as $function$
  -- Snapshot of the prod array (post mig 00202 fund_writers_balance_lifecycle)
  -- plus the new spaceCreated atom. CREATE OR REPLACE replaces the body
  -- wholesale; preserving every prior entry is mandatory.
  select p_event_type = any (array[
    'eventClosed', 'eventCreated', 'rsvpDeadlinePassed', 'hoursBeforeEvent',
    'rsvpSubmitted', 'rsvpChangedSameDay', 'checkInRecorded', 'checkInMissed',
    'eventDescriptionMissing',
    'slotAssigned', 'slotDeclined', 'slotExpired', 'slotSwapRequested', 'slotSwapApproved',
    'bookingCreated', 'bookingCancelled', 'bookingExpired',
    'assetCreated',
    'fineOfficialized', 'fineVoided', 'finePaid', 'fineReminderSent',
    'appealCreated', 'appealResolved',
    'voteOpened', 'voteCast', 'voteResolved',
    'fundCreated', 'fundDeposit', 'fundThresholdReached',
    'positionChanged', 'memberJoined', 'memberLeft',
    'ruleEnabledChanged', 'ruleAmountChanged',
    'pendingChangeApplied', 'inviteCodeRotated',
    'groupCreated', 'groupArchived', 'groupUnarchived', 'groupRenamed', 'governanceUpdated',
    'resourceArchived', 'resourceUnarchived', 'resourceRenamed',
    'capabilityToggled', 'capabilityConfigUpdated', 'memberCapabilityOverridden',
    'ledgerEntryCreated', 'warningEmitted',
    'resourceLinked', 'resourceUnlinked',
    'eventCancelled',
    'fundLocked', 'fundUnlocked',
    -- mig 00203: space lifecycle
    'spaceCreated'
  ]);
$function$;

-- =============================================================================
-- 2. Capabilities catalog — add 'space' to existing capability rows
-- =============================================================================
--
-- Idempotent: only appends 'space' when missing. No catalog row is
-- created here — every capability listed already exists (mig 00165).
-- If a capability hasn't been seeded, the corresponding UPDATE is a
-- no-op and the catalog stays consistent.

update public.capabilities
   set enabled_resource_types = array_append(enabled_resource_types, 'space')
 where id in ('booking', 'schedule', 'check_in', 'capacity', 'location', 'guest_access')
   and not ('space' = any (enabled_resource_types));

-- =============================================================================
-- 3. create_space RPC
-- =============================================================================

create or replace function public.create_space(
  p_group_id       uuid,
  p_name           text,
  p_capacity       int    default null,
  p_location_name  text   default null,
  p_location_lat   double precision default null,
  p_location_lng   double precision default null,
  p_description    text   default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  v_caller_id uuid := auth.uid();
  v_space_id  uuid;
  v_metadata  jsonb;
begin
  if v_caller_id is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;

  -- Any group member may create a space (matches mig 00144 create_asset
  -- doctrine). Booking governance and access control belong to rules,
  -- not the writer.
  if not public.is_group_member(p_group_id, v_caller_id) then
    raise exception 'not a member of this group' using errcode = '42501';
  end if;

  if p_name is null or length(trim(p_name)) = 0 then
    raise exception 'space name required' using errcode = '22023';
  end if;

  if p_capacity is not null and p_capacity < 0 then
    raise exception 'space capacity must be non-negative' using errcode = '22023';
  end if;

  -- Build metadata defensively: nulls drop out so the jsonb stays tight
  -- and the projection reads it cleanly. trim text fields to avoid empty
  -- strings winning over real nulls.
  v_metadata := jsonb_build_object('name', trim(p_name));
  if p_capacity      is not null then
    v_metadata := v_metadata || jsonb_build_object('capacity', p_capacity);
  end if;
  if p_location_name is not null and length(trim(p_location_name)) > 0 then
    v_metadata := v_metadata || jsonb_build_object('location_name', trim(p_location_name));
  end if;
  if p_location_lat  is not null then
    v_metadata := v_metadata || jsonb_build_object('location_lat', p_location_lat);
  end if;
  if p_location_lng  is not null then
    v_metadata := v_metadata || jsonb_build_object('location_lng', p_location_lng);
  end if;
  if p_description   is not null and length(trim(p_description))  > 0 then
    v_metadata := v_metadata || jsonb_build_object('description',  trim(p_description));
  end if;

  insert into public.resources (group_id, resource_type, status, metadata, created_by)
  values (
    p_group_id,
    'space',
    'active',
    v_metadata,
    v_caller_id
  )
  returning id into v_space_id;

  perform public.record_system_event(
    p_group_id,
    'spaceCreated',
    v_space_id,
    null,
    v_metadata
  );

  return v_space_id;
end;
$$;

revoke execute on function public.create_space(uuid, text, int, text, double precision, double precision, text) from public, anon;
grant  execute on function public.create_space(uuid, text, int, text, double precision, double precision, text) to authenticated;

comment on function public.create_space(uuid, text, int, text, double precision, double precision, text) is
  'Creates a space resource. Any group member may call. Stores name + optional capacity/location_name/lat/lng/description in resources.metadata; nulls and empty strings drop out. Emits spaceCreated. Mig 00203.';

-- =============================================================================
-- 4. build_resource_from_draft — space branch (preserves event/asset/fund/right)
-- =============================================================================
--
-- Snapshot of prod's current function (post mig 00201 right branch) plus
-- the new `when 'space'` arm. CREATE OR REPLACE rewrites wholesale, so
-- every existing branch — including the right branch that ships outside
-- the local repo's mig 00139 baseline — must be reproduced verbatim.

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
  v_uid                  uuid := auth.uid();
  v_resource_id          uuid;
  v_series_id            uuid;
  v_capability           text;
  v_rule                 jsonb;
  v_rule_name            text;
  v_event_starts_at      timestamptz;
  v_event_title          text;
  v_event_duration       int;
  v_event_location       text;
  v_event_description    text;
  v_event_deadline       timestamptz;
  v_rsvp_deadline_raw    text;
  v_series_metadata      jsonb;
  v_asset_name           text;
  v_asset_capacity       int;
  v_fund_name            text;
  v_fund_target          bigint;
  v_fund_currency        text;
  v_right_name           text;
  v_right_holder         uuid;
  v_right_target         uuid;
  v_right_capability     text;
  v_right_scope          text;
  v_right_priority       int;
  v_right_exclusive      boolean;
  v_right_transfer       boolean;
  v_right_delegable      boolean;
  v_right_divisible      boolean;
  v_right_expires_at     timestamptz;
  v_right_source         text;
  v_right_expires_raw    text;
  v_space_name           text;
  v_space_capacity       int;
  v_space_location_name  text;
  v_space_location_lat   double precision;
  v_space_location_lng   double precision;
  v_space_description    text;
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

  when 'right' then
    v_right_name        := p_basic_fields->>'name';
    v_right_holder      := nullif(p_basic_fields->>'holderMemberId', '')::uuid;
    v_right_target      := nullif(p_basic_fields->>'targetResourceId', '')::uuid;
    v_right_capability  := nullif(p_basic_fields->>'targetCapability', '');
    v_right_scope       := coalesce(nullif(p_basic_fields->>'scope', ''), 'resource');
    v_right_priority    := coalesce(nullif(p_basic_fields->>'priority', '')::int, 0);
    v_right_exclusive   := coalesce((p_basic_fields->>'exclusive')::boolean,    false);
    v_right_transfer    := coalesce((p_basic_fields->>'transferable')::boolean, false);
    v_right_delegable   := coalesce((p_basic_fields->>'delegable')::boolean,    false);
    v_right_divisible   := coalesce((p_basic_fields->>'divisible')::boolean,    false);
    v_right_source      := nullif(p_basic_fields->>'source', '');
    v_right_expires_raw := nullif(p_basic_fields->>'expiresAt', '');
    if v_right_expires_raw is not null then
      begin
        v_right_expires_at := v_right_expires_raw::timestamptz;
      exception when others then
        v_right_expires_at := null;
      end;
    end if;

    if v_right_name is null or length(trim(v_right_name)) < 1 then
      raise exception 'right name required';
    end if;

    v_resource_id := public.create_right(
      p_group_id            := p_group_id,
      p_name                := v_right_name,
      p_holder_member_id    := v_right_holder,
      p_target_resource_id  := v_right_target,
      p_target_capability   := v_right_capability,
      p_scope               := v_right_scope,
      p_priority            := v_right_priority,
      p_exclusive           := v_right_exclusive,
      p_transferable        := v_right_transfer,
      p_delegable           := v_right_delegable,
      p_divisible           := v_right_divisible,
      p_expires_at          := v_right_expires_at,
      p_source              := v_right_source
    );

  when 'space' then
    -- mig 00203: wizard-driven space creation. Mirrors the asset branch
    -- but accepts optional location knobs (name + coordinates) and a
    -- description so venues with addresses can land in one round-trip.
    v_space_name          := p_basic_fields->>'name';
    v_space_capacity      := nullif(p_basic_fields->>'capacity', '')::int;
    v_space_location_name := nullif(p_basic_fields->>'locationName', '');
    v_space_location_lat  := nullif(p_basic_fields->>'locationLat', '')::double precision;
    v_space_location_lng  := nullif(p_basic_fields->>'locationLng', '')::double precision;
    v_space_description   := nullif(p_basic_fields->>'description', '');

    if v_space_name is null or length(trim(v_space_name)) < 1 then
      raise exception 'space name required';
    end if;

    v_resource_id := public.create_space(
      p_group_id      := p_group_id,
      p_name          := v_space_name,
      p_capacity      := v_space_capacity,
      p_location_name := v_space_location_name,
      p_location_lat  := v_space_location_lat,
      p_location_lng  := v_space_location_lng,
      p_description   := v_space_description
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
  'Atomic ResourceWizard submit. v6 (00203): added space branch — calls create_space with name + optional capacity / location_name / location_lat / location_lng / description from basic_fields. Right branch (mig 00198+00201) preserved verbatim; series, capability bind, and rules seeding preserved.';
