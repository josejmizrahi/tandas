-- 00129 — Tier 2: align rsvp deadline source-of-truth.
--
-- Today `build_resource_from_draft` (00101) calls `create_event_v2`
-- WITHOUT threading the wizard's rsvp capability config through. The
-- result: the event row is inserted first with the legacy
-- `starts_at - 4h` fallback, and only afterwards do
-- `resource_capabilities` rows get the wizard's `deadline`. From that
-- point on, two sources of truth coexist:
--   - `events.rsvp_deadline`       — what `emit-deadline-events` reads
--   - `resource_capabilities.config->'rsvp'->>'deadline'` — what the
--                                    user actually picked in the wizard
--
-- They are usually different. The cron fires `rsvpDeadlinePassed` at
-- the legacy T-4h, not at the user's chosen time.
--
-- Audit "Create Resource Flow — Matriz de Verdad", criterio #4:
--   "Cada required field se guarda en capability_config — ⚠ se guarda,
--    pero nadie la lee."
--
-- Fix: in the event branch of `build_resource_from_draft`, extract the
-- absolute timestamp the wizard already resolved and pass it via the
-- existing `p_rsvp_deadline` parameter (added in mig 00126). The iOS
-- catalog's `RsvpCapability.optionalFields` declares `deadline` with
-- kind `.dateTime`, so the wizard ships an ISO8601 string in
-- `p_capability_configs->'rsvp'->>'deadline'`. No signature change to
-- `create_event_v2` — it already accepts the override.
--
-- Out of scope (intentional):
--   - `emit-deadline-events`: keeps reading `events.rsvp_deadline`.
--     With this migration that column now reflects the wizard's choice,
--     so no edge function update is needed for the wizard path.
--   - Later edits to rsvp cap_config don't resync `events.rsvp_deadline`.
--     A trigger could backfill on update, but that's a separate slice —
--     the wizard's once-at-creation deadline is the Tier 2 contract.
--   - Recurrence (auto-generate-events): the series doesn't carry rsvp
--     cap_config today; generated occurrences keep the T-4h fallback
--     until the series metadata schema gains a deadline field.
--
-- Tier 1.7 quarantines remain: shared_resource e2e still raises because
-- `build_resource_from_draft` only supports event + asset.

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
  if p_series_pattern is not null and p_series_pattern <> '{}'::jsonb then
    insert into public.resource_series (
      group_id, resource_type, pattern, metadata, created_by
    )
    values (
      p_group_id,
      p_resource_type,
      p_series_pattern,
      coalesce(p_basic_fields, '{}'::jsonb),
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
    -- Tolerates absent/blank/malformed values silently — those fall
    -- back to T-4h, identical to pre-Tier-2 behavior.
    if p_capability_configs is not null then
      v_rsvp_deadline_raw := nullif(
        trim(coalesce(p_capability_configs->'rsvp'->>'deadline', '')),
        ''
      );
      if v_rsvp_deadline_raw is not null then
        begin
          v_event_deadline := v_rsvp_deadline_raw::timestamptz;
        exception when others then
          -- Malformed ISO8601 → ignore; fall back to T-4h. Cheaper than
          -- failing the whole atomic submit over a single bad field.
          v_event_deadline := null;
        end;
      end if;
    end if;

    -- create_event_v2 returns `public.events` (the full row, not a bare
    -- uuid), so we extract `.id`. 00101 had this same call returning the
    -- record into a uuid variable, which Postgres surfaced at runtime as
    -- "invalid input syntax for type uuid: '(<row tuple>)'" — fixed here
    -- by selecting the id explicitly.
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
  'Atomic ResourceWizard submit. Creates resource + series + capabilities + rules in one transaction. v2 (00129): for events, threads p_capability_configs->rsvp->>deadline as p_rsvp_deadline into create_event_v2 so the wizard''s choice materializes in events.rsvp_deadline (and thus is what emit-deadline-events reads). Falls back to T-4h when absent or malformed.';
