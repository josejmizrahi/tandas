-- Rollback 00129 — restore the 00101 body of build_resource_from_draft.
-- The function signature is unchanged so CREATE OR REPLACE is enough.

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
  v_uid              uuid := auth.uid();
  v_resource_id      uuid;
  v_series_id        uuid;
  v_capability       text;
  v_rule             jsonb;
  v_rule_name        text;
  v_event_starts_at  timestamptz;
  v_event_title      text;
  v_event_duration   int;
  v_event_location   text;
  v_event_description text;
  v_asset_name       text;
  v_asset_capacity   int;
begin
  if v_uid is null then
    raise exception 'auth required';
  end if;

  if not public.is_group_member(p_group_id, v_uid) then
    raise exception 'not a member of this group';
  end if;

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

    declare
      v_event_id uuid;
    begin
      v_event_id := public.create_event_v2(
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
        p_is_recurring_generated := false
      );
      v_resource_id := v_event_id;
    end;

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
  'Atomic ResourceWizard submit. Creates resource + series + capabilities + rules in one transaction. Polymorphic by p_resource_type. Phase 1 supports event + asset; other types raise until their create_* helpers ship. Founder framing 2026-05-11 #5.';
