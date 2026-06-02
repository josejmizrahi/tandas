-- d24_p9_role_mandate_audit_events
-- Reconstruido desde supabase_migrations.schema_migrations (live DB wyvkqveienzixinonhum)
-- en R.1 para restaurar la replicabilidad del repo (drift fix: la sesion original
-- aplico esta migration via MCP pero no commiteo el archivo al repo).

-- V3 D.24 PHASE 9 — Role / Mandate Audit Events (retry with correct col name)

create or replace function public.atom_no_update_guard()
returns trigger language plpgsql set search_path to 'public' as $$
begin raise exception 'append-only table %.%: update is not allowed',
        TG_TABLE_SCHEMA, TG_TABLE_NAME; end;
$$;

create table if not exists public.group_role_assignment_events (
    id uuid primary key default gen_random_uuid(),
    group_id uuid not null references public.groups(id) on delete cascade,
    membership_id uuid not null references public.group_memberships(id) on delete cascade,
    role_id uuid not null references public.group_roles(id) on delete cascade,
    event_type text not null check (event_type in ('assigned','removed')),
    actor_user_id uuid references auth.users(id),
    source_decision_id uuid references public.group_decisions(id),
    reason text,
    metadata jsonb not null default '{}'::jsonb,
    created_at timestamptz not null default now()
);
create index if not exists group_role_assignment_events_group_idx
    on public.group_role_assignment_events(group_id, created_at desc);
create index if not exists group_role_assignment_events_membership_idx
    on public.group_role_assignment_events(membership_id, created_at desc);
create index if not exists group_role_assignment_events_role_idx
    on public.group_role_assignment_events(role_id, created_at desc);
create index if not exists group_role_assignment_events_source_decision_idx
    on public.group_role_assignment_events(source_decision_id)
    where source_decision_id is not null;

create or replace function public._assert_role_event_same_group()
returns trigger language plpgsql set search_path to 'public' as $$
declare v_mem_group uuid; v_role_group uuid;
begin
    select group_id into v_mem_group from public.group_memberships where id = NEW.membership_id;
    select group_id into v_role_group from public.group_roles where id = NEW.role_id;
    if v_mem_group is null or v_mem_group <> NEW.group_id then
        raise exception 'role_event membership group mismatch' using errcode='22023';
    end if;
    if v_role_group is null or v_role_group <> NEW.group_id then
        raise exception 'role_event role group mismatch' using errcode='22023';
    end if;
    return NEW;
end$$;

drop trigger if exists trg_role_event_same_group on public.group_role_assignment_events;
create trigger trg_role_event_same_group before insert on public.group_role_assignment_events
    for each row execute function public._assert_role_event_same_group();
drop trigger if exists trg_role_event_no_delete on public.group_role_assignment_events;
create trigger trg_role_event_no_delete before delete on public.group_role_assignment_events
    for each statement execute function public.atom_no_delete_guard();
drop trigger if exists trg_role_event_no_update on public.group_role_assignment_events;
create trigger trg_role_event_no_update before update on public.group_role_assignment_events
    for each statement execute function public.atom_no_update_guard();

alter table public.group_role_assignment_events enable row level security;
drop policy if exists "role_events_read" on public.group_role_assignment_events;
create policy "role_events_read" on public.group_role_assignment_events
    for select to authenticated using (public.is_group_member(group_id));

create table if not exists public.group_mandate_events (
    id uuid primary key default gen_random_uuid(),
    group_id uuid not null references public.groups(id) on delete cascade,
    mandate_id uuid not null references public.group_mandates(id) on delete cascade,
    event_type text not null check (event_type in ('granted','revoked','expired','updated')),
    actor_user_id uuid references auth.users(id),
    source_decision_id uuid references public.group_decisions(id),
    reason text,
    metadata jsonb not null default '{}'::jsonb,
    created_at timestamptz not null default now()
);
create index if not exists group_mandate_events_group_idx
    on public.group_mandate_events(group_id, created_at desc);
create index if not exists group_mandate_events_mandate_idx
    on public.group_mandate_events(mandate_id, created_at desc);
create index if not exists group_mandate_events_source_decision_idx
    on public.group_mandate_events(source_decision_id)
    where source_decision_id is not null;

create or replace function public._assert_mandate_event_same_group()
returns trigger language plpgsql set search_path to 'public' as $$
declare v_m_group uuid;
begin
    select group_id into v_m_group from public.group_mandates where id = NEW.mandate_id;
    if v_m_group is null or v_m_group <> NEW.group_id then
        raise exception 'mandate_event group mismatch' using errcode='22023';
    end if;
    return NEW;
end$$;

drop trigger if exists trg_mandate_event_same_group on public.group_mandate_events;
create trigger trg_mandate_event_same_group before insert on public.group_mandate_events
    for each row execute function public._assert_mandate_event_same_group();
