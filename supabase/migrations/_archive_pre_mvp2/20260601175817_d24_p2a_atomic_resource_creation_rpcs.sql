-- d24_p2a_atomic_resource_creation_rpcs
-- Reconstruido desde supabase_migrations.schema_migrations (live DB wyvkqveienzixinonhum)
-- en R.1 para restaurar la replicabilidad del repo (drift fix: la sesion original
-- aplico esta migration via MCP pero no commiteo el archivo al repo).

-- =====================================================================
-- V3 D.24 PHASE 2A — Atomic Resource Creation RPCs
--
-- Cierra el gap envelope→subtype: hoy puedes crear `group_resources` con
-- resource_type='event' SIN su subtype row correspondiente. Las 6 RPCs
-- nuevas garantizan que envelope + subtype se creen atómicamente.
--
-- NO bloquea inserts directos (eso es PHASE 2B). Solo añade el camino
-- correcto.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. group_resources gains client_id for idempotency
-- ---------------------------------------------------------------------

alter table public.group_resources
    add column if not exists client_id text;

create unique index if not exists group_resources_client_id_uq
    on public.group_resources(group_id, client_id)
    where client_id is not null;

-- ---------------------------------------------------------------------
-- 2. Extend create_group_resource with p_metadata + p_client_id
--    (additive — existing callers don't pass them; PostgREST resolves
--     by named params so old iOS calls keep working.)
-- ---------------------------------------------------------------------

create or replace function public.create_group_resource(
    p_group_id uuid,
    p_resource_type text,
    p_name text,
    p_description text default null,
    p_visibility text default 'members',
    p_ownership_kind text default 'group',
    p_owner_membership_id uuid default null,
    p_custodian_membership_id uuid default null,
    p_metadata jsonb default '{}'::jsonb,
    p_client_id text default null
) returns public.group_resources
language plpgsql security definer set search_path='public','pg_catalog' as $$
DECLARE
    v_uid uuid := auth.uid();
    v_type text;
    v_name text;
    v_description text;
    v_visibility text;
    v_ownership text;
    v_metadata jsonb := coalesce(p_metadata, '{}'::jsonb);
    v_existing public.group_resources;
    v_row public.group_resources;
BEGIN
    IF v_uid IS NULL THEN RAISE EXCEPTION 'must be authenticated' USING errcode = '42501'; END IF;
    v_type := COALESCE(NULLIF(btrim(coalesce(p_resource_type, '')), ''), '');
    IF v_type NOT IN (
        'event','fund','slot','space','asset','right','money','time','points',
        'document','data','access','other','vehicle','tool','inventory','real_estate','intellectual_property'
    ) THEN RAISE EXCEPTION 'invalid resource type' USING errcode = '22023'; END IF;
    v_name := NULLIF(btrim(coalesce(p_name, '')), '');
    IF v_name IS NULL THEN RAISE EXCEPTION 'resource name required' USING errcode = '22023'; END IF;
    v_description := NULLIF(btrim(coalesce(p_description, '')), '');
    v_visibility := COALESCE(NULLIF(btrim(coalesce(p_visibility, '')), ''), 'members');
    IF v_visibility NOT IN ('private','members','public') THEN
        RAISE EXCEPTION 'invalid resource visibility' USING errcode = '22023'; END IF;
    v_ownership := COALESCE(NULLIF(btrim(coalesce(p_ownership_kind, '')), ''), 'group');
    IF v_ownership NOT IN ('group','individual','shared','custodial','external') THEN
        RAISE EXCEPTION 'invalid ownership kind' USING errcode = '22023'; END IF;
    IF p_owner_membership_id IS NOT NULL THEN
        IF NOT EXISTS (SELECT 1 FROM public.group_memberships WHERE id = p_owner_membership_id AND group_id = p_group_id) THEN
            RAISE EXCEPTION 'owner membership not in group %', p_group_id USING errcode = '22023'; END IF;
    END IF;
    IF p_custodian_membership_id IS NOT NULL THEN
        IF NOT EXISTS (SELECT 1 FROM public.group_memberships WHERE id = p_custodian_membership_id AND group_id = p_group_id) THEN
            RAISE EXCEPTION 'custodian membership not in group %', p_group_id USING errcode = '22023'; END IF;
        v_metadata := v_metadata || jsonb_build_object(
            'foundation_custodian_membership_id', p_custodian_membership_id::text);
    END IF;

    PERFORM public.assert_permission(p_group_id, 'resources.create');

    -- Idempotency on (group_id, client_id)
    IF p_client_id IS NOT NULL THEN
        SELECT * INTO v_existing FROM public.group_resources
        WHERE group_id = p_group_id AND client_id = p_client_id;
        IF v_existing.id IS NOT NULL THEN RETURN v_existing; END IF;
    END IF;

    INSERT INTO public.group_resources (
        group_id, resource_type, name, description, status, visibility,
        ownership_kind, owner_membership_id, metadata, created_by, client_id
    ) VALUES (
        p_group_id, v_type, v_name, v_description, 'active', v_visibility,
        v_ownership, p_owner_membership_id, v_metadata, v_uid, p_client_id
    )
    RETURNING * INTO v_row;

    PERFORM public.record_system_event(
        p_group_id, 'resource.created', 'resource', v_row.id, v_name,
        jsonb_build_object('resource_type', v_type, 'visibility', v_visibility, 'ownership_kind', v_ownership));

    RETURN v_row;
