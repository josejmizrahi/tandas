-- d24_p6_comments
-- Reconstruido desde supabase_migrations.schema_migrations (live DB wyvkqveienzixinonhum)
-- en R.1 para restaurar la replicabilidad del repo (drift fix: la sesion original
-- aplico esta migration via MCP pero no commiteo el archivo al repo).

-- =====================================================================
-- V3 D.24 PHASE 6 — Universal Comments
--
-- Standalone cross-primitive comment thread per (entity_kind, entity_id).
-- Append-only contenido (body inmutable post-INSERT); status + archived_at
-- mutables vía RPCs específicas (archive by author or moderator).
--
-- Scope: lineal (no parent_comment_id todavía). Allowlist entity_kind 11.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Tabla
-- ---------------------------------------------------------------------

create table if not exists public.group_comments (
    id uuid primary key default gen_random_uuid(),
    group_id uuid not null references public.groups(id) on delete cascade,
    entity_kind text not null
        check (entity_kind in (
            'decision','resource','event','sanction','dispute','rule',
            'membership','external_party','mandate','obligation','settlement'
        )),
    entity_id uuid not null,
    actor_membership_id uuid references public.group_memberships(id) on delete set null,
    body text not null check (length(btrim(body)) > 0),
    status text not null default 'active'
        check (status in ('active','archived','deleted_by_moderator','deleted_by_author')),
    metadata jsonb not null default '{}'::jsonb,
    client_id text,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    archived_at timestamptz
);

create unique index if not exists group_comments_client_id_uq
    on public.group_comments(group_id, client_id)
    where client_id is not null;
create index if not exists group_comments_entity_idx
    on public.group_comments(group_id, entity_kind, entity_id, created_at desc);
create index if not exists group_comments_actor_idx
    on public.group_comments(actor_membership_id, created_at desc)
    where actor_membership_id is not null;
create index if not exists group_comments_active_idx
    on public.group_comments(group_id, entity_kind, entity_id)
    where status = 'active';

-- ---------------------------------------------------------------------
-- 2. Content-immutability guard
--    body/entity_kind/entity_id/actor_membership_id/group_id NEVER change.
--    status/archived_at/metadata CAN change (via SECURITY DEFINER RPCs).
-- ---------------------------------------------------------------------

create or replace function public._comment_content_immutable()
returns trigger language plpgsql as $$
begin
    if NEW.body            <> OLD.body            then raise exception 'comment body is append-only' using errcode='42501'; end if;
    if NEW.entity_kind     <> OLD.entity_kind     then raise exception 'comment entity_kind immutable' using errcode='42501'; end if;
    if NEW.entity_id       <> OLD.entity_id       then raise exception 'comment entity_id immutable' using errcode='42501'; end if;
    if NEW.group_id        <> OLD.group_id        then raise exception 'comment group_id immutable' using errcode='42501'; end if;
    if coalesce(NEW.actor_membership_id::text,'') <> coalesce(OLD.actor_membership_id::text,'')
        then raise exception 'comment actor immutable' using errcode='42501'; end if;
    if NEW.created_at      <> OLD.created_at      then raise exception 'comment created_at immutable' using errcode='42501'; end if;
    NEW.updated_at := now();
    return NEW;
end$$;

drop trigger if exists trg_comment_content_immutable on public.group_comments;
create trigger trg_comment_content_immutable
    before update on public.group_comments
    for each row execute function public._comment_content_immutable();

-- Append-only DELETE guard.
drop trigger if exists trg_comment_no_delete on public.group_comments;
create trigger trg_comment_no_delete
    before delete on public.group_comments
    for each statement execute function public.atom_no_delete_guard();

-- ---------------------------------------------------------------------
-- 3. RLS
-- ---------------------------------------------------------------------

alter table public.group_comments enable row level security;

drop policy if exists "comments_read" on public.group_comments;
create policy "comments_read" on public.group_comments
    for select to authenticated using (public.is_group_member(group_id));

