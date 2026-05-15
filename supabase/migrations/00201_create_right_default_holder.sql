-- Mig 00201: default `create_right`'s holder to the caller when omitted,
-- + relax the build_resource_from_draft `right` branch to accept a null
-- holderMemberId.
--
-- Why
-- ===
-- The wizard's `.memberPicker` field-kind renders disabled today
-- (BuilderFieldRenderer: "Selector de miembros no disponible — Próximamente").
-- Mig 00198's `create_right` requires `p_holder_member_id` to be non-null,
-- and mig 00198's `build_resource_from_draft` requires
-- `basic_fields.holderMemberId` to be non-null. Together those gates make
-- the Right wizard card non-functional in the iOS UI: the user can fill
-- in `name` but can't fill `holderMemberId`, validation blocks submission.
--
-- Doctrinal stance: every right has a holder. The natural default is the
-- creator — they minted the claim, so they hold it until they transfer it.
-- A creator who wants to grant a right to someone else can use the member
-- picker (once wired) or transfer_right after creation. This matches the
-- "Activo compartido" doctrine where the creator becomes the row's
-- `created_by` and effective custodian.
--
-- Changes
-- =======
--   1. create_right: `p_holder_member_id uuid default null`. When null,
--      resolve from auth.uid() → group_members.id of the calling user
--      (active member of p_group_id). Service_role callers (auth.uid()=
--      null) MUST still supply the holder explicitly — there's no
--      "service_role's own member" to fall back to. Existing callers
--      that pass a UUID are unaffected.
--   2. build_resource_from_draft: when basic_fields.holderMemberId is
--      absent or empty, pass NULL to create_right and let it default.
--      Drops the "right holder required" check in the wizard path.

BEGIN;

