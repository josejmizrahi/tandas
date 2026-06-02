-- d24_p3a_ownership_v2_backend
-- Reconstruido desde supabase_migrations.schema_migrations (live DB wyvkqveienzixinonhum)
-- en R.1 para restaurar la replicabilidad del repo (drift fix: la sesion original
-- aplico esta migration via MCP pero no commiteo el archivo al repo).

-- =====================================================================
-- V3 D.24 PHASE 3A — Ownership 2.0 (backend-only)
--
-- group_resource_owners: copropiedad formal con porcentajes, roles,
-- ventanas temporales y source_decision_id. Append-only (no DELETE);
-- cerrar ownership = set ends_at.
--
-- Conexión a external_parties (PHASE 4) vía external_party_id opcional.
-- Conexión a group_decisions vía source_decision_id opcional.
-- Same-group enforcement vía constraint trigger.
--
-- Backfill: `group_resources.owner_membership_id` → owner_kind='member';
-- resources con ownership_kind='group' sin owner → owner_kind='group'.
--
-- NO actualiza `group_resources.owner_membership_id` (sigue siendo
-- "primary owner" derived). PHASE 3B podrá deprecar la col.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Tabla
-- ---------------------------------------------------------------------

create table if not exists public.group_resource_owners (
    id uuid primary key default gen_random_uuid(),
    group_id uuid not null references public.groups(id) on delete cascade,
    resource_id uuid not null references public.group_resources(id) on delete cascade,
    membership_id uuid references public.group_memberships(id) on delete set null,
    external_party_id uuid references public.group_external_parties(id) on delete set null,
    owner_kind text not null
        check (owner_kind in ('group','member','external_party','other')),
    ownership_pct numeric(6,3)
        check (ownership_pct is null or (ownership_pct >= 0 and ownership_pct <= 100)),
    ownership_role text not null default 'owner'
        check (ownership_role in ('owner','co_owner','custodian','manager','beneficiary','steward','other')),
    starts_at timestamptz not null default now(),
    ends_at timestamptz,
    source_decision_id uuid references public.group_decisions(id),
    metadata jsonb not null default '{}'::jsonb,
    created_at timestamptz not null default now(),
    -- target consistency: member→membership_id, external_party→external_party_id,
    --                     group/other→both null
    constraint group_resource_owners_target_shape check (
        case owner_kind
            when 'member'         then membership_id is not null and external_party_id is null
            when 'external_party' then external_party_id is not null and membership_id is null
            else (membership_id is null and external_party_id is null)
        end
    ),
    constraint group_resource_owners_window_check check (
        ends_at is null or ends_at >= starts_at
    )
);

create index if not exists group_resource_owners_resource_idx
    on public.group_resource_owners(resource_id, ends_at);
create index if not exists group_resource_owners_active_idx
    on public.group_resource_owners(resource_id)
    where ends_at is null;
create index if not exists group_resource_owners_membership_idx
    on public.group_resource_owners(membership_id, ends_at)
    where membership_id is not null;
create index if not exists group_resource_owners_external_party_idx
    on public.group_resource_owners(external_party_id, ends_at)
    where external_party_id is not null;
create index if not exists group_resource_owners_source_decision_idx
    on public.group_resource_owners(source_decision_id)
    where source_decision_id is not null;

-- Same-group enforcement trigger
create or replace function public._assert_resource_owner_same_group()
returns trigger language plpgsql set search_path=public as $$
declare
    v_res_group uuid;
    v_mem_group uuid;
    v_ext_group uuid;
begin
    select group_id into v_res_group from public.group_resources where id = NEW.resource_id;
    if v_res_group is null or v_res_group <> NEW.group_id then
        raise exception 'owner.group_id (%) does not match resource.group_id (%)',
            NEW.group_id, v_res_group using errcode='22023';
    end if;
    if NEW.membership_id is not null then
        select group_id into v_mem_group from public.group_memberships where id = NEW.membership_id;
        if v_mem_group is null or v_mem_group <> NEW.group_id then
            raise exception 'owner.membership.group_id (%) does not match (%)',
                v_mem_group, NEW.group_id using errcode='22023';
        end if;
    end if;
    if NEW.external_party_id is not null then
        select group_id into v_ext_group from public.group_external_parties where id = NEW.external_party_id;
        if v_ext_group is null or v_ext_group <> NEW.group_id then
            raise exception 'owner.external_party.group_id (%) does not match (%)',
                v_ext_group, NEW.group_id using errcode='22023';
        end if;
    end if;
    return NEW;
end$$;

drop trigger if exists trg_resource_owner_same_group on public.group_resource_owners;
create trigger trg_resource_owner_same_group
    before insert or update on public.group_resource_owners
    for each row execute function public._assert_resource_owner_same_group();

