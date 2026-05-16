-- 00204 — slot resource_type wizard branch.
--
-- Next canonical resource_type after space (mig 00203). Slot is the
-- momentary reservable capacity unit (turno, asiento, horario, mesa) —
-- distinct from event (a temporal occurrence) and asset (the parent
-- persistent object that exposes the slot).
--
-- Unlike event / fund / asset / space / right, slot is **dependent**:
-- every slot belongs to a parent asset. Existing backend already supports
-- this end-to-end:
--   - `create_slot(p_asset_id, p_starts_at, p_ends_at)` (mig 00070)
--   - `assign_slot`, `book_slot`, `request_slot_swap` lifecycle RPCs
--   - 5 slot atoms + 3 booking atoms whitelisted
--   - 21+ capabilities declare slot in enabled_resource_types
--   - `shared_resource` template seeds slot_assignment + slot_swap_request
--   - `emit-slot-system-events` cron drives `slotExpired`
--
-- The one missing piece is the wizard's atomic submit path: until now
-- `build_resource_from_draft` had no `when 'slot'` branch, so the iOS
-- ResourceWizard couldn't route a slot draft through. The `BuilderField
-- .resourcePicker` (commit 7e29b8d) unblocks asset selection from the
-- wizard; this migration closes the SQL side.
--
-- Doctrine
-- ========
-- Constitution §2: polymorphic via `resources.resource_type`. Slot
-- metadata (asset_id, starts_at, ends_at, assigned_member_id, booking_id)
-- lives in `resources.metadata` jsonb. No dedicated `slots` table.
--
-- Constitution §5: capabilities are universal. Slot already inherits 21+
-- catalog rows from prior seeding — no additions needed here.
--
-- Changes
-- =======
--   1. `build_resource_from_draft` extended with `when 'slot'` branch.
--      Function body reproduces every existing branch verbatim — including
--      the prod-only right branch from mig 00198+00201 — because CREATE
--      OR REPLACE rewrites wholesale. The slot branch parses three fields
--      from `p_basic_fields` (assetId / startsAt / endsAt), defers all
--      semantic validation to `create_slot` (asset exists + active,
--      caller has assignSlot permission, starts_at < ends_at), and
--      delegates.
--
-- Whitelist + capability changes NOT NEEDED — both are already in place
-- from earlier migrations (00070 + 00135 + 00165 + 00203). This is
-- purely the wizard-side wiring.
--
-- Out of scope (intentional, follow-up slices):
--   - Standalone `bookings` atom table. Per Constitution §7 it remains
--     Phase 2 work. Today bookings live as `resource_type='booking'`
--     rows in `resources` (mig 00070).
--   - `slotCreated` / `slotReleased` atoms. Mig 00070 explicitly chose
--     to NOT emit on slot creation ("operational, not governance-relevant").
--     If demand-pull shifts that doctrine, a follow-up adds the atom +
--     trigger.

-- =============================================================================
-- build_resource_from_draft — add slot branch (preserve all existing branches)
-- =============================================================================

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
  v_slot_asset_id        uuid;
  v_slot_starts_at       timestamptz;
  v_slot_ends_at         timestamptz;
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

    insert into public.resource_series (group_id, resource_type, pattern, metadata, created_by)
    values (p_group_id, p_resource_type, p_series_pattern, v_series_metadata, v_uid)
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
      v_rsvp_deadline_raw := nullif(trim(coalesce(p_capability_configs->'rsvp'->>'deadline', '')), '');
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
        p_group_id := p_group_id, p_title := v_event_title, p_starts_at := v_event_starts_at,
        p_duration_minutes := v_event_duration, p_location_name := v_event_location,
        p_location_lat := null, p_location_lng := null, p_host_id := null,
        p_cover_image_name := null, p_cover_image_url := null,
        p_description := v_event_description, p_apply_rules := true,
        p_is_recurring_generated := false, p_rsvp_deadline := v_event_deadline
      ) as e;

  when 'asset' then
    v_asset_name     := p_basic_fields->>'name';
    v_asset_capacity := (p_basic_fields->>'capacity')::int;
    if v_asset_name is null or length(trim(v_asset_name)) < 1 then
      raise exception 'asset name required';
    end if;
    v_resource_id := public.create_asset(
      p_group_id := p_group_id, p_name := v_asset_name, p_capacity := v_asset_capacity
    );

  when 'fund' then
    v_fund_name     := p_basic_fields->>'name';
    v_fund_target   := nullif(p_basic_fields->>'targetAmountCents', '')::bigint;
    v_fund_currency := coalesce(p_basic_fields->>'currency', 'MXN');
    if v_fund_name is null or length(trim(v_fund_name)) < 1 then
      raise exception 'fund name required';
    end if;
    v_resource_id := public.create_fund(
      p_group_id := p_group_id, p_name := v_fund_name,
      p_target_amount_cents := v_fund_target, p_currency := v_fund_currency
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

  when 'slot' then
    -- mig 00204: wizard-driven slot creation. Slot is dependent on a
    -- parent asset (created via the resource picker in the wizard).
    -- Semantic validation (asset exists + active, caller has assignSlot,
    -- starts_at < ends_at) is enforced by `create_slot` (mig 00070);
    -- this branch only parses the three basic fields.
    v_slot_asset_id  := nullif(p_basic_fields->>'assetId', '')::uuid;
    v_slot_starts_at := nullif(p_basic_fields->>'startsAt', '')::timestamptz;
    v_slot_ends_at   := nullif(p_basic_fields->>'endsAt', '')::timestamptz;
    if v_slot_asset_id is null then
      raise exception 'slot assetId required';
    end if;
    if v_slot_starts_at is null then
      raise exception 'slot startsAt required';
    end if;
    if v_slot_ends_at is null then
      raise exception 'slot endsAt required';
    end if;
    v_resource_id := public.create_slot(
      p_asset_id  := v_slot_asset_id,
      p_starts_at := v_slot_starts_at,
      p_ends_at   := v_slot_ends_at
    );

  else
    raise exception 'resource_type % not supported by build_resource_from_draft yet', p_resource_type;
  end case;

  if v_series_id is not null then
    update public.resources set series_id = v_series_id where id = v_resource_id;
  end if;

  if p_enabled_capabilities is not null then
    foreach v_capability in array p_enabled_capabilities loop
      insert into public.resource_capabilities (
        resource_id, capability_block_id, config, enabled, enabled_by
      )
      values (
        v_resource_id, v_capability,
        coalesce(p_capability_configs->v_capability, '{}'::jsonb),
        true, v_uid
      )
      on conflict (resource_id, capability_block_id)
        do update set
          enabled = excluded.enabled, config = excluded.config,
          enabled_by = excluded.enabled_by, enabled_at = now();
    end loop;
  end if;

  if p_initial_rules is not null and jsonb_array_length(p_initial_rules) > 0 then
    for v_rule in select * from jsonb_array_elements(p_initial_rules) loop
      v_rule_name := coalesce(v_rule->>'name', 'Regla sin nombre');
      insert into public.rules (
        group_id, resource_id, slug, name, is_active,
        trigger, conditions, consequences,
        module_key, series_id, membership_id, proposed_by
      )
      values (
        p_group_id, v_resource_id, v_rule->>'slug', v_rule_name,
        coalesce((v_rule->>'isActive')::boolean, true),
        coalesce(v_rule->'trigger', '{}'::jsonb),
        coalesce(v_rule->'conditions', '[]'::jsonb),
        coalesce(v_rule->'consequences', '[]'::jsonb),
        null, v_series_id, null, v_uid
      );
    end loop;
  end if;

  return v_resource_id;
end;
$$;

comment on function public.build_resource_from_draft(uuid, text, jsonb, text[], jsonb, jsonb, jsonb) is
  'Atomic ResourceWizard submit. v7 (00204): added slot branch — parses assetId/startsAt/endsAt and delegates to create_slot. All prior branches (event/asset/fund/right/space) preserved verbatim. Mig 00204.';