-- Writes solo via SECURITY DEFINER RPCs.

-- ---------------------------------------------------------------------
-- 4. Permissions catalog + per-group role seed
-- ---------------------------------------------------------------------

insert into public.permissions (key, description, category) values
    ('comments.read',     'Leer comments del grupo',             'comments'),
    ('comments.create',   'Crear comments en cualquier entidad', 'comments'),
    ('comments.moderate', 'Archivar comments de otros miembros', 'comments')
on conflict (key) do nothing;

do $$
declare v_role record;
begin
    for v_role in
        select id, key from public.group_roles where key in ('founder','admin','member')
    loop
        insert into public.group_role_permissions(role_id, permission_key)
        values (v_role.id, 'comments.read') on conflict do nothing;
        insert into public.group_role_permissions(role_id, permission_key)
        values (v_role.id, 'comments.create') on conflict do nothing;
        if v_role.key in ('founder','admin') then
            insert into public.group_role_permissions(role_id, permission_key)
            values (v_role.id, 'comments.moderate') on conflict do nothing;
        end if;
    end loop;
end$$;

-- ---------------------------------------------------------------------
-- 5. RPCs
-- ---------------------------------------------------------------------

-- 5.1 create_group_comment
create or replace function public.create_group_comment(
    p_group_id uuid,
    p_entity_kind text,
    p_entity_id uuid,
    p_body text,
    p_metadata jsonb default '{}'::jsonb,
    p_client_id text default null
) returns uuid
language plpgsql security definer set search_path=public, pg_catalog as $$
declare
    v_uid uuid := (select auth.uid());
    v_membership uuid;
    v_id uuid;
    v_existing uuid;
    v_body text;
begin
    if v_uid is null then raise exception 'auth_required' using errcode='42501'; end if;
    if not public.is_group_member(p_group_id) then
        raise exception 'not_a_member' using errcode='42501';
    end if;
    if not public.has_group_permission(p_group_id, 'comments.create') then
        raise exception 'missing_permission: comments.create' using errcode='42501';
    end if;
    if p_entity_kind is null or p_entity_kind not in (
        'decision','resource','event','sanction','dispute','rule',
        'membership','external_party','mandate','obligation','settlement'
    ) then
        raise exception 'invalid_entity_kind: %', p_entity_kind using errcode='22023';
    end if;
    if p_entity_id is null then raise exception 'entity_id_required' using errcode='22023'; end if;
    v_body := nullif(btrim(coalesce(p_body,'')),'');
    if v_body is null then raise exception 'body_required' using errcode='22023'; end if;

    -- Idempotency
    if p_client_id is not null then
        select id into v_existing from public.group_comments
        where group_id=p_group_id and client_id=p_client_id;
        if v_existing is not null then return v_existing; end if;
    end if;

    select id into v_membership from public.group_memberships
    where group_id=p_group_id and user_id=v_uid and status='active' limit 1;

    insert into public.group_comments (
        group_id, entity_kind, entity_id, actor_membership_id, body,
        status, metadata, client_id
    ) values (
        p_group_id, p_entity_kind, p_entity_id, v_membership, v_body,
        'active', coalesce(p_metadata,'{}'::jsonb), p_client_id
    ) returning id into v_id;

    perform public.record_system_event(
        p_group_id, 'comment.created', 'comment', v_id,
        substr(v_body, 1, 80),
        jsonb_build_object('entity_kind', p_entity_kind, 'entity_id', p_entity_id,
            'actor_membership_id', v_membership));
    return v_id;
end$$;

-- 5.2 archive_group_comment
create or replace function public.archive_group_comment(
    p_comment_id uuid,
    p_reason text default null
) returns void
language plpgsql security definer set search_path=public, pg_catalog as $$
declare
    v_uid uuid := (select auth.uid());
    v_c public.group_comments%ROWTYPE;
    v_caller_membership uuid;
    v_is_author boolean := false;
    v_can_moderate boolean := false;
    v_new_status text;