-- Append-only DELETE guard
drop trigger if exists trg_resource_owner_no_delete on public.group_resource_owners;
create trigger trg_resource_owner_no_delete
    before delete on public.group_resource_owners
    for each statement execute function public.atom_no_delete_guard();

-- RLS
alter table public.group_resource_owners enable row level security;
drop policy if exists "resource_owners_read" on public.group_resource_owners;
create policy "resource_owners_read" on public.group_resource_owners
    for select to authenticated using (public.is_group_member(group_id));

-- ---------------------------------------------------------------------
-- 2. Permission catalog
-- ---------------------------------------------------------------------

insert into public.permissions (key, description, category) values
    ('resources.manage_ownership', 'Agregar/cerrar owners de recursos', 'resources')
on conflict (key) do nothing;

do $$
declare v_role record;
begin
    for v_role in select id, key from public.group_roles where key in ('founder','admin') loop
        insert into public.group_role_permissions(role_id, permission_key)
        values (v_role.id, 'resources.manage_ownership') on conflict do nothing;
    end loop;
end$$;

-- ---------------------------------------------------------------------
-- 3. Backfill from group_resources.owner_membership_id
-- ---------------------------------------------------------------------

-- 3a. Resources with an explicit owner_membership_id → member owner 100%
insert into public.group_resource_owners (
    group_id, resource_id, membership_id, owner_kind, ownership_pct, ownership_role,
    starts_at, metadata
)
select r.group_id, r.id, r.owner_membership_id, 'member', 100, 'owner',
       coalesce(r.created_at, now()),
       jsonb_build_object('backfill', true)
from public.group_resources r
where r.owner_membership_id is not null
  and not exists (
    select 1 from public.group_resource_owners e
    where e.resource_id = r.id and e.ends_at is null
  );

-- 3b. Resources with ownership_kind='group' and no member owner → group owner
insert into public.group_resource_owners (
    group_id, resource_id, owner_kind, ownership_pct, ownership_role,
    starts_at, metadata
)
select r.group_id, r.id, 'group', 100, 'owner',
       coalesce(r.created_at, now()),
       jsonb_build_object('backfill', true)
from public.group_resources r
where r.ownership_kind = 'group'
  and r.owner_membership_id is null
  and not exists (
    select 1 from public.group_resource_owners e
    where e.resource_id = r.id and e.ends_at is null
  );

-- ---------------------------------------------------------------------
-- 4. Helper: assert sum of active ownership_pct ≤ 100
-- ---------------------------------------------------------------------

create or replace function public._assert_resource_ownership_pct_total(p_resource_id uuid)
returns void language plpgsql security definer set search_path=public as $$
declare v_total numeric;
begin
    select coalesce(sum(ownership_pct), 0) into v_total
    from public.group_resource_owners
    where resource_id = p_resource_id and ends_at is null;
    if v_total > 100 then
        raise exception 'ownership_pct_total_exceeds_100: %', v_total using errcode='22023';
    end if;
end$$;

-- ---------------------------------------------------------------------
-- 5. RPCs
-- ---------------------------------------------------------------------

create or replace function public.add_resource_owner(
    p_resource_id uuid,
    p_owner_kind text,
    p_membership_id uuid default null,
    p_external_party_id uuid default null,
    p_ownership_pct numeric default null,
    p_ownership_role text default 'owner',
    p_starts_at timestamptz default null,
    p_source_decision_id uuid default null,
    p_metadata jsonb default '{}'::jsonb
) returns uuid
language plpgsql security definer set search_path=public, pg_catalog as $$
declare
    v_uid uuid := (select auth.uid());
    v_resource public.group_resources%ROWTYPE;
    v_id uuid;
