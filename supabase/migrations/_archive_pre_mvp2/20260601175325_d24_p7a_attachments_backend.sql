-- d24_p7a_attachments_backend
-- Reconstruido desde supabase_migrations.schema_migrations (live DB wyvkqveienzixinonhum)
-- en R.1 para restaurar la replicabilidad del repo (drift fix: la sesion original
-- aplico esta migration via MCP pero no commiteo el archivo al repo).

-- =====================================================================
-- V3 D.24 PHASE 7A — Universal Attachments (backend-only)
--
-- Scope per founder: metadata-only table + 3 RPCs + perms + smoke.
-- NO Supabase Storage bucket policies, NO iOS upload, NO signed URL
-- refresh — eso es PHASE 7B.
-- =====================================================================

create table if not exists public.group_attachments (
    id uuid primary key default gen_random_uuid(),
    group_id uuid not null references public.groups(id) on delete cascade,
    entity_kind text not null
        check (entity_kind in (
            'decision','resource','event','sanction','dispute','rule',
            'membership','external_party','mandate','obligation','settlement','comment'
        )),
    entity_id uuid not null,
    uploaded_by_membership_id uuid references public.group_memberships(id) on delete set null,
    file_url text not null check (length(btrim(file_url)) > 0),
    storage_bucket text,
    storage_path text,
    file_name text,
    mime_type text,
    size_bytes bigint check (size_bytes is null or size_bytes >= 0),
    attachment_kind text not null default 'file'
        check (attachment_kind in ('file','image','receipt','evidence','contract','document','photo','other')),
    status text not null default 'active'
        check (status in ('active','archived','deleted_by_author','deleted_by_moderator')),
    metadata jsonb not null default '{}'::jsonb,
    client_id text,
    created_at timestamptz not null default now(),
    archived_at timestamptz
);

create unique index if not exists group_attachments_client_id_uq
    on public.group_attachments(group_id, client_id)
    where client_id is not null;
create index if not exists group_attachments_entity_idx
    on public.group_attachments(group_id, entity_kind, entity_id, created_at desc);
create index if not exists group_attachments_active_idx
    on public.group_attachments(group_id, entity_kind, entity_id)
    where status = 'active';
create index if not exists group_attachments_uploader_idx
    on public.group_attachments(uploaded_by_membership_id, created_at desc)
    where uploaded_by_membership_id is not null;
create index if not exists group_attachments_kind_idx
    on public.group_attachments(group_id, attachment_kind)
    where status='active';

-- Content-immutability guard. status/archived_at/metadata mutables.
create or replace function public._attachment_content_immutable()
returns trigger language plpgsql as $$
begin
    if NEW.group_id        <> OLD.group_id        then raise exception 'attachment group_id immutable' using errcode='42501'; end if;
    if NEW.entity_kind     <> OLD.entity_kind     then raise exception 'attachment entity_kind immutable' using errcode='42501'; end if;
    if NEW.entity_id       <> OLD.entity_id       then raise exception 'attachment entity_id immutable' using errcode='42501'; end if;
    if NEW.file_url        <> OLD.file_url        then raise exception 'attachment file_url immutable' using errcode='42501'; end if;
    if coalesce(NEW.storage_path,'') <> coalesce(OLD.storage_path,'')
        then raise exception 'attachment storage_path immutable' using errcode='42501'; end if;
    if coalesce(NEW.storage_bucket,'') <> coalesce(OLD.storage_bucket,'')
        then raise exception 'attachment storage_bucket immutable' using errcode='42501'; end if;
    if NEW.attachment_kind <> OLD.attachment_kind then raise exception 'attachment_kind immutable' using errcode='42501'; end if;
    if coalesce(NEW.uploaded_by_membership_id::text,'') <> coalesce(OLD.uploaded_by_membership_id::text,'')
        then raise exception 'attachment uploader immutable' using errcode='42501'; end if;
    if NEW.created_at      <> OLD.created_at      then raise exception 'attachment created_at immutable' using errcode='42501'; end if;
    return NEW;
end$$;

drop trigger if exists trg_attachment_content_immutable on public.group_attachments;
create trigger trg_attachment_content_immutable
    before update on public.group_attachments
    for each row execute function public._attachment_content_immutable();

drop trigger if exists trg_attachment_no_delete on public.group_attachments;
create trigger trg_attachment_no_delete
    before delete on public.group_attachments
    for each statement execute function public.atom_no_delete_guard();