create or replace function public.create_right(
  p_group_id            uuid,
  p_name                text,
  p_holder_member_id    uuid     default null,
  p_target_resource_id  uuid     default null,
  p_target_capability   text     default null,
  p_scope               text     default 'resource',
  p_priority            int      default 0,
  p_exclusive           boolean  default false,
  p_transferable        boolean  default false,
  p_delegable           boolean  default false,
  p_divisible           boolean  default false,
  p_expires_at          timestamptz default null,
  p_source              text     default null,
  p_extra               jsonb    default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller_id   uuid := auth.uid();
  v_right_id    uuid;
  v_holder      uuid := p_holder_member_id;
  v_holder_uid  uuid;
  v_target_grp  uuid;
  v_metadata    jsonb;
begin
  if v_caller_id is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;

  if not public.is_group_member(p_group_id, v_caller_id) then
    raise exception 'not a member of this group' using errcode = '42501';
  end if;

  if p_name is null or length(trim(p_name)) = 0 then
    raise exception 'right name required' using errcode = '22023';
  end if;

  -- Holder default (mig 00201): when caller didn't pass an explicit
  -- holder, the right vests in the caller. Resolves caller's auth.uid()
  -- to the matching active group_members.id row in p_group_id.
  if v_holder is null then
    select gm.id into v_holder
      from public.group_members gm
     where gm.user_id = v_caller_id
       and gm.group_id = p_group_id
       and gm.active = true
     limit 1;
    if v_holder is null then
      raise exception 'right holder required: caller has no active membership in this group'
        using errcode = '22023';
    end if;
  end if;

  -- holder must be an active member of the same group. Same check as
  -- mig 00198, retained for explicit-holder callers + sanity for the
  -- defaulted path.
  select gm.user_id into v_holder_uid
    from public.group_members gm
   where gm.id = v_holder
     and gm.group_id = p_group_id
     and gm.active = true;
  if v_holder_uid is null then
    raise exception 'right holder must be an active member of the same group'
      using errcode = '22023';
  end if;

  if p_scope not in ('group', 'resource', 'occurrence') then
    raise exception 'invalid scope %: must be group|resource|occurrence', p_scope
      using errcode = '22023';
  end if;

  if p_target_resource_id is not null then
    select r.group_id into v_target_grp
      from public.resources r
     where r.id = p_target_resource_id;
    if v_target_grp is null then
      raise exception 'target_resource_id not found' using errcode = '22023';
    end if;
    if v_target_grp <> p_group_id then
      raise exception 'target_resource_id belongs to a different group'
        using errcode = '22023';
    end if;
  end if;

  if p_priority < 0 then
    raise exception 'priority must be non-negative' using errcode = '22023';
  end if;

  v_metadata := coalesce(p_extra, '{}'::jsonb) || jsonb_build_object(
    'name',                p_name,
    'holder_member_id',    v_holder,
    'holder_user_id',      v_holder_uid,
    'target_resource_id',  p_target_resource_id,
    'target_capability',   p_target_capability,
    'scope',               p_scope,
    'priority',            p_priority,
    'exclusive',           p_exclusive,
    'transferable',        p_transferable,
    'delegable',           p_delegable,
    'divisible',           p_divisible,
    'expires_at',          p_expires_at,
    'source',              p_source
  );

  insert into public.resources (group_id, resource_type, status, metadata, created_by)
  values (
    p_group_id,
    'right',
    'active',
    v_metadata,
    v_caller_id
  )
  returning id into v_right_id;

  perform public.record_system_event(
    p_group_id,
    'rightCreated',
    v_right_id,
    v_holder,
    jsonb_build_object(
      'name',               p_name,
      'holder_member_id',   v_holder,
      'target_resource_id', p_target_resource_id,
      'target_capability',  p_target_capability,
      'scope',              p_scope,
      'priority',           p_priority,
      'exclusive',          p_exclusive,
      'transferable',       p_transferable,
      'delegable',          p_delegable,
      'divisible',          p_divisible,
      'expires_at',         p_expires_at,
      'source',             p_source,
      'created_by',         v_caller_id,
      'holder_defaulted',   (p_holder_member_id is null)
    )
  );

  return v_right_id;
end;
$$;

comment on function public.create_right(
  uuid, text, uuid, uuid, text, text, int, boolean, boolean, boolean, boolean,
  timestamptz, text, jsonb
) is
  'Create a `right` resource. v2 (mig 00201): p_holder_member_id is now optional — defaults to the caller''s group_members.id when omitted. Explicit-holder callers unchanged. Service_role callers must supply the holder. Emits rightCreated with holder_defaulted=true in payload when the default fired.';

-- build_resource_from_draft: relax holderMemberId requirement so the
-- wizard can submit a right with just `name`. When holderMemberId is
-- omitted or empty in basic_fields, create_right's default takes over
-- and vests the right in the caller.
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
  v_right_name        text;
  v_right_holder      uuid;
  v_right_target      uuid;
  v_right_capability  text;
  v_right_scope       text;
  v_right_priority    int;
  v_right_exclusive   boolean;
  v_right_transfer    boolean;
  v_right_delegable   boolean;
  v_right_divisible   boolean;
  v_right_expires_at  timestamptz;
  v_right_source      text;
  v_right_expires_raw text;
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
      v_rsvp_deadline_raw := nullif(
        trim(coalesce(p_capability_configs->'rsvp'->>'deadline', '')), ''
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
    v_right_name       := p_basic_fields->>'name';
    -- mig 00201: holderMemberId is optional in the wizard's basic_fields.
    -- nullif() handles the absent + empty-string + non-uuid cases by
    -- producing null, then create_right's default vests the right in
    -- the caller.
    v_right_holder     := nullif(p_basic_fields->>'holderMemberId', '')::uuid;
    v_right_target     := nullif(p_basic_fields->>'targetResourceId', '')::uuid;
    v_right_capability := nullif(p_basic_fields->>'targetCapability', '');
    v_right_scope      := coalesce(nullif(p_basic_fields->>'scope', ''), 'resource');
    v_right_priority   := coalesce(nullif(p_basic_fields->>'priority', '')::int, 0);
    v_right_exclusive  := coalesce((p_basic_fields->>'exclusive')::boolean,    false);
    v_right_transfer   := coalesce((p_basic_fields->>'transferable')::boolean, false);
    v_right_delegable  := coalesce((p_basic_fields->>'delegable')::boolean,    false);
    v_right_divisible  := coalesce((p_basic_fields->>'divisible')::boolean,    false);
    v_right_source     := nullif(p_basic_fields->>'source', '');
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
    -- v_right_holder may legitimately be null here (mig 00201). create_right
    -- defaults it to the caller's membership id.
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
  'Atomic ResourceWizard submit. v6 (mig 00201): right branch no longer requires basic_fields.holderMemberId — create_right defaults the holder to the caller when omitted, so the wizard can submit a right with just `name` while the member picker is still pending.';

COMMIT;