drop trigger if exists trg_mandate_event_no_delete on public.group_mandate_events;
create trigger trg_mandate_event_no_delete before delete on public.group_mandate_events
    for each statement execute function public.atom_no_delete_guard();
drop trigger if exists trg_mandate_event_no_update on public.group_mandate_events;
create trigger trg_mandate_event_no_update before update on public.group_mandate_events
    for each statement execute function public.atom_no_update_guard();

alter table public.group_mandate_events enable row level security;
drop policy if exists "mandate_events_read" on public.group_mandate_events;
create policy "mandate_events_read" on public.group_mandate_events
    for select to authenticated using (public.is_group_member(group_id));

-- Helpers
create or replace function public._record_role_event(
    p_group_id uuid, p_membership_id uuid, p_role_id uuid,
    p_event_type text, p_source_decision_id uuid default null,
    p_reason text default null, p_metadata jsonb default '{}'::jsonb
) returns uuid language plpgsql security definer set search_path=public as $$
declare v_id uuid; v_full jsonb;
begin
    insert into public.group_role_assignment_events (
        group_id, membership_id, role_id, event_type, actor_user_id,
        source_decision_id, reason, metadata
    ) values (
        p_group_id, p_membership_id, p_role_id, p_event_type, (select auth.uid()),
        p_source_decision_id, p_reason, coalesce(p_metadata,'{}'::jsonb)
    ) returning id into v_id;
    v_full := coalesce(p_metadata,'{}'::jsonb) || jsonb_build_object(
        'role_id', p_role_id, 'membership_id', p_membership_id,
        'audit_event_id', v_id, 'source_decision_id', p_source_decision_id, 'reason', p_reason);
    perform public.record_system_event(
        p_group_id,
        case p_event_type when 'assigned' then 'role.assigned' else 'role.removed' end,
        'membership', p_membership_id,
        case p_event_type when 'assigned' then 'Rol asignado' else 'Rol removido' end,
        v_full);
    return v_id;
end$$;

create or replace function public._record_mandate_event(
    p_group_id uuid, p_mandate_id uuid, p_event_type text,
    p_source_decision_id uuid default null, p_reason text default null,
    p_metadata jsonb default '{}'::jsonb
) returns uuid language plpgsql security definer set search_path=public as $$
declare v_id uuid; v_full jsonb; v_summary text;
begin
    insert into public.group_mandate_events (
        group_id, mandate_id, event_type, actor_user_id,
        source_decision_id, reason, metadata
    ) values (
        p_group_id, p_mandate_id, p_event_type, (select auth.uid()),
        p_source_decision_id, p_reason, coalesce(p_metadata,'{}'::jsonb)
    ) returning id into v_id;
    v_full := coalesce(p_metadata,'{}'::jsonb) || jsonb_build_object(
        'mandate_id', p_mandate_id, 'audit_event_id', v_id,
        'source_decision_id', p_source_decision_id, 'reason', p_reason);
    v_summary := case p_event_type when 'granted' then 'Mandato otorgado'
        when 'revoked' then 'Mandato revocado' when 'expired' then 'Mandato expirado'
        when 'updated' then 'Mandato actualizado' else 'Mandato' end;
    perform public.record_system_event(
        p_group_id, 'mandate.'||p_event_type, 'mandate', p_mandate_id, v_summary, v_full);
    return v_id;
end$$;

-- RPC refactors
create or replace function public.assign_role_to_member(
    p_membership_id uuid, p_role_id uuid,
    p_source_decision_id uuid default null, p_reason text default null
) returns void language plpgsql security definer set search_path=public as $$
DECLARE v_group uuid; v_inserted boolean := false;
BEGIN
    SELECT group_id INTO v_group FROM public.group_memberships WHERE id = p_membership_id;
    IF v_group IS NULL THEN RAISE EXCEPTION 'membership not found'; END IF;
    PERFORM public.assert_permission(v_group, 'roles.manage');
    IF NOT EXISTS (SELECT 1 FROM public.group_roles WHERE id = p_role_id AND group_id = v_group) THEN
        RAISE EXCEPTION 'role_not_in_group' USING errcode='22023';
    END IF;
    WITH ins AS (
        INSERT INTO public.group_member_roles (membership_id, role_id, assigned_by)
        VALUES (p_membership_id, p_role_id, (select auth.uid()))
        ON CONFLICT DO NOTHING RETURNING 1
    ) SELECT EXISTS(SELECT 1 FROM ins) INTO v_inserted;
    IF v_inserted THEN
        INSERT INTO public.group_membership_events (group_id, membership_id, actor_user_id, event_type, payload)
        VALUES (v_group, p_membership_id, (select auth.uid()), 'role_assigned',
                jsonb_build_object('role_id', p_role_id, 'source_decision_id', p_source_decision_id));
        PERFORM public._record_role_event(v_group, p_membership_id, p_role_id, 'assigned',
            p_source_decision_id, p_reason, '{}'::jsonb);
    END IF;