-- RLS
alter table public.group_attachments enable row level security;
drop policy if exists "attachments_read" on public.group_attachments;
create policy "attachments_read" on public.group_attachments
    for select to authenticated using (public.is_group_member(group_id));

-- Perms
insert into public.permissions (key, description, category) values
    ('attachments.read',     'Leer attachments del grupo',         'attachments'),
    ('attachments.create',   'Subir attachments en cualquier entidad', 'attachments'),
    ('attachments.moderate', 'Archivar attachments de otros',      'attachments')
on conflict (key) do nothing;

do $$
declare v_role record;
begin
    for v_role in
        select id, key from public.group_roles where key in ('founder','admin','member')
    loop
        insert into public.group_role_permissions(role_id, permission_key)
        values (v_role.id, 'attachments.read') on conflict do nothing;
        insert into public.group_role_permissions(role_id, permission_key)
        values (v_role.id, 'attachments.create') on conflict do nothing;
        if v_role.key in ('founder','admin') then
            insert into public.group_role_permissions(role_id, permission_key)
            values (v_role.id, 'attachments.moderate') on conflict do nothing;
        end if;
    end loop;
end$$;

-- RPCs

create or replace function public.create_group_attachment_metadata(
    p_group_id uuid,
    p_entity_kind text,
    p_entity_id uuid,
    p_attachment_kind text,
    p_file_url text,
    p_file_name text default null,
    p_mime_type text default null,
    p_size_bytes bigint default null,
    p_storage_bucket text default null,
    p_storage_path text default null,
    p_metadata jsonb default '{}'::jsonb,
    p_client_id text default null
) returns uuid
language plpgsql security definer set search_path=public, pg_catalog as $$
declare
    v_uid uuid := (select auth.uid());
    v_membership uuid;
    v_id uuid;
    v_existing uuid;
    v_url text;
begin
    if v_uid is null then raise exception 'auth_required' using errcode='42501'; end if;
    if not public.is_group_member(p_group_id) then raise exception 'not_a_member' using errcode='42501'; end if;
    if not public.has_group_permission(p_group_id, 'attachments.create') then
        raise exception 'missing_permission: attachments.create' using errcode='42501';
    end if;
    if p_entity_kind is null or p_entity_kind not in (
        'decision','resource','event','sanction','dispute','rule',
        'membership','external_party','mandate','obligation','settlement','comment'
    ) then raise exception 'invalid_entity_kind: %', p_entity_kind using errcode='22023'; end if;
    if p_entity_id is null then raise exception 'entity_id_required' using errcode='22023'; end if;
    if p_attachment_kind is null or p_attachment_kind not in
        ('file','image','receipt','evidence','contract','document','photo','other')
        then raise exception 'invalid_attachment_kind: %', p_attachment_kind using errcode='22023'; end if;
    v_url := nullif(btrim(coalesce(p_file_url,'')),'');
    if v_url is null then raise exception 'file_url_required' using errcode='22023'; end if;
    if p_size_bytes is not null and p_size_bytes < 0 then
        raise exception 'invalid_size_bytes' using errcode='22023'; end if;

    if p_client_id is not null then
        select id into v_existing from public.group_attachments
        where group_id=p_group_id and client_id=p_client_id;
        if v_existing is not null then return v_existing; end if;
    end if;

    select id into v_membership from public.group_memberships
    where group_id=p_group_id and user_id=v_uid and status='active' limit 1;

    insert into public.group_attachments (
        group_id, entity_kind, entity_id, uploaded_by_membership_id,
        file_url, storage_bucket, storage_path, file_name, mime_type, size_bytes,
        attachment_kind, status, metadata, client_id
    ) values (
        p_group_id, p_entity_kind, p_entity_id, v_membership,
        v_url,
        nullif(btrim(coalesce(p_storage_bucket,'')),''),
        nullif(btrim(coalesce(p_storage_path,'')),''),
        nullif(btrim(coalesce(p_file_name,'')),''),
        nullif(btrim(coalesce(p_mime_type,'')),''),
        p_size_bytes, p_attachment_kind, 'active',
        coalesce(p_metadata,'{}'::jsonb), p_client_id
    ) returning id into v_id;

    perform public.record_system_event(
        p_group_id, 'attachment.created', 'attachment', v_id,
        coalesce(nullif(btrim(p_file_name),''), p_attachment_kind),
        jsonb_build_object(
            'entity_kind', p_entity_kind, 'entity_id', p_entity_id,
            'attachment_kind', p_attachment_kind,
            'mime_type', p_mime_type, 'size_bytes', p_size_bytes,
            'uploaded_by_membership_id', v_membership));
    return v_id;
