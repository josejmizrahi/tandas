-- 00132 — Tier 5 Beta: rotation as capability on resource_series.
--
-- Founder decision 2026-05-13: rotation is a capability of resource_series,
-- not a standalone resource_type. The wizard's per-series rotation
-- config persists into the series row, and the cron generator consults
-- it when materializing each occurrence to pick the host.
--
-- Pre-Tier-5: `next_host_for_group(group_id, cycle)` reads
-- `group_members.turn_order` — a group-wide rotation set via
-- `set_turn_order` RPC. That's V1 behavior (one rotation per group).
-- It stays as the fallback when a series has no rotation cap_config,
-- so legacy `recurring_dinner` groups keep working unchanged.
--
-- This migration adds two pieces:
--
-- 1. `build_resource_from_draft` v3: when creating a series for an event,
--    merge the wizard's `p_capability_configs` into the series row's
--    `metadata` jsonb under the key `capability_configs`. Existing
--    metadata fields (title, durationMinutes, etc.) preserved as
--    top-level keys; cap configs sit beside them. Future capabilities
--    (capacity per series, voting per series, etc.) reuse the same
--    envelope shape.
--
-- 2. `next_host_for_series(p_series_id, p_cycle)`: reads the series's
--    rotation cap_config and returns the user_id who should host cycle
--    p_cycle. Order strategies:
--      - "sequential" — round-robin over participants[] in declared
--        order. Cycle 1 → participants[0], cycle 2 → participants[1],
--        wrap around at length(participants).
--      - "random" — deterministic per (series_id, cycle). Hash-driven
--        so re-runs of auto-generate-events for the same cycle pick
--        the same host; idempotent without a stored mapping table.
--
--    Replacement policy:
--      - "skip_to_next" (default) — if the elected participant isn't
--        an active member of the group anymore, advance to the next
--        one in rotation. Recurses up to N=length(participants) times
--        to avoid infinite loops; returns NULL if nobody is active.
--      - "host_stays_until_swap" — keep the elected user_id even if
--        they left. The caller (auto-generate-events / create_event_v2)
--        decides what to do with a null/inactive host downstream.
--
-- Frequency is honored at the caller (auto-generate-events) — for
-- Tier 5 Beta only `every_event` is supported, so the caller passes
-- cycle = (occurrence_index + 1). When `every_n_events` arrives
-- the caller will divide.
--
-- Out of Tier 5 Beta scope (per founder 2026-05-13):
--   - rotation as resource_type (this stays a capability)
--   - swap requests / marketplace / voting on swaps
--   - rotation shared across multiple resources in a group
--   - money/payout rotation

-- =============================================================================
-- 1. build_resource_from_draft v3 — merge capability_configs into series.metadata
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
begin
  if v_uid is null then
    raise exception 'auth required';
  end if;

  if not public.is_group_member(p_group_id, v_uid) then
    raise exception 'not a member of this group';
  end if;

  -- =========================================================
  -- 1. Optional ResourceSeries (recurring resources only)
  -- =========================================================
  -- Tier 5 (mig 00132): when a series gets created, fold the wizard's
  -- capability_configs into metadata so the cron generator can read
  -- them per occurrence (next_host_for_series, future per-series caps).
  -- We do NOT clone the configs into each occurrence's
  -- resource_capabilities — those rows still live on the specific
  -- occurrence resource and represent the as-instantiated state. The
  -- series metadata is the template; the per-occurrence rows are
  -- the materialized snapshot.
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

  -- =========================================================
  -- 2. Create the resource row, dispatching by type
  -- =========================================================
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

    -- Tier 2 (mig 00129): pull the rsvp deadline out of the wizard's
    -- capability_config so create_event_v2 materializes events.rsvp_deadline
    -- with the user's choice instead of the legacy T-4h fallback.
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

  else
    raise exception 'resource_type % not supported by build_resource_from_draft yet', p_resource_type;
  end case;

  -- =========================================================
  -- 3. Link to series (if we created one)
  -- =========================================================
  if v_series_id is not null then
    update public.resources
       set series_id = v_series_id
     where id = v_resource_id;
  end if;

  -- =========================================================
  -- 4. Enable capabilities
  -- =========================================================
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

  -- =========================================================
  -- 5. Seed initial rules
  -- =========================================================
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
  'Atomic ResourceWizard submit. v3 (00132): when a series is created, merges p_capability_configs into resource_series.metadata under the "capability_configs" key so the cron generator can read per-series capabilities (rotation, future per-series caps). Per-occurrence resource_capabilities rows still get written for the immediate occurrence — the series metadata is the template, per-occurrence is the materialized snapshot.';

