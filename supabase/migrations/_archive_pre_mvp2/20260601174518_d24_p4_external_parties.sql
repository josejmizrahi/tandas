-- d24_p4_external_parties
-- Reconstruido desde supabase_migrations.schema_migrations (live DB wyvkqveienzixinonhum)
-- en R.1 para restaurar la replicabilidad del repo (drift fix: la sesion original
-- aplico esta migration via MCP pero no commiteo el archivo al repo).

-- =====================================================================
-- V3 D.24 PHASE 4 — External Parties
--
-- Standalone entity for non-member actors that the group interacts with:
-- vendors, venues, landlords, coaches, mediators, guests, etc.
--
-- Scope per founder spec:
--   - Tabla group_external_parties (standalone, NO FK obligatorias yet)
--   - party_type whitelist: person/organization/vendor/venue/landlord/coach/
--                          mediator/guest/client/other
--   - 4 RPCs: create / update / archive / list
--   - Eventos: external_party.{created,updated,archived}
--   - Idempotency en create via p_client_id
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Tabla
-- ---------------------------------------------------------------------

create table if not exists public.group_external_parties (
    id uuid primary key default gen_random_uuid(),
    group_id uuid not null references public.groups(id) on delete cascade,
    party_type text not null default 'person'
        check (party_type in (
            'person','organization','vendor','venue','landlord',
            'coach','mediator','guest','client','other'
        )),
    display_name text not null check (length(btrim(display_name)) > 0),
    email text,
    phone text,
    notes text,
    status text not null default 'active'
        check (status in ('active','archived','blacklisted')),
    metadata jsonb not null default '{}'::jsonb,
    client_id text,
    created_by uuid references auth.users(id),
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    archived_at timestamptz
);

create unique index if not exists group_external_parties_client_id_uq
    on public.group_external_parties(group_id, client_id)
    where client_id is not null;
create index if not exists group_external_parties_group_idx
    on public.group_external_parties(group_id, created_at desc);
create index if not exists group_external_parties_status_idx
    on public.group_external_parties(group_id, status)
    where status <> 'archived';
create index if not exists group_external_parties_type_idx
    on public.group_external_parties(group_id, party_type)
    where status='active';

create or replace function public._touch_external_party_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end;
$$;
drop trigger if exists trg_external_party_touch on public.group_external_parties;
create trigger trg_external_party_touch
    before update on public.group_external_parties
    for each row execute function public._touch_external_party_updated_at();

-- ---------------------------------------------------------------------
-- 2. RLS
-- ---------------------------------------------------------------------

alter table public.group_external_parties enable row level security;

drop policy if exists "external_parties_read" on public.group_external_parties;
create policy "external_parties_read" on public.group_external_parties
    for select to authenticated using (public.is_group_member(group_id));

-- Writes only via SECURITY DEFINER RPCs.

-- ---------------------------------------------------------------------
-- 3. Permissions catalog + per-group role seeding
-- ---------------------------------------------------------------------

insert into public.permissions (key, description, category) values
    ('external_parties.read',   'Leer external parties del grupo',  'external_parties'),
    ('external_parties.manage', 'Crear/editar/archivar external parties', 'external_parties')
on conflict (key) do nothing;

-- Seed: founder + admin tienen manage; todos los miembros tienen read.
do $$
declare
    v_role record;
begin
    for v_role in
        select id, key from public.group_roles where key in ('founder','admin','member')
    loop
        insert into public.group_role_permissions(role_id, permission_key)
        values (v_role.id, 'external_parties.read')
        on conflict do nothing;

        if v_role.key in ('founder','admin') then
            insert into public.group_role_permissions(role_id, permission_key)
            values (v_role.id, 'external_parties.manage')
            on conflict do nothing;
        end if;
    end loop;
end$$;

-- ---------------------------------------------------------------------
-- 4. RPCs
-- ---------------------------------------------------------------------

-- 4.1 create_external_party
create or replace function public.create_external_party(
    p_group_id uuid,
    p_display_name text,
    p_party_type text default 'person',
    p_email text default null,
    p_phone text default null,
    p_notes text default null,
    p_metadata jsonb default '{}'::jsonb,
    p_client_id text default null
) returns uuid
language plpgsql security definer set search_path=public, pg_catalog as $$
declare
    v_uid uuid := (select auth.uid());
    v_id uuid;
    v_existing uuid;
    v_name text;
    v_type text;
begin
    if v_uid is null then raise exception 'auth_required' using errcode='42501'; end if;
    if not public.is_group_member(p_group_id) then
        raise exception 'not_a_member' using errcode='42501';
    end if;
    if not public.has_group_permission(p_group_id, 'external_parties.manage') then
        raise exception 'missing_permission: external_parties.manage' using errcode='42501';
    end if;

    v_name := nullif(btrim(coalesce(p_display_name,'')),'');
    if v_name is null then raise exception 'display_name_required' using errcode='22023'; end if;

    v_type := coalesce(p_party_type,'person');
    if v_type not in ('person','organization','vendor','venue','landlord',
                      'coach','mediator','guest','client','other') then
        raise exception 'invalid_party_type: %', v_type using errcode='22023';
    end if;

    -- Idempotency by (group_id, client_id)
    if p_client_id is not null then
        select id into v_existing from public.group_external_parties
        where group_id=p_group_id and client_id=p_client_id;
        if v_existing is not null then return v_existing; end if;
    end if;

    insert into public.group_external_parties (
        group_id, party_type, display_name, email, phone, notes,
        status, metadata, client_id, created_by
    ) values (
        p_group_id, v_type, v_name,
        nullif(btrim(coalesce(p_email,'')),''),
        nullif(btrim(coalesce(p_phone,'')),''),
        nullif(btrim(coalesce(p_notes,'')),''),
        'active',
        coalesce(p_metadata,'{}'::jsonb),
        p_client_id, v_uid
    ) returning id into v_id;

    perform public.record_system_event(
        p_group_id, 'external_party.created', 'external_party', v_id, v_name,
        jsonb_build_object('party_type', v_type, 'has_email', p_email is not null,
            'has_phone', p_phone is not null));
    return v_id;