END $$;

create or replace function public.revoke_role_from_member(
    p_membership_id uuid, p_role_id uuid,
    p_source_decision_id uuid default null, p_reason text default null
) returns void language plpgsql security definer set search_path=public as $$
DECLARE v_group uuid; v_remaining int; v_existed boolean := false;
BEGIN
    SELECT group_id INTO v_group FROM public.group_memberships WHERE id = p_membership_id;
    IF v_group IS NULL THEN RAISE EXCEPTION 'membership not found'; END IF;
    PERFORM public.assert_permission(v_group, 'roles.manage');
    SELECT count(*) INTO v_remaining FROM public.group_member_roles
        WHERE membership_id = p_membership_id AND role_id <> p_role_id;
    IF v_remaining = 0 THEN RAISE EXCEPTION 'cannot revoke last role from member'; END IF;
    WITH del AS (
        DELETE FROM public.group_member_roles
        WHERE membership_id = p_membership_id AND role_id = p_role_id RETURNING 1
    ) SELECT EXISTS(SELECT 1 FROM del) INTO v_existed;
    IF v_existed THEN
        INSERT INTO public.group_membership_events (group_id, membership_id, actor_user_id, event_type, payload)
        VALUES (v_group, p_membership_id, (select auth.uid()), 'role_revoked',
                jsonb_build_object('role_id', p_role_id, 'source_decision_id', p_source_decision_id));
        PERFORM public._record_role_event(v_group, p_membership_id, p_role_id, 'removed',
            p_source_decision_id, p_reason, '{}'::jsonb);
    END IF;
END $$;

create or replace function public.grant_mandate(
    p_group_id uuid, p_representative_membership_id uuid, p_mandate_type text,
    p_principal_type text default 'group', p_principal_id uuid default null,
    p_scope jsonb default '{}'::jsonb, p_ends_at timestamptz default null,
    p_source_decision_id uuid default null
) returns uuid language plpgsql security definer set search_path='public','pg_catalog' as $$
DECLARE v_uid uuid := auth.uid(); v_mtype text; v_ptype text; v_scope jsonb; v_id uuid;
BEGIN
    IF v_uid IS NULL THEN RAISE EXCEPTION 'must be authenticated' USING errcode='42501'; END IF;
    IF NOT EXISTS (SELECT 1 FROM public.group_memberships gm
        WHERE gm.group_id=p_group_id AND gm.user_id=v_uid AND gm.status='active') THEN
        RAISE EXCEPTION 'caller not active member' USING errcode='42501'; END IF;
    v_mtype := NULLIF(btrim(coalesce(p_mandate_type,'')),'');
    IF v_mtype IS NULL OR v_mtype NOT IN ('speak','sign','vote','negotiate','spend','represent','delegate','other') THEN
        RAISE EXCEPTION 'invalid mandate type' USING errcode='22023'; END IF;
    v_ptype := COALESCE(NULLIF(btrim(coalesce(p_principal_type,'')),''), 'group');
    IF v_ptype NOT IN ('group','committee','role','membership') THEN
        RAISE EXCEPTION 'invalid principal type' USING errcode='22023'; END IF;
    IF v_ptype <> 'group' AND p_principal_id IS NULL THEN
        RAISE EXCEPTION 'principal_id required' USING errcode='22023'; END IF;
    IF NOT EXISTS (SELECT 1 FROM public.group_memberships gm
        WHERE gm.id=p_representative_membership_id AND gm.group_id=p_group_id AND gm.status='active') THEN
        RAISE EXCEPTION 'representative not active member' USING errcode='22023'; END IF;
    IF p_ends_at IS NOT NULL AND p_ends_at <= now() THEN
        RAISE EXCEPTION 'ends_at must be in future' USING errcode='22023'; END IF;
    v_scope := COALESCE(p_scope,'{}'::jsonb);
    PERFORM public.assert_permission(p_group_id, 'mandates.grant');
    INSERT INTO public.group_mandates (group_id, principal_type, principal_id,
        representative_membership_id, mandate_type, scope, status, ends_at,
        source_decision_id, granted_by)
    VALUES (p_group_id, v_ptype,
        CASE WHEN v_ptype='group' THEN NULL ELSE p_principal_id END,
        p_representative_membership_id, v_mtype, v_scope, 'active', p_ends_at,
        p_source_decision_id, v_uid)
    RETURNING id INTO v_id;
    PERFORM public._record_mandate_event(p_group_id, v_id, 'granted', p_source_decision_id, NULL,
        jsonb_build_object('mandate_type', v_mtype, 'principal_type', v_ptype,
            'representative_membership_id', p_representative_membership_id, 'ends_at', p_ends_at));
    RETURN v_id;