-- =============================================================================
-- 2. next_host_for_series — rotation evaluator for series-scoped cap config
-- =============================================================================

create or replace function public.next_host_for_series(
  p_series_id uuid,
  p_cycle     int
)
returns uuid
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_series       public.resource_series;
  v_cfg          jsonb;
  v_participants jsonb;
  v_order        text;
  v_replacement  text;
  v_count        int;
  v_idx          int;
  v_candidate    uuid;
  v_attempts     int := 0;
  v_max_attempts int;
begin
  if p_series_id is null or p_cycle is null or p_cycle < 1 then
    return null;
  end if;

  select * into v_series from public.resource_series where id = p_series_id;
  if not found then
    return null;
  end if;

  -- The wizard config lives at metadata.capability_configs.rotation
  -- (per mig 00132 build_resource_from_draft v3 envelope).
  v_cfg := coalesce(
    v_series.metadata->'capability_configs'->'rotation',
    '{}'::jsonb
  );

  v_participants := v_cfg->'participants';
  if v_participants is null or jsonb_typeof(v_participants) <> 'array'
     or jsonb_array_length(v_participants) = 0 then
    -- No rotation config → caller falls back to legacy
    -- next_host_for_group / null behavior.
    return null;
  end if;

  v_count := jsonb_array_length(v_participants);
  v_order := coalesce(v_cfg->>'order', 'sequential');
  v_replacement := coalesce(v_cfg->>'replacementPolicy', 'skip_to_next');
  v_max_attempts := case when v_replacement = 'skip_to_next' then v_count else 1 end;

  -- Sequential: position N maps to participants[(N-1) mod count].
  -- Random: deterministic per (series_id, cycle). hashtextextended
  -- gives a stable 64-bit hash that doesn't depend on the row's
  -- physical layout, so the same (series, cycle) returns the same
  -- index across runs (idempotency requirement for the cron).
  if v_order = 'random' then
    v_idx := (
      abs(hashtextextended(p_series_id::text || ':' || p_cycle::text, 0))
      % v_count
    )::int;
  else
    v_idx := ((p_cycle - 1) % v_count);
  end if;

  loop
    -- jsonb arrays are 0-indexed via the `->` operator. Cast text to uuid;
    -- malformed values fall through to NULL via the `try` pattern below.
    begin
      v_candidate := (v_participants->>v_idx)::uuid;
    exception when others then
      v_candidate := null;
    end;

    if v_candidate is not null then
      -- skip_to_next: if candidate isn't an active member, advance.
      -- host_stays_until_swap: return whatever the rotation elected,
      -- the caller decides how to handle inactive.
      if v_replacement = 'skip_to_next' then
        if exists (
          select 1 from public.group_members
           where group_id = v_series.group_id
             and user_id  = v_candidate
             and active   = true
        ) then
          return v_candidate;
        end if;
      else
        return v_candidate;
      end if;
    end if;

    v_attempts := v_attempts + 1;
    if v_attempts >= v_max_attempts then
      return null;
    end if;

    -- Advance to the next slot. For random order we re-hash with the
    -- attempt count so we don't loop on the same dead slot.
    if v_order = 'random' then
      v_idx := (
        abs(hashtextextended(p_series_id::text || ':' || p_cycle::text || ':' || v_attempts::text, 0))
        % v_count
      )::int;
    else
      v_idx := (v_idx + 1) % v_count;
    end if;
  end loop;
end;
$$;

revoke execute on function public.next_host_for_series(uuid, int) from public, anon;
grant  execute on function public.next_host_for_series(uuid, int) to authenticated, service_role;

comment on function public.next_host_for_series(uuid, int) is
  'Tier 5 Beta: returns the user_id who should host occurrence p_cycle of the given series, reading rotation config from resource_series.metadata.capability_configs.rotation. Supports order=sequential|random and replacementPolicy=skip_to_next|host_stays_until_swap. Returns NULL when no rotation cap_config is set, or when skip_to_next exhausts an all-inactive participant list.';