END;
$$;

grant execute on function public.create_group_resource(uuid, text, text, text, text, text, uuid, uuid, jsonb, text) to authenticated;

-- ---------------------------------------------------------------------
-- 3. Six atomic wrappers
-- ---------------------------------------------------------------------

-- 3.1 create_event_resource
create or replace function public.create_event_resource(
    p_group_id uuid,
    p_name text,
    p_starts_at timestamptz,
    p_description text default null,
    p_ends_at timestamptz default null,
    p_location text default null,
    p_capacity integer default null,
    p_host_membership_id uuid default null,
    p_visibility text default 'members',
    p_metadata jsonb default '{}'::jsonb,
    p_client_id text default null
) returns uuid
language plpgsql security definer set search_path=public, pg_catalog as $$
declare
    v_resource public.group_resources;
begin
    if p_starts_at is null then raise exception 'starts_at_required' using errcode='22023'; end if;
    if p_ends_at is not null and p_ends_at < p_starts_at then
        raise exception 'ends_before_starts' using errcode='22023'; end if;

    v_resource := public.create_group_resource(
        p_group_id, 'event', p_name, p_description, p_visibility,
        'group', null, null, coalesce(p_metadata,'{}'::jsonb), p_client_id);

    -- Insert subtype only if not already there (idempotent retry-safe)
    insert into public.group_resource_events (
        resource_id, starts_at, ends_at, location, capacity, host_membership_id
    ) values (
        v_resource.id, p_starts_at, p_ends_at, p_location, p_capacity, p_host_membership_id
    ) on conflict (resource_id) do nothing;

    return v_resource.id;
end$$;

-- 3.2 create_asset_resource
create or replace function public.create_asset_resource(
    p_group_id uuid,
    p_name text,
    p_asset_kind text,
    p_description text default null,
    p_serial_number text default null,
    p_current_value numeric default null,
    p_current_value_unit text default null,
    p_condition text default null,
    p_custodian_membership_id uuid default null,
    p_owner_membership_id uuid default null,
    p_ownership_kind text default 'group',
    p_visibility text default 'members',
    p_metadata jsonb default '{}'::jsonb,
    p_client_id text default null
) returns uuid
language plpgsql security definer set search_path=public, pg_catalog as $$
declare
    v_resource public.group_resources;
begin
    if nullif(btrim(coalesce(p_asset_kind,'')),'') is null then
        raise exception 'asset_kind_required' using errcode='22023'; end if;

    v_resource := public.create_group_resource(
        p_group_id, 'asset', p_name, p_description, p_visibility,
        p_ownership_kind, p_owner_membership_id, p_custodian_membership_id,
        coalesce(p_metadata,'{}'::jsonb), p_client_id);

    insert into public.group_resource_assets (
        resource_id, asset_kind, serial_number,
        current_value, current_value_unit, condition, custodian_membership_id
    ) values (
        v_resource.id, p_asset_kind, p_serial_number,
        p_current_value, p_current_value_unit, p_condition, p_custodian_membership_id
    ) on conflict (resource_id) do nothing;

    return v_resource.id;
end$$;

-- 3.3 create_fund_resource
create or replace function public.create_fund_resource(
    p_group_id uuid,
    p_name text,
    p_fund_kind text,
    p_currency text default 'MXN',
    p_description text default null,
    p_is_shared_pool boolean default false,
    p_is_in_kind boolean default false,
    p_threshold_target numeric default null,
    p_visibility text default 'members',
    p_metadata jsonb default '{}'::jsonb,
    p_client_id text default null
) returns uuid
language plpgsql security definer set search_path=public, pg_catalog as $$
declare
    v_resource public.group_resources;
begin
    if nullif(btrim(coalesce(p_fund_kind,'')),'') is null then
        raise exception 'fund_kind_required' using errcode='22023'; end if;

    v_resource := public.create_group_resource(
        p_group_id, 'fund', p_name, p_description, p_visibility,
        'group', null, null, coalesce(p_metadata,'{}'::jsonb), p_client_id);

    insert into public.group_resource_funds (
        resource_id, fund_kind, currency, is_shared_pool, is_in_kind, threshold_target
    ) values (
        v_resource.id, p_fund_kind, coalesce(p_currency,'MXN'),
        coalesce(p_is_shared_pool,false), coalesce(p_is_in_kind,false), p_threshold_target
    ) on conflict (resource_id) do nothing;

    return v_resource.id;