END $$;

create or replace function public.revoke_mandate(
    p_mandate_id uuid, p_reason text default null, p_source_decision_id uuid default null
) returns void language plpgsql security definer set search_path='public','pg_catalog' as $$
DECLARE v_uid uuid := auth.uid(); v_group_id uuid; v_status text; v_reason text;
BEGIN
    IF v_uid IS NULL THEN RAISE EXCEPTION 'must be authenticated' USING errcode='42501'; END IF;
    SELECT m.group_id, m.status INTO v_group_id, v_status FROM public.group_mandates m
        WHERE m.id=p_mandate_id FOR UPDATE;
    IF v_group_id IS NULL THEN RAISE EXCEPTION 'mandate not found' USING errcode='P0002'; END IF;
    IF NOT EXISTS (SELECT 1 FROM public.group_memberships gm
        WHERE gm.group_id=v_group_id AND gm.user_id=v_uid AND gm.status='active') THEN
        RAISE EXCEPTION 'caller not active member' USING errcode='42501'; END IF;
    PERFORM public.assert_permission(v_group_id, 'mandates.revoke');
    IF v_status <> 'active' THEN RETURN; END IF;
    v_reason := NULLIF(btrim(coalesce(p_reason,'')),'');
    UPDATE public.group_mandates SET status='revoked', revoked_at=now(), revoked_by=v_uid,
        revoked_reason=v_reason, updated_at=now() WHERE id=p_mandate_id;
    PERFORM public._record_mandate_event(v_group_id, p_mandate_id, 'revoked',
        p_source_decision_id, v_reason, '{}'::jsonb);
END $$;

create or replace function public.expire_mandate_if_due(p_mandate_id uuid)
returns boolean language plpgsql security definer set search_path=public as $$
declare v_m public.group_mandates%ROWTYPE;
begin
    select * into v_m from public.group_mandates where id=p_mandate_id for update;
    if v_m.id is null then return false; end if;
    if v_m.status <> 'active' then return false; end if;
    if v_m.ends_at is null or v_m.ends_at > now() then return false; end if;
    update public.group_mandates set status='expired', updated_at=now() where id=p_mandate_id;
    perform public._record_mandate_event(v_m.group_id, p_mandate_id, 'expired',
        null, 'ends_at_reached', '{}'::jsonb);
    return true;
end$$;

-- Backfill role events (no assigned_at col on group_member_roles → use created_at)
insert into public.group_role_assignment_events (
    group_id, membership_id, role_id, event_type, actor_user_id,
    source_decision_id, reason, metadata, created_at
)
select gm.group_id, gmr.membership_id, gmr.role_id, 'assigned',
       gmr.assigned_by, null, 'backfill',
       jsonb_build_object('backfill', true), coalesce(gmr.created_at, now())
from public.group_member_roles gmr
join public.group_memberships gm on gm.id = gmr.membership_id
join public.group_roles gr on gr.id = gmr.role_id and gr.group_id = gm.group_id
where not exists (
    select 1 from public.group_role_assignment_events e
    where e.membership_id = gmr.membership_id
      and e.role_id = gmr.role_id
      and e.event_type = 'assigned'
);

-- Backfill mandate granted
insert into public.group_mandate_events (
    group_id, mandate_id, event_type, actor_user_id,
    source_decision_id, reason, metadata, created_at
)
select m.group_id, m.id, 'granted', m.granted_by, m.source_decision_id, 'backfill',
       jsonb_build_object('mandate_type', m.mandate_type, 'principal_type', m.principal_type, 'backfill', true),
       coalesce(m.created_at, now())
from public.group_mandates m
where not exists (
    select 1 from public.group_mandate_events e
    where e.mandate_id = m.id and e.event_type = 'granted'
);

-- Backfill mandate revoked
insert into public.group_mandate_events (
    group_id, mandate_id, event_type, actor_user_id,
    source_decision_id, reason, metadata, created_at
)
select m.group_id, m.id, 'revoked', m.revoked_by, null, coalesce(m.revoked_reason,'backfill'),
       jsonb_build_object('backfill', true), coalesce(m.revoked_at, now())
from public.group_mandates m
where m.status='revoked'
  and not exists (select 1 from public.group_mandate_events e
                  where e.mandate_id = m.id and e.event_type = 'revoked');

grant execute on function public.assign_role_to_member(uuid, uuid, uuid, text) to authenticated;
grant execute on function public.revoke_role_from_member(uuid, uuid, uuid, text) to authenticated;
grant execute on function public.grant_mandate(uuid, uuid, text, text, uuid, jsonb, timestamptz, uuid) to authenticated;
grant execute on function public.revoke_mandate(uuid, text, uuid) to authenticated;
grant execute on function public.expire_mandate_if_due(uuid) to authenticated;