end$$;

create or replace function public.archive_group_attachment(
    p_attachment_id uuid, p_reason text default null
) returns void
language plpgsql security definer set search_path=public, pg_catalog as $$
declare
    v_uid uuid := (select auth.uid());
    v_a public.group_attachments%ROWTYPE;
    v_caller_membership uuid;
    v_is_uploader boolean := false;
    v_can_moderate boolean := false;
    v_new_status text;
begin
    if v_uid is null then raise exception 'auth_required' using errcode='42501'; end if;
    select * into v_a from public.group_attachments where id=p_attachment_id for update;
    if v_a.id is null then raise exception 'attachment_not_found' using errcode='42704'; end if;
    if not public.is_group_member(v_a.group_id) then raise exception 'not_a_member' using errcode='42501'; end if;

    select id into v_caller_membership from public.group_memberships
    where group_id=v_a.group_id and user_id=v_uid and status='active' limit 1;
    v_is_uploader := (v_caller_membership is not null AND v_caller_membership = v_a.uploaded_by_membership_id);
    v_can_moderate := public.has_group_permission(v_a.group_id, 'attachments.moderate');

    if not v_is_uploader and not v_can_moderate then
        raise exception 'missing_permission: attachments.moderate' using errcode='42501';
    end if;
    if v_a.status in ('archived','deleted_by_author','deleted_by_moderator') then return; end if;

    if v_is_uploader then v_new_status := 'deleted_by_author';
    else v_new_status := 'deleted_by_moderator'; end if;

    update public.group_attachments
       set status = v_new_status,
           archived_at = now(),
           metadata = metadata || jsonb_strip_nulls(jsonb_build_object('archive_reason', p_reason))
     where id = p_attachment_id;

    perform public.record_system_event(
        v_a.group_id, 'attachment.archived', 'attachment', p_attachment_id,
        coalesce(v_a.file_name, v_a.attachment_kind),
        jsonb_build_object('entity_kind', v_a.entity_kind, 'entity_id', v_a.entity_id,
            'archived_by_membership_id', v_caller_membership,
            'archived_status', v_new_status, 'reason', p_reason));
end$$;

create or replace function public.list_group_attachments(
    p_group_id uuid,
    p_entity_kind text default null,
    p_entity_id uuid default null,
    p_attachment_kind text default null,
    p_include_archived boolean default false,
    p_limit integer default 100
) returns table(
    id uuid, group_id uuid, entity_kind text, entity_id uuid,
    uploaded_by_membership_id uuid, uploader_display_name text,
    file_url text, storage_bucket text, storage_path text,
    file_name text, mime_type text, size_bytes bigint,
    attachment_kind text, status text, metadata jsonb,
    created_at timestamptz, archived_at timestamptz
) language sql stable security definer set search_path=public as $$
    select a.id, a.group_id, a.entity_kind, a.entity_id,
           a.uploaded_by_membership_id,
           coalesce(p.display_name, p.username) as uploader_display_name,
           a.file_url, a.storage_bucket, a.storage_path,
           a.file_name, a.mime_type, a.size_bytes,
           a.attachment_kind, a.status, a.metadata,
           a.created_at, a.archived_at
    from public.group_attachments a
    left join public.group_memberships gm on gm.id = a.uploaded_by_membership_id
    left join public.profiles p on p.id = gm.user_id
    where a.group_id = p_group_id
      and public.is_group_member(p_group_id)
      and (p_entity_kind is null or a.entity_kind = p_entity_kind)
      and (p_entity_id is null or a.entity_id = p_entity_id)
      and (p_attachment_kind is null or a.attachment_kind = p_attachment_kind)
      and (p_include_archived or a.status = 'active')
    order by a.created_at desc
    limit greatest(coalesce(p_limit, 100), 1);
$$;

grant execute on function public.create_group_attachment_metadata(uuid, text, uuid, text, text, text, text, bigint, text, text, jsonb, text) to authenticated;
grant execute on function public.archive_group_attachment(uuid, text) to authenticated;
grant execute on function public.list_group_attachments(uuid, text, uuid, text, boolean, integer) to authenticated;