end$$;

-- 4.2 update_external_party
create or replace function public.update_external_party(
    p_party_id uuid,
    p_display_name text default null,
    p_party_type text default null,
    p_email text default null,
    p_phone text default null,
    p_notes text default null,
    p_metadata jsonb default null
) returns void
language plpgsql security definer set search_path=public, pg_catalog as $$
declare
    v_uid uuid := (select auth.uid());
    v_party public.group_external_parties%ROWTYPE;
    v_new_name text;
begin
    if v_uid is null then raise exception 'auth_required' using errcode='42501'; end if;
    select * into v_party from public.group_external_parties where id=p_party_id for update;
    if v_party.id is null then raise exception 'external_party_not_found' using errcode='42704'; end if;
    if not public.is_group_member(v_party.group_id) then raise exception 'not_a_member' using errcode='42501'; end if;
    if not public.has_group_permission(v_party.group_id, 'external_parties.manage') then
        raise exception 'missing_permission: external_parties.manage' using errcode='42501';
    end if;
    if v_party.status = 'archived' then
        raise exception 'cannot_update_archived' using errcode='22023';
    end if;
    if p_party_type is not null and p_party_type not in (
        'person','organization','vendor','venue','landlord','coach','mediator','guest','client','other'
    ) then raise exception 'invalid_party_type: %', p_party_type using errcode='22023'; end if;
    v_new_name := nullif(btrim(coalesce(p_display_name,'')),'');

    update public.group_external_parties
    set display_name = coalesce(v_new_name, display_name),
        party_type   = coalesce(p_party_type, party_type),
        email        = case when p_email is null then email
                            else nullif(btrim(p_email),'') end,
        phone        = case when p_phone is null then phone
                            else nullif(btrim(p_phone),'') end,
        notes        = case when p_notes is null then notes
                            else nullif(btrim(p_notes),'') end,
        metadata     = case when p_metadata is null then metadata else metadata || p_metadata end
    where id = p_party_id;

    perform public.record_system_event(
        v_party.group_id, 'external_party.updated', 'external_party', p_party_id,
        coalesce(v_new_name, v_party.display_name),
        jsonb_strip_nulls(jsonb_build_object(
            'party_type_changed', p_party_type is not null,
            'name_changed', v_new_name is not null,
            'metadata_patched', p_metadata is not null)));
end$$;

-- 4.3 archive_external_party
create or replace function public.archive_external_party(p_party_id uuid)
returns void
language plpgsql security definer set search_path=public, pg_catalog as $$
declare
    v_uid uuid := (select auth.uid());
    v_party public.group_external_parties%ROWTYPE;
begin
    if v_uid is null then raise exception 'auth_required' using errcode='42501'; end if;
    select * into v_party from public.group_external_parties where id=p_party_id for update;
    if v_party.id is null then raise exception 'external_party_not_found' using errcode='42704'; end if;
    if not public.is_group_member(v_party.group_id) then raise exception 'not_a_member' using errcode='42501'; end if;
    if not public.has_group_permission(v_party.group_id, 'external_parties.manage') then
        raise exception 'missing_permission: external_parties.manage' using errcode='42501';
    end if;
    if v_party.status='archived' then return; end if;

    update public.group_external_parties
    set status='archived', archived_at=now()
    where id=p_party_id;

    perform public.record_system_event(
        v_party.group_id, 'external_party.archived', 'external_party', p_party_id,
        v_party.display_name, '{}'::jsonb);
end$$;

-- 4.4 list_external_parties
create or replace function public.list_external_parties(
    p_group_id uuid,
    p_include_archived boolean default false,
    p_party_type text default null
) returns table(
    id uuid, group_id uuid, party_type text, display_name text,
    email text, phone text, notes text, status text, metadata jsonb,
    created_by uuid, created_at timestamptz, updated_at timestamptz, archived_at timestamptz
) language sql stable security definer set search_path=public as $$
    select e.id, e.group_id, e.party_type, e.display_name,
           e.email, e.phone, e.notes, e.status, e.metadata,
           e.created_by, e.created_at, e.updated_at, e.archived_at
    from public.group_external_parties e
    where e.group_id = p_group_id
      and public.is_group_member(p_group_id)
      and (p_include_archived or e.status <> 'archived')
      and (p_party_type is null or e.party_type = p_party_type)
    order by e.status asc, e.display_name asc;
$$;

-- ---------------------------------------------------------------------
-- 5. Grants
-- ---------------------------------------------------------------------

grant execute on function public.create_external_party(uuid, text, text, text, text, text, jsonb, text) to authenticated;
grant execute on function public.update_external_party(uuid, text, text, text, text, text, jsonb) to authenticated;
grant execute on function public.archive_external_party(uuid) to authenticated;
grant execute on function public.list_external_parties(uuid, boolean, text) to authenticated;