end$$;

-- 3.4 create_space_resource
create or replace function public.create_space_resource(
    p_group_id uuid,
    p_name text,
    p_address text default null,
    p_description text default null,
    p_capacity integer default null,
    p_rules text default null,
    p_visibility text default 'members',
    p_metadata jsonb default '{}'::jsonb,
    p_client_id text default null
) returns uuid
language plpgsql security definer set search_path=public, pg_catalog as $$
declare
    v_resource public.group_resources;
begin
    v_resource := public.create_group_resource(
        p_group_id, 'space', p_name, p_description, p_visibility,
        'group', null, null, coalesce(p_metadata,'{}'::jsonb), p_client_id);

    insert into public.group_resource_spaces (
        resource_id, address, capacity, rules
    ) values (
        v_resource.id, p_address, p_capacity, p_rules
    ) on conflict (resource_id) do nothing;

    return v_resource.id;
end$$;

-- 3.5 create_slot_resource
create or replace function public.create_slot_resource(
    p_group_id uuid,
    p_name text,
    p_slot_starts_at timestamptz,
    p_slot_ends_at timestamptz,
    p_description text default null,
    p_assigned_membership_id uuid default null,
    p_visibility text default 'members',
    p_metadata jsonb default '{}'::jsonb,
    p_client_id text default null
) returns uuid
language plpgsql security definer set search_path=public, pg_catalog as $$
declare
    v_resource public.group_resources;
begin
    if p_slot_starts_at is null or p_slot_ends_at is null then
        raise exception 'slot_window_required' using errcode='22023'; end if;
    if p_slot_ends_at < p_slot_starts_at then
        raise exception 'slot_ends_before_starts' using errcode='22023'; end if;

    v_resource := public.create_group_resource(
        p_group_id, 'slot', p_name, p_description, p_visibility,
        case when p_assigned_membership_id is not null then 'individual' else 'group' end,
        p_assigned_membership_id, null,
        coalesce(p_metadata,'{}'::jsonb), p_client_id);

    insert into public.group_resource_slots (
        resource_id, slot_starts_at, slot_ends_at, assigned_membership_id
    ) values (
        v_resource.id, p_slot_starts_at, p_slot_ends_at, p_assigned_membership_id
    ) on conflict (resource_id) do nothing;

    return v_resource.id;
end$$;

-- 3.6 create_right_resource
create or replace function public.create_right_resource(
    p_group_id uuid,
    p_name text,
    p_right_kind text,
    p_holder_membership_id uuid,
    p_description text default null,
    p_expires_at timestamptz default null,
    p_transferable boolean default false,
    p_conditions text default null,
    p_visibility text default 'members',
    p_metadata jsonb default '{}'::jsonb,
    p_client_id text default null
) returns uuid
language plpgsql security definer set search_path=public, pg_catalog as $$
declare
    v_resource public.group_resources;
begin
    if nullif(btrim(coalesce(p_right_kind,'')),'') is null then
        raise exception 'right_kind_required' using errcode='22023'; end if;
    if p_holder_membership_id is null then
        raise exception 'holder_membership_required' using errcode='22023'; end if;
    if not exists (select 1 from public.group_memberships
        where id=p_holder_membership_id and group_id=p_group_id) then
        raise exception 'holder_not_in_group' using errcode='22023'; end if;

    v_resource := public.create_group_resource(
        p_group_id, 'right', p_name, p_description, p_visibility,
        'individual', p_holder_membership_id, null,
        coalesce(p_metadata,'{}'::jsonb), p_client_id);

    insert into public.group_resource_rights (
        resource_id, right_kind, holder_membership_id,
        granted_at, expires_at, transferable, conditions
    ) values (
        v_resource.id, p_right_kind, p_holder_membership_id,
        now(), p_expires_at, coalesce(p_transferable,false), p_conditions
    ) on conflict (resource_id) do nothing;

    return v_resource.id;
end$$;

grant execute on function public.create_event_resource(uuid, text, timestamptz, text, timestamptz, text, integer, uuid, text, jsonb, text) to authenticated;
grant execute on function public.create_asset_resource(uuid, text, text, text, text, numeric, text, text, uuid, uuid, text, text, jsonb, text) to authenticated;
grant execute on function public.create_fund_resource(uuid, text, text, text, text, boolean, boolean, numeric, text, jsonb, text) to authenticated;
grant execute on function public.create_space_resource(uuid, text, text, text, integer, text, text, jsonb, text) to authenticated;
grant execute on function public.create_slot_resource(uuid, text, timestamptz, timestamptz, text, uuid, text, jsonb, text) to authenticated;
grant execute on function public.create_right_resource(uuid, text, text, uuid, text, timestamptz, boolean, text, text, jsonb, text) to authenticated;