begin
    if v_uid is null then raise exception 'auth_required' using errcode='42501'; end if;
    select * into v_c from public.group_comments where id=p_comment_id for update;
    if v_c.id is null then raise exception 'comment_not_found' using errcode='42704'; end if;
    if not public.is_group_member(v_c.group_id) then raise exception 'not_a_member' using errcode='42501'; end if;

    select id into v_caller_membership from public.group_memberships
    where group_id=v_c.group_id and user_id=v_uid and status='active' limit 1;
    v_is_author := (v_caller_membership is not null AND v_caller_membership = v_c.actor_membership_id);
    v_can_moderate := public.has_group_permission(v_c.group_id, 'comments.moderate');

    if not v_is_author and not v_can_moderate then
        raise exception 'missing_permission: comments.moderate' using errcode='42501';
    end if;

    -- Idempotent: already archived
    if v_c.status in ('archived','deleted_by_moderator','deleted_by_author') then return; end if;

    -- Author archival → status=deleted_by_author
    -- Moderator archival → status=deleted_by_moderator
    -- (founder spec: status="archived" is reserved for soft-archive en futuro)
    if v_is_author then
        v_new_status := 'deleted_by_author';
    else
        v_new_status := 'deleted_by_moderator';
    end if;

    update public.group_comments
       set status = v_new_status,
           archived_at = now(),
           metadata = metadata || jsonb_strip_nulls(jsonb_build_object('archive_reason', p_reason))
     where id = p_comment_id;

    perform public.record_system_event(
        v_c.group_id, 'comment.archived', 'comment', p_comment_id,
        substr(v_c.body, 1, 80),
        jsonb_build_object('entity_kind', v_c.entity_kind, 'entity_id', v_c.entity_id,
            'archived_by_membership_id', v_caller_membership,
            'archived_status', v_new_status,
            'reason', p_reason));
end$$;

-- 5.3 list_group_comments
create or replace function public.list_group_comments(
    p_group_id uuid,
    p_entity_kind text,
    p_entity_id uuid,
    p_include_archived boolean default false,
    p_limit integer default 100
) returns table(
    id uuid, group_id uuid, entity_kind text, entity_id uuid,
    actor_membership_id uuid, actor_display_name text,
    body text, status text, metadata jsonb,
    created_at timestamptz, updated_at timestamptz, archived_at timestamptz
) language sql stable security definer set search_path=public as $$
    select c.id, c.group_id, c.entity_kind, c.entity_id,
           c.actor_membership_id,
           coalesce(p.display_name, p.username) as actor_display_name,
           case when c.status='deleted_by_author' then '[mensaje borrado por el autor]'
                when c.status='deleted_by_moderator' then '[mensaje removido por moderación]'
                else c.body end as body,
           c.status, c.metadata, c.created_at, c.updated_at, c.archived_at
    from public.group_comments c
    left join public.group_memberships gm on gm.id = c.actor_membership_id
    left join public.profiles p on p.id = gm.user_id
    where c.group_id = p_group_id
      and public.is_group_member(p_group_id)
      and (p_entity_kind is null or c.entity_kind = p_entity_kind)
      and (p_entity_id is null or c.entity_id = p_entity_id)
      and (p_include_archived or c.status = 'active')
    order by c.created_at asc
    limit greatest(coalesce(p_limit, 100), 1);
$$;

-- ---------------------------------------------------------------------
-- 6. Grants
-- ---------------------------------------------------------------------

grant execute on function public.create_group_comment(uuid, text, uuid, text, jsonb, text) to authenticated;
grant execute on function public.archive_group_comment(uuid, text) to authenticated;
grant execute on function public.list_group_comments(uuid, text, uuid, boolean, integer) to authenticated;