begin
    if v_uid is null then raise exception 'auth_required' using errcode='42501'; end if;
    select * into v_resource from public.group_resources where id=p_resource_id;
    if v_resource.id is null then raise exception 'resource_not_found' using errcode='42704'; end if;
    if not public.is_group_member(v_resource.group_id) then raise exception 'not_a_member' using errcode='42501'; end if;
    if not public.has_group_permission(v_resource.group_id, 'resources.manage_ownership') then
        raise exception 'missing_permission: resources.manage_ownership' using errcode='42501';
    end if;
    if p_owner_kind not in ('group','member','external_party','other') then
        raise exception 'invalid_owner_kind: %', p_owner_kind using errcode='22023';
    end if;
    if p_ownership_role is not null and p_ownership_role not in
        ('owner','co_owner','custodian','manager','beneficiary','steward','other') then
        raise exception 'invalid_ownership_role: %', p_ownership_role using errcode='22023';
    end if;
    if p_owner_kind='member' and p_membership_id is null then
        raise exception 'membership_id_required_for_member_owner' using errcode='22023';
    end if;
    if p_owner_kind='external_party' and p_external_party_id is null then
        raise exception 'external_party_id_required' using errcode='22023';
    end if;

    insert into public.group_resource_owners (
        group_id, resource_id,
        membership_id, external_party_id,
        owner_kind, ownership_pct, ownership_role,
        starts_at, source_decision_id, metadata
    ) values (
        v_resource.group_id, p_resource_id,
        case when p_owner_kind='member' then p_membership_id else null end,
        case when p_owner_kind='external_party' then p_external_party_id else null end,
        p_owner_kind, p_ownership_pct, coalesce(p_ownership_role,'owner'),
        coalesce(p_starts_at, now()),
        p_source_decision_id, coalesce(p_metadata,'{}'::jsonb)
    ) returning id into v_id;

    -- Enforce pct total ≤ 100 (deferred check, raise to undo this insert)
    perform public._assert_resource_ownership_pct_total(p_resource_id);

    perform public.record_system_event(
        v_resource.group_id, 'resource.owner_added', 'resource', p_resource_id, v_resource.name,
        jsonb_build_object(
            'owner_id', v_id, 'owner_kind', p_owner_kind,
            'membership_id', p_membership_id, 'external_party_id', p_external_party_id,
            'ownership_pct', p_ownership_pct, 'ownership_role', p_ownership_role,
            'source_decision_id', p_source_decision_id));

    return v_id;
end$$;

create or replace function public.end_resource_owner(
    p_owner_id uuid,
    p_reason text default null,
    p_ends_at timestamptz default null
) returns void
language plpgsql security definer set search_path=public, pg_catalog as $$
declare
    v_uid uuid := (select auth.uid());
    v_o public.group_resource_owners%ROWTYPE;
    v_resource public.group_resources%ROWTYPE;
begin
    if v_uid is null then raise exception 'auth_required' using errcode='42501'; end if;
    select * into v_o from public.group_resource_owners where id=p_owner_id for update;
    if v_o.id is null then raise exception 'owner_not_found' using errcode='42704'; end if;
    if not public.is_group_member(v_o.group_id) then raise exception 'not_a_member' using errcode='42501'; end if;
    if not public.has_group_permission(v_o.group_id, 'resources.manage_ownership') then
        raise exception 'missing_permission: resources.manage_ownership' using errcode='42501';
    end if;
    if v_o.ends_at is not null then return; end if;  -- idempotent

    update public.group_resource_owners
       set ends_at = coalesce(p_ends_at, now()),
           metadata = metadata || jsonb_strip_nulls(jsonb_build_object('end_reason', p_reason))
     where id = p_owner_id;

    select * into v_resource from public.group_resources where id = v_o.resource_id;
    perform public.record_system_event(
        v_o.group_id, 'resource.owner_removed', 'resource', v_o.resource_id, v_resource.name,
        jsonb_build_object('owner_id', p_owner_id, 'owner_kind', v_o.owner_kind,
            'membership_id', v_o.membership_id, 'external_party_id', v_o.external_party_id,
            'reason', p_reason));
end$$;

create or replace function public.list_resource_owners(
    p_resource_id uuid, p_include_ended boolean default false
) returns table(
    id uuid, group_id uuid, resource_id uuid,
    membership_id uuid, external_party_id uuid,
    owner_kind text, ownership_pct numeric, ownership_role text,
    starts_at timestamptz, ends_at timestamptz,
    source_decision_id uuid, metadata jsonb, created_at timestamptz,
    actor_display_name text
) language sql stable security definer set search_path=public as $$
    select o.id, o.group_id, o.resource_id,
           o.membership_id, o.external_party_id,
           o.owner_kind, o.ownership_pct, o.ownership_role,
           o.starts_at, o.ends_at, o.source_decision_id, o.metadata, o.created_at,
           coalesce(p.display_name, p.username, ep.display_name) as actor_display_name
    from public.group_resource_owners o
    left join public.group_memberships gm on gm.id = o.membership_id
    left join public.profiles p on p.id = gm.user_id
    left join public.group_external_parties ep on ep.id = o.external_party_id
    where o.resource_id = p_resource_id
      and public.is_group_member(o.group_id)
      and (p_include_ended or o.ends_at is null)
    order by o.starts_at desc, o.created_at desc;
$$;

grant execute on function public.add_resource_owner(uuid, text, uuid, uuid, numeric, text, timestamptz, uuid, jsonb) to authenticated;
grant execute on function public.end_resource_owner(uuid, text, timestamptz) to authenticated;
grant execute on function public.list_resource_owners(uuid, boolean) to authenticated;
