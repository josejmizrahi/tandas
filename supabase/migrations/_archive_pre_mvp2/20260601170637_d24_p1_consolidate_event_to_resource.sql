-- d24_p1_consolidate_event_to_resource
-- Reconstruido desde supabase_migrations.schema_migrations (live DB wyvkqveienzixinonhum)
-- en R.1 para restaurar la replicabilidad del repo (drift fix: la sesion original
-- aplico esta migration via MCP pero no commiteo el archivo al repo).

-- =====================================================================
-- V3 D.24 PHASE 1 — Consolidate Calendar Event → resource_type='event'
-- Re-apply with split SELECT INTO for remove_event_attendee.
-- =====================================================================

-- 1. DEPRECATED comments
comment on table public.group_calendar_events is
    'DEPRECATED (D.24 PHASE 1, 2026-06-01) — see group_resources WHERE resource_type=event. Zero live rows. Drop scheduled >=1 release after wrappers proven.';
comment on table public.group_calendar_event_attendees is
    'DEPRECATED (D.24 PHASE 1, 2026-06-01) — replaced by group_resources.metadata.event_roster + group_rsvp_actions.';
comment on table public.group_calendar_event_reminders is
    'DEPRECATED (D.24 PHASE 1, 2026-06-01) — replaced by group_resource_capabilities (capability_key=reminders).';

-- 2. Helpers
create or replace function public._event_v3_to_canon_visibility(p_v text)
returns text language sql immutable as $$
    select case coalesce(p_v,'group')
        when 'group' then 'members' when 'invited' then 'private'
        when 'admins' then 'private' when 'public_link' then 'public'
        else 'members' end;
$$;

create or replace function public._event_v3_validate_visibility(p_v text)
returns void language plpgsql immutable as $$
begin
    if p_v is not null and p_v not in ('group','invited','admins','public_link') then
        raise exception 'invalid_visibility: %', p_v using errcode='22023';
    end if;
end$$;

create or replace function public._event_v3_validate_type(p_t text)
returns void language plpgsql immutable as $$
begin
    if p_t is not null and p_t not in (
        'social','meal','meeting_candidate','ceremony',
        'work_session','deadline','maintenance','trip','ritual','other'
    ) then
        raise exception 'invalid_event_type: %', p_t using errcode='22023';
    end if;
end$$;

create or replace function public._event_caller_membership(p_group_id uuid)
returns uuid language sql stable security definer set search_path=public as $$
    select id from public.group_memberships
    where group_id=p_group_id and user_id=(select auth.uid()) and status='active'
    limit 1;
$$;

create or replace function public._event_is_host(p_resource_id uuid)
returns boolean language sql stable security definer set search_path=public as $$
    with mem as (
        select id from public.group_memberships
        where user_id=(select auth.uid()) and status='active'
    )
    select exists (
        select 1
        from public.group_resources r,
             jsonb_array_elements(coalesce(r.metadata->'event_roster','[]'::jsonb)) e
        where r.id=p_resource_id
          and (e->>'role') in ('host','cohost')
          and (e->>'membership_id')::uuid in (select id from mem)
    );
$$;

create or replace function public._event_derived_status(
    p_archived_at timestamptz, p_cancelled_at timestamptz, p_closed_at timestamptz
) returns text language sql immutable as $$
    select case
        when p_archived_at is not null  then 'archived'
        when p_cancelled_at is not null then 'cancelled'
        when p_closed_at is not null    then 'completed'
        else 'scheduled' end;
$$;

create or replace function public._event_attendees_json(p_resource_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare
    v_roster jsonb;
    v_attendees jsonb := '[]'::jsonb;
begin
    select coalesce(metadata->'event_roster','[]'::jsonb) into v_roster
    from public.group_resources where id=p_resource_id;

    with roster as (
        select e->>'id' as id,
               (e->>'membership_id')::uuid as membership_id,
               e->>'invited_email' as invited_email,
               e->>'invited_phone' as invited_phone,
               e->>'display_name'  as display_name,
               coalesce(e->>'role','attendee') as role,
               (e->>'added_at')::timestamptz as added_at
        from jsonb_array_elements(v_roster) e
    ),
    latest_rsvp as (
        select distinct on (a.membership_id)
            a.membership_id, a.rsvp_status, a.note, a.acted_at
        from public.group_rsvp_actions a
        where a.resource_id=p_resource_id
        order by a.membership_id, a.acted_at desc, a.id desc
    )
    select coalesce(jsonb_agg(jsonb_build_object(
        'id', r.id,
        'membership_id', r.membership_id,
        'invited_email', r.invited_email,
        'invited_phone', r.invited_phone,
        'display_name',  coalesce(r.display_name, p.display_name, p.username),
        'role',          r.role,
        'rsvp_status',   coalesce(lr.rsvp_status,'pending'),
        'rsvp_note',     lr.note,
        'responded_at',  lr.acted_at,
        'created_at',    r.added_at,
        'user_id',       gm.user_id
    ) order by
        case r.role when 'host' then 0 when 'cohost' then 1 when 'attendee' then 2 when 'optional' then 3 else 4 end,
        r.added_at
    ), '[]'::jsonb)
    into v_attendees
    from roster r
    left join latest_rsvp lr on lr.membership_id=r.membership_id
    left join public.group_memberships gm on gm.id=r.membership_id
    left join public.profiles p on p.id=gm.user_id;

    return v_attendees;
end$$;

create or replace function public._event_reminders_json(p_resource_id uuid)
returns jsonb language sql stable security definer set search_path=public as $$
    select coalesce(
        (select config->'reminders' from public.group_resource_capabilities
         where resource_id=p_resource_id and capability_key='reminders' and enabled limit 1),
        '[]'::jsonb);
$$;

-- 3. Drop old D.23 RPCs
drop function if exists public.create_event(uuid, text, text, text, timestamptz, timestamptz, text, text, text, text, text, text, jsonb);
drop function if exists public.update_event(uuid, text, text, text, timestamptz, timestamptz, text, text, text, text, text, text, jsonb);
drop function if exists public.cancel_event(uuid, text);
drop function if exists public.archive_event(uuid);
drop function if exists public.list_group_events(uuid, timestamptz, timestamptz, boolean, boolean);
drop function if exists public.get_event_detail(uuid);
drop function if exists public.add_event_attendee(uuid, uuid, text, text, text, text);
drop function if exists public.remove_event_attendee(uuid);
drop function if exists public.respond_event(uuid, text, text);
drop function if exists public.add_event_reminder(uuid, text, integer, text, uuid);
drop function if exists public.remove_event_reminder(uuid);

-- 4. Wrappers

-- 4.1 create_event
create function public.create_event(
    p_group_id uuid, p_title text, p_description text default null,
    p_event_type text default 'social', p_starts_at timestamptz default null,
    p_ends_at timestamptz default null, p_timezone text default null,
    p_location_name text default null, p_location_address text default null,
    p_location_url text default null, p_recurrence_rule text default null,
    p_visibility text default 'group', p_metadata jsonb default '{}'::jsonb
) returns uuid language plpgsql security definer set search_path=public as $$
declare
    v_uid uuid := (select auth.uid());
    v_membership_id uuid;
    v_resource_id uuid;
    v_metadata jsonb; v_roster jsonb;
    v_v text := coalesce(p_visibility,'group');
    v_type text := coalesce(p_event_type,'social');
begin
    if v_uid is null then raise exception 'auth_required' using errcode='42501'; end if;
    if not public.is_group_member(p_group_id) then raise exception 'not_a_member' using errcode='42501'; end if;
    if not public.has_group_permission(p_group_id,'events.create') then
        raise exception 'missing_permission: events.create' using errcode='42501'; end if;
    if p_title is null or length(btrim(p_title))=0 then raise exception 'title_required' using errcode='22023'; end if;
    if p_starts_at is null then raise exception 'starts_at_required' using errcode='22023'; end if;
    if p_ends_at is not null and p_ends_at < p_starts_at then raise exception 'ends_before_starts' using errcode='22023'; end if;
    perform public._event_v3_validate_visibility(v_v);
    perform public._event_v3_validate_type(v_type);

    v_membership_id := public._event_caller_membership(p_group_id);
    v_roster := case
        when v_membership_id is null then '[]'::jsonb
        else jsonb_build_array(jsonb_build_object(
            'id', gen_random_uuid(), 'membership_id', v_membership_id,
            'role', 'host', 'added_at', now()))
    end;
    v_metadata := coalesce(p_metadata,'{}'::jsonb) || jsonb_build_object(
        'resource_kind','event','event_subtype', v_type,
        'event_visibility', v_v, 'event_roster', v_roster,
        'timezone', p_timezone, 'location_address', p_location_address,
        'location_url', p_location_url, 'recurrence_rule', p_recurrence_rule
    );

    insert into public.group_resources (
        group_id, resource_type, name, description, status, visibility,
        ownership_kind, metadata, created_by
    ) values (
        p_group_id, 'event', btrim(p_title), p_description, 'active',
        public._event_v3_to_canon_visibility(v_v),
        'group', v_metadata, v_uid
    ) returning id into v_resource_id;

    insert into public.group_resource_events (
        resource_id, starts_at, ends_at, location, host_membership_id
    ) values (v_resource_id, p_starts_at, p_ends_at, p_location_name, v_membership_id);

    if v_membership_id is not null then
        insert into public.group_rsvp_actions (
            group_id, resource_id, membership_id, user_id, rsvp_status, note, source, acted_at
        ) values (p_group_id, v_resource_id, v_membership_id, v_uid, 'accepted', null, 'host_auto', now());
    end if;

    perform public.record_system_event(
        p_group_id, 'resource.created', 'resource', v_resource_id, btrim(p_title),
        jsonb_build_object('resource_kind','event','event_subtype', v_type,
            'starts_at', p_starts_at, 'event_visibility', v_v,
            'recurring', p_recurrence_rule is not null));
    return v_resource_id;
end$$;

-- 4.2 update_event
create function public.update_event(
    p_event_id uuid, p_title text default null, p_description text default null,
    p_event_type text default null, p_starts_at timestamptz default null,
    p_ends_at timestamptz default null, p_timezone text default null,
    p_location_name text default null, p_location_address text default null,
    p_location_url text default null, p_recurrence_rule text default null,
    p_visibility text default null, p_metadata jsonb default null
) returns void language plpgsql security definer set search_path=public as $$
declare
    v_uid uuid := (select auth.uid());
    v_resource public.group_resources; v_event public.group_resource_events;
    v_can_update boolean; v_status text;
    v_meta_patch jsonb := '{}'::jsonb;
begin
    if v_uid is null then raise exception 'auth_required' using errcode='42501'; end if;
    select * into v_resource from public.group_resources where id=p_event_id and resource_type='event';
    if not found then raise exception 'event_not_found' using errcode='42704'; end if;
    select * into v_event from public.group_resource_events where resource_id=p_event_id;
    v_status := public._event_derived_status(v_resource.archived_at, v_event.cancelled_at, v_event.closed_at);
    if v_status in ('cancelled','archived') then raise exception 'event_is_terminal: %', v_status using errcode='22023'; end if;
    v_can_update := public.has_group_permission(v_resource.group_id,'events.update') or public._event_is_host(p_event_id);
    if not v_can_update then raise exception 'missing_permission: events.update' using errcode='42501'; end if;
    perform public._event_v3_validate_visibility(p_visibility);
    perform public._event_v3_validate_type(p_event_type);
    if p_starts_at is not null and p_ends_at is not null and p_ends_at < p_starts_at then
        raise exception 'ends_before_starts' using errcode='22023'; end if;

    if p_event_type is not null then v_meta_patch := v_meta_patch || jsonb_build_object('event_subtype', p_event_type); end if;
    if p_visibility is not null then v_meta_patch := v_meta_patch || jsonb_build_object('event_visibility', p_visibility); end if;
    if p_timezone is not null then v_meta_patch := v_meta_patch || jsonb_build_object('timezone', p_timezone); end if;
    if p_location_address is not null then v_meta_patch := v_meta_patch || jsonb_build_object('location_address', p_location_address); end if;
    if p_location_url is not null then v_meta_patch := v_meta_patch || jsonb_build_object('location_url', p_location_url); end if;
    if p_recurrence_rule is not null then v_meta_patch := v_meta_patch || jsonb_build_object('recurrence_rule', p_recurrence_rule); end if;
    if p_metadata is not null then v_meta_patch := v_meta_patch || p_metadata; end if;

    update public.group_resources
    set name = coalesce(nullif(btrim(p_title),''), name),
        description = coalesce(p_description, description),
        visibility = case when p_visibility is not null then public._event_v3_to_canon_visibility(p_visibility) else visibility end,
        metadata = metadata || v_meta_patch,
        updated_at = now()
    where id=p_event_id;

    update public.group_resource_events
    set starts_at = coalesce(p_starts_at, starts_at),
        ends_at = coalesce(p_ends_at, ends_at),
        location = coalesce(p_location_name, location),
        updated_at = now()
    where resource_id=p_event_id;

    perform public.record_system_event(
        v_resource.group_id, 'resource.updated', 'resource', p_event_id,
        coalesce(nullif(btrim(p_title),''), v_resource.name),
        jsonb_build_object('resource_kind','event','updated_fields', jsonb_strip_nulls(jsonb_build_object(
            'title', p_title,'description', p_description,'event_type', p_event_type,
            'starts_at', p_starts_at,'ends_at', p_ends_at,'visibility', p_visibility,
            'recurrence_rule', p_recurrence_rule,'location_name', p_location_name))));
end$$;

-- 4.3 cancel_event
create function public.cancel_event(p_event_id uuid, p_reason text default null)
returns void language plpgsql security definer set search_path=public as $$
declare
    v_uid uuid := (select auth.uid());
    v_resource public.group_resources; v_event public.group_resource_events;
    v_status text; v_can boolean;
begin
    if v_uid is null then raise exception 'auth_required' using errcode='42501'; end if;
    select * into v_resource from public.group_resources where id=p_event_id and resource_type='event';
    if not found then raise exception 'event_not_found' using errcode='42704'; end if;
    select * into v_event from public.group_resource_events where resource_id=p_event_id;
    v_status := public._event_derived_status(v_resource.archived_at, v_event.cancelled_at, v_event.closed_at);
    if v_status in ('cancelled','archived') then raise exception 'event_is_terminal: %', v_status using errcode='22023'; end if;
    v_can := public.has_group_permission(v_resource.group_id,'events.cancel') or public._event_is_host(p_event_id);
    if not v_can then raise exception 'missing_permission: events.cancel' using errcode='42501'; end if;

    update public.group_resource_events set cancelled_at = now(), updated_at = now() where resource_id=p_event_id;
    update public.group_resources set metadata = metadata || jsonb_build_object('cancel_reason', p_reason), updated_at = now() where id=p_event_id;

    perform public.record_system_event(
        v_resource.group_id, 'resource.cancelled', 'resource', p_event_id, v_resource.name,
        jsonb_build_object('resource_kind','event','reason', p_reason));
end$$;

-- 4.4 archive_event
create function public.archive_event(p_event_id uuid)
returns void language plpgsql security definer set search_path=public as $$
declare
    v_uid uuid := (select auth.uid());
    v_resource public.group_resources; v_can boolean;
begin
    if v_uid is null then raise exception 'auth_required' using errcode='42501'; end if;
    select * into v_resource from public.group_resources where id=p_event_id and resource_type='event';
    if not found then raise exception 'event_not_found' using errcode='42704'; end if;
    if v_resource.archived_at is not null then raise exception 'event_already_archived' using errcode='22023'; end if;
    v_can := public.has_group_permission(v_resource.group_id,'events.archive') or public._event_is_host(p_event_id);
    if not v_can then raise exception 'missing_permission: events.archive' using errcode='42501'; end if;

    update public.group_resources set archived_at=now(), status='archived', updated_at=now() where id=p_event_id;
    perform public.record_system_event(
        v_resource.group_id, 'resource.archived', 'resource', p_event_id, v_resource.name,
        jsonb_build_object('resource_kind','event'));
end$$;

-- 4.5 list_group_events
create function public.list_group_events(
    p_group_id uuid, p_from timestamptz default null, p_to timestamptz default null,
    p_include_cancelled boolean default false, p_include_archived boolean default false
) returns table(
    id uuid, group_id uuid, title text, description text, event_type text,
    starts_at timestamptz, ends_at timestamptz, timezone text,
    location_name text, location_address text, location_url text,
    recurrence_rule text, recurrence_parent_id uuid,
    visibility text, status text, metadata jsonb,
    created_by uuid, created_at timestamptz, archived_at timestamptz,
    attendee_count integer, accepted_count integer,
    my_rsvp_status text, my_attendee_role text
) language sql stable security definer set search_path=public as $$
    with caller_mem as (
        select id as membership_id from public.group_memberships
        where group_id=p_group_id and user_id=(select auth.uid()) and status='active' limit 1
    ),
    base as (
        select r.id, r.group_id, r.name as title, r.description,
            coalesce(r.metadata->>'event_subtype','other') as event_type,
            e.starts_at, e.ends_at, r.metadata->>'timezone' as timezone,
            e.location as location_name, r.metadata->>'location_address' as location_address,
            r.metadata->>'location_url' as location_url,
            r.metadata->>'recurrence_rule' as recurrence_rule,
            null::uuid as recurrence_parent_id,
            coalesce(r.metadata->>'event_visibility','group') as visibility,
            public._event_derived_status(r.archived_at, e.cancelled_at, e.closed_at) as status,
            r.metadata, r.created_by, r.created_at, r.archived_at,
            coalesce(r.metadata->'event_roster','[]'::jsonb) as roster
        from public.group_resources r
        join public.group_resource_events e on e.resource_id=r.id
        where r.group_id=p_group_id and r.resource_type='event'
          and public.is_group_member(p_group_id)
    )
    select
        b.id, b.group_id, b.title, b.description, b.event_type,
        b.starts_at, b.ends_at, b.timezone,
        b.location_name, b.location_address, b.location_url,
        b.recurrence_rule, b.recurrence_parent_id,
        b.visibility, b.status, b.metadata,
        b.created_by, b.created_at, b.archived_at,
        coalesce(att.total,0)::integer as attendee_count,
        coalesce(att.accepted,0)::integer as accepted_count,
        my.rsvp_status as my_rsvp_status,
        roster_self.role as my_attendee_role
    from base b
    left join lateral (
        with rm as (
            select (e->>'membership_id')::uuid as membership_id
            from jsonb_array_elements(b.roster) e
            where e ? 'membership_id'
        ),
        rl as (
            select distinct on (a.membership_id) a.membership_id, a.rsvp_status
            from public.group_rsvp_actions a
            where a.resource_id=b.id
            order by a.membership_id, a.acted_at desc, a.id desc
        ),
        am as (select membership_id from rm union select membership_id from rl)
        select count(distinct am.membership_id) as total,
               count(distinct am.membership_id) filter (where rl.rsvp_status='accepted') as accepted
        from am left join rl on rl.membership_id=am.membership_id
    ) att on true
    left join lateral (
        select distinct on (a.membership_id) a.rsvp_status
        from public.group_rsvp_actions a, caller_mem cm
        where a.resource_id=b.id and a.membership_id=cm.membership_id
        order by a.membership_id, a.acted_at desc, a.id desc limit 1
    ) my on true
    left join lateral (
        select e->>'role' as role
        from jsonb_array_elements(b.roster) e, caller_mem cm
        where (e->>'membership_id')::uuid=cm.membership_id limit 1
    ) roster_self on true
    where (p_from is null or b.starts_at>=p_from)
      and (p_to is null or b.starts_at<=p_to)
      and (p_include_cancelled or b.status<>'cancelled')
      and (p_include_archived or b.status<>'archived')
      and (
          b.visibility in ('group','public_link')
       or (b.visibility='invited' and (roster_self.role is not null or my.rsvp_status is not null))
       or (b.visibility='admins' and public.has_group_permission(p_group_id,'events.update'))
       or b.created_by=(select auth.uid())
       or public.has_group_permission(p_group_id,'events.update')
       or public.has_group_permission(p_group_id,'events.cancel')
      )
    order by b.starts_at asc, b.created_at asc;
$$;

-- 4.6 get_event_detail
create function public.get_event_detail(p_event_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare
    v_uid uuid := (select auth.uid());
    v_resource public.group_resources; v_event public.group_resource_events;
    v_membership_id uuid; v_attendees jsonb; v_reminders jsonb; v_perms jsonb;
    v_visibility text; v_status text; v_visible boolean;
    v_can_update boolean; v_can_cancel boolean; v_can_archive boolean;
    v_can_manage_att boolean; v_can_manage_rem boolean; v_can_rsvp boolean;
    v_event_out jsonb;
begin
    if v_uid is null then raise exception 'auth_required' using errcode='42501'; end if;
    select * into v_resource from public.group_resources where id=p_event_id and resource_type='event';
    if not found then raise exception 'event_not_found' using errcode='42704'; end if;
    if not public.is_group_member(v_resource.group_id) then raise exception 'not_a_member' using errcode='42501'; end if;
    select * into v_event from public.group_resource_events where resource_id=p_event_id;

    v_membership_id := public._event_caller_membership(v_resource.group_id);
    v_visibility := coalesce(v_resource.metadata->>'event_visibility','group');
    v_status := public._event_derived_status(v_resource.archived_at, v_event.cancelled_at, v_event.closed_at);

    v_can_update := public.has_group_permission(v_resource.group_id,'events.update') or public._event_is_host(p_event_id);
    v_can_cancel := public.has_group_permission(v_resource.group_id,'events.cancel') or public._event_is_host(p_event_id);
    v_can_archive := public.has_group_permission(v_resource.group_id,'events.archive') or public._event_is_host(p_event_id);
    v_can_manage_att := public.has_group_permission(v_resource.group_id,'events.manage_attendees') or public._event_is_host(p_event_id);
    v_can_manage_rem := public.has_group_permission(v_resource.group_id,'events.manage_reminders') or public._event_is_host(p_event_id);
    v_can_rsvp := public.has_group_permission(v_resource.group_id,'events.rsvp');

    v_visible := v_visibility in ('group','public_link') or v_can_update or v_can_cancel
        or v_resource.created_by=v_uid
        or (v_visibility='invited' and exists (
            select 1 from jsonb_array_elements(coalesce(v_resource.metadata->'event_roster','[]'::jsonb)) e
            where (e->>'membership_id')::uuid=v_membership_id))
        or (v_visibility='admins' and v_can_update);
    if not v_visible then raise exception 'event_not_visible' using errcode='42501'; end if;

    v_attendees := public._event_attendees_json(p_event_id);
    v_reminders := public._event_reminders_json(p_event_id);
    v_perms := jsonb_build_object(
        'can_update', v_can_update, 'can_cancel', v_can_cancel, 'can_archive', v_can_archive,
        'can_manage_attendees', v_can_manage_att, 'can_manage_reminders', v_can_manage_rem,
        'can_rsvp', v_can_rsvp);

    v_event_out := jsonb_build_object(
        'id', v_resource.id, 'group_id', v_resource.group_id,
        'title', v_resource.name, 'description', v_resource.description,
        'event_type', coalesce(v_resource.metadata->>'event_subtype','other'),
        'starts_at', v_event.starts_at, 'ends_at', v_event.ends_at,
        'timezone', v_resource.metadata->>'timezone',
        'location_name', v_event.location,
        'location_address', v_resource.metadata->>'location_address',
        'location_url', v_resource.metadata->>'location_url',
        'recurrence_rule', v_resource.metadata->>'recurrence_rule',
        'recurrence_parent_id', null,
        'visibility', v_visibility, 'status', v_status,
        'metadata', v_resource.metadata,
        'created_by', v_resource.created_by,
        'created_at', v_resource.created_at,
        'updated_at', v_resource.updated_at,
        'archived_at', v_resource.archived_at);

    return jsonb_build_object(
        'event', v_event_out, 'attendees', v_attendees,
        'reminders', v_reminders, 'permissions', v_perms,
        'caller_membership_id', v_membership_id);
end$$;

-- 4.7 add_event_attendee
create function public.add_event_attendee(
    p_event_id uuid, p_membership_id uuid default null,
    p_invited_email text default null, p_invited_phone text default null,
    p_display_name text default null, p_role text default 'attendee'
) returns uuid language plpgsql security definer set search_path=public as $$
declare
    v_uid uuid := (select auth.uid());
    v_resource public.group_resources; v_event public.group_resource_events;
    v_status text; v_can boolean;
    v_roster jsonb; v_existing_id uuid; v_new_id uuid;
begin
    if v_uid is null then raise exception 'auth_required' using errcode='42501'; end if;
    select * into v_resource from public.group_resources where id=p_event_id and resource_type='event';
    if not found then raise exception 'event_not_found' using errcode='42704'; end if;
    select * into v_event from public.group_resource_events where resource_id=p_event_id;
    v_status := public._event_derived_status(v_resource.archived_at, v_event.cancelled_at, v_event.closed_at);
    if v_status in ('cancelled','archived') then raise exception 'event_is_terminal: %', v_status using errcode='22023'; end if;
    if p_membership_id is null and p_invited_email is null and p_invited_phone is null then
        raise exception 'attendee_target_required' using errcode='22023'; end if;
    v_can := public.has_group_permission(v_resource.group_id,'events.manage_attendees') or public._event_is_host(p_event_id);
    if not v_can then raise exception 'missing_permission: events.manage_attendees' using errcode='42501'; end if;
    if p_membership_id is not null and not exists (
        select 1 from public.group_memberships where id=p_membership_id and group_id=v_resource.group_id
    ) then raise exception 'membership_not_in_group' using errcode='22023'; end if;

    v_roster := coalesce(v_resource.metadata->'event_roster','[]'::jsonb);
    select (e->>'id')::uuid into v_existing_id
    from jsonb_array_elements(v_roster) e
    where (
        (p_membership_id is not null and (e->>'membership_id')::uuid=p_membership_id)
     or (p_membership_id is null and (
            (p_invited_email is not null and lower(coalesce(e->>'invited_email',''))=lower(p_invited_email))
         or (p_invited_phone is not null and coalesce(e->>'invited_phone','')=p_invited_phone)
        ))
    ) limit 1;
    if v_existing_id is not null then return v_existing_id; end if;

    v_new_id := gen_random_uuid();
    v_roster := v_roster || jsonb_build_array(jsonb_build_object(
        'id', v_new_id, 'membership_id', p_membership_id,
        'invited_email', p_invited_email, 'invited_phone', p_invited_phone,
        'display_name', p_display_name, 'role', coalesce(p_role,'attendee'),
        'added_at', now()));
    update public.group_resources
    set metadata = metadata || jsonb_build_object('event_roster', v_roster),
        updated_at = now()
    where id=p_event_id;

    perform public.record_system_event(
        v_resource.group_id, 'resource.attendee_added', 'resource', p_event_id, v_resource.name,
        jsonb_build_object('resource_kind','event','attendee_id', v_new_id,
            'membership_id', p_membership_id, 'invited_email', p_invited_email, 'role', p_role));
    return v_new_id;
end$$;

-- 4.8 remove_event_attendee (split SELECTs — no record+jsonb mixed INTO)
create function public.remove_event_attendee(p_event_attendee_id uuid)
returns void language plpgsql security definer set search_path=public as $$
declare
    v_uid uuid := (select auth.uid());
    v_resource_id uuid; v_entry jsonb;
    v_resource public.group_resources;
    v_remaining_hosts int; v_can boolean;
    v_new_roster jsonb; v_role text;
begin
    if v_uid is null then raise exception 'auth_required' using errcode='42501'; end if;

    -- Find which event-type resource holds this roster entry
    select r.id, e_entry into v_resource_id, v_entry
    from public.group_resources r,
         jsonb_array_elements(coalesce(r.metadata->'event_roster','[]'::jsonb)) e_entry
    where r.resource_type='event'
      and (e_entry->>'id')::uuid=p_event_attendee_id
    limit 1;
    if v_entry is null then raise exception 'attendee_not_found' using errcode='42704'; end if;

    select * into v_resource from public.group_resources where id=v_resource_id;

    v_can := public.has_group_permission(v_resource.group_id,'events.manage_attendees') or public._event_is_host(v_resource_id);
    if not v_can then raise exception 'missing_permission: events.manage_attendees' using errcode='42501'; end if;

    v_role := coalesce(v_entry->>'role','attendee');
    if v_role='host' then
        select count(*) into v_remaining_hosts
        from jsonb_array_elements(coalesce(v_resource.metadata->'event_roster','[]'::jsonb)) e
        where (e->>'role')='host' and (e->>'id')::uuid<>p_event_attendee_id;
        if v_remaining_hosts=0 then raise exception 'cannot_remove_last_host' using errcode='23514'; end if;
    end if;

    select coalesce(jsonb_agg(e),'[]'::jsonb) into v_new_roster
    from jsonb_array_elements(coalesce(v_resource.metadata->'event_roster','[]'::jsonb)) e
    where (e->>'id')::uuid<>p_event_attendee_id;

    update public.group_resources
    set metadata = metadata || jsonb_build_object('event_roster', v_new_roster),
        updated_at = now()
    where id=v_resource_id;

    perform public.record_system_event(
        v_resource.group_id, 'resource.attendee_removed', 'resource', v_resource_id, v_resource.name,
        jsonb_build_object('resource_kind','event','attendee_id', p_event_attendee_id,
            'membership_id', v_entry->>'membership_id','role', v_role));
end$$;

-- 4.9 respond_event
create function public.respond_event(
    p_event_id uuid, p_rsvp_status text, p_rsvp_note text default null
) returns uuid language plpgsql security definer set search_path=public as $$
declare
    v_uid uuid := (select auth.uid());
    v_resource public.group_resources; v_event public.group_resource_events;
    v_status text; v_visibility text; v_membership_id uuid;
    v_roster jsonb; v_roster_entry_id uuid; v_new_entry_id uuid;
begin
    if v_uid is null then raise exception 'auth_required' using errcode='42501'; end if;
    if p_rsvp_status not in ('pending','accepted','declined','tentative','maybe') then
        raise exception 'invalid_rsvp_status' using errcode='22023'; end if;
    select * into v_resource from public.group_resources where id=p_event_id and resource_type='event';
    if not found then raise exception 'event_not_found' using errcode='42704'; end if;
    select * into v_event from public.group_resource_events where resource_id=p_event_id;
    v_status := public._event_derived_status(v_resource.archived_at, v_event.cancelled_at, v_event.closed_at);
    if v_status in ('cancelled','archived') then raise exception 'event_is_terminal: %', v_status using errcode='22023'; end if;
    if not public.is_group_member(v_resource.group_id) then raise exception 'not_a_member' using errcode='42501'; end if;
    if not public.has_group_permission(v_resource.group_id,'events.rsvp') then
        raise exception 'missing_permission: events.rsvp' using errcode='42501'; end if;

    v_membership_id := public._event_caller_membership(v_resource.group_id);
    if v_membership_id is null then raise exception 'no_active_membership' using errcode='42501'; end if;

    v_visibility := coalesce(v_resource.metadata->>'event_visibility','group');
    v_roster := coalesce(v_resource.metadata->'event_roster','[]'::jsonb);
    select (e->>'id')::uuid into v_roster_entry_id
    from jsonb_array_elements(v_roster) e
    where (e->>'membership_id')::uuid=v_membership_id limit 1;

    if v_roster_entry_id is null and v_visibility in ('invited','admins') then
        raise exception 'not_invited' using errcode='42501';
    end if;

    if v_roster_entry_id is null then
        v_new_entry_id := gen_random_uuid();
        v_roster := v_roster || jsonb_build_array(jsonb_build_object(
            'id', v_new_entry_id, 'membership_id', v_membership_id,
            'role', 'attendee', 'added_at', now()));
        update public.group_resources
        set metadata = metadata || jsonb_build_object('event_roster', v_roster), updated_at = now()
        where id=p_event_id;
        v_roster_entry_id := v_new_entry_id;
    end if;

    insert into public.group_rsvp_actions (
        group_id, resource_id, membership_id, user_id, rsvp_status, note, source, acted_at
    ) values (v_resource.group_id, p_event_id, v_membership_id, v_uid, p_rsvp_status, p_rsvp_note, 'self', now());

    perform public.record_system_event(
        v_resource.group_id, 'resource.rsvp_updated', 'resource', p_event_id, v_resource.name,
        jsonb_build_object('resource_kind','event','attendee_id', v_roster_entry_id,
            'membership_id', v_membership_id, 'rsvp_status', p_rsvp_status));
    return v_roster_entry_id;
end$$;

-- 4.10 add_event_reminder
create function public.add_event_reminder(
    p_event_id uuid, p_reminder_type text default 'push',
    p_offset_minutes integer default 60, p_target text default 'attendees',
    p_target_membership_id uuid default null
) returns uuid language plpgsql security definer set search_path=public as $$
declare
    v_uid uuid := (select auth.uid());
    v_resource public.group_resources; v_event public.group_resource_events;
    v_status text; v_can boolean;
    v_cap_id uuid; v_config jsonb;
    v_new_id uuid := gen_random_uuid(); v_entry jsonb;
begin
    if v_uid is null then raise exception 'auth_required' using errcode='42501'; end if;
    select * into v_resource from public.group_resources where id=p_event_id and resource_type='event';
    if not found then raise exception 'event_not_found' using errcode='42704'; end if;
    select * into v_event from public.group_resource_events where resource_id=p_event_id;
    v_status := public._event_derived_status(v_resource.archived_at, v_event.cancelled_at, v_event.closed_at);
    if v_status in ('cancelled','archived') then raise exception 'event_is_terminal: %', v_status using errcode='22023'; end if;
    if p_offset_minutes is null or p_offset_minutes<0 then raise exception 'invalid_offset_minutes' using errcode='22023'; end if;
    v_can := public.has_group_permission(v_resource.group_id,'events.manage_reminders') or public._event_is_host(p_event_id);
    if not v_can then raise exception 'missing_permission: events.manage_reminders' using errcode='42501'; end if;

    select id, config into v_cap_id, v_config
    from public.group_resource_capabilities where resource_id=p_event_id and capability_key='reminders';

    v_entry := jsonb_build_object(
        'id', v_new_id, 'reminder_type', coalesce(p_reminder_type,'push'),
        'offset_minutes', p_offset_minutes, 'target', coalesce(p_target,'attendees'),
        'target_membership_id', case when p_target='specific_membership' then p_target_membership_id else null end,
        'created_at', now());

    if v_cap_id is null then
        insert into public.group_resource_capabilities (resource_id, capability_key, enabled, config, enabled_by)
        values (p_event_id, 'reminders', true,
                jsonb_build_object('reminders', jsonb_build_array(v_entry)), v_uid);
    else
        update public.group_resource_capabilities
        set config = jsonb_set(coalesce(config,'{}'::jsonb), '{reminders}',
                coalesce(config->'reminders','[]'::jsonb) || jsonb_build_array(v_entry), true),
            enabled = true, updated_at = now()
        where id=v_cap_id;
    end if;

    perform public.record_system_event(
        v_resource.group_id, 'resource.reminder_added', 'resource', p_event_id, v_resource.name,
        jsonb_build_object('resource_kind','event','reminder_id', v_new_id,
            'reminder_type', p_reminder_type, 'offset_minutes', p_offset_minutes, 'target', p_target));
    return v_new_id;
end$$;

-- 4.11 remove_event_reminder
create function public.remove_event_reminder(p_reminder_id uuid)
returns void language plpgsql security definer set search_path=public as $$
declare
    v_uid uuid := (select auth.uid());
    v_resource public.group_resources;
    v_cap_id uuid; v_resource_id uuid; v_cap_config jsonb;
    v_can boolean; v_new_reminders jsonb;
begin
    if v_uid is null then raise exception 'auth_required' using errcode='42501'; end if;
    select c.id, c.resource_id, c.config into v_cap_id, v_resource_id, v_cap_config
    from public.group_resource_capabilities c,
         jsonb_array_elements(coalesce(c.config->'reminders','[]'::jsonb)) r
    where c.capability_key='reminders' and (r->>'id')::uuid=p_reminder_id
    limit 1;
    if v_cap_id is null then raise exception 'reminder_not_found' using errcode='42704'; end if;

    select * into v_resource from public.group_resources where id=v_resource_id;
    v_can := public.has_group_permission(v_resource.group_id,'events.manage_reminders') or public._event_is_host(v_resource_id);
    if not v_can then raise exception 'missing_permission: events.manage_reminders' using errcode='42501'; end if;

    select coalesce(jsonb_agg(r),'[]'::jsonb) into v_new_reminders
    from jsonb_array_elements(coalesce(v_cap_config->'reminders','[]'::jsonb)) r
    where (r->>'id')::uuid<>p_reminder_id;

    update public.group_resource_capabilities
    set config = jsonb_set(coalesce(config,'{}'::jsonb), '{reminders}', v_new_reminders, true),
        updated_at = now()
    where id=v_cap_id;

    perform public.record_system_event(
        v_resource.group_id, 'resource.reminder_removed', 'resource', v_resource_id, v_resource.name,
        jsonb_build_object('resource_kind','event','reminder_id', p_reminder_id));
end$$;

-- 5. Read-model view
drop view if exists public.group_event_calendar_view;
create view public.group_event_calendar_view as
select r.id, r.group_id, r.name as title, r.description,
    coalesce(r.metadata->>'event_subtype','other') as event_type,
    e.starts_at, e.ends_at, r.metadata->>'timezone' as timezone,
    e.location as location_name, r.metadata->>'location_address' as location_address,
    e.location_geo, e.host_membership_id, e.rsvp_deadline, e.check_in_window, e.capacity,
    e.cancelled_at, e.closed_at, r.metadata->>'recurrence_rule' as recurrence_rule,
    r.series_id, coalesce(r.metadata->>'event_visibility','group') as visibility,
    public._event_derived_status(r.archived_at, e.cancelled_at, e.closed_at) as status,
    r.created_by, r.created_at, r.archived_at, r.metadata
from public.group_resources r
join public.group_resource_events e on e.resource_id=r.id
where r.resource_type='event';

grant select on public.group_event_calendar_view to authenticated;

-- 6. Grants
grant execute on function public.create_event(uuid, text, text, text, timestamptz, timestamptz, text, text, text, text, text, text, jsonb) to authenticated;
grant execute on function public.update_event(uuid, text, text, text, timestamptz, timestamptz, text, text, text, text, text, text, jsonb) to authenticated;
grant execute on function public.cancel_event(uuid, text) to authenticated;
grant execute on function public.archive_event(uuid) to authenticated;
grant execute on function public.list_group_events(uuid, timestamptz, timestamptz, boolean, boolean) to authenticated;
grant execute on function public.get_event_detail(uuid) to authenticated;
grant execute on function public.add_event_attendee(uuid, uuid, text, text, text, text) to authenticated;
grant execute on function public.remove_event_attendee(uuid) to authenticated;
grant execute on function public.respond_event(uuid, text, text) to authenticated;
grant execute on function public.add_event_reminder(uuid, text, integer, text, uuid) to authenticated;
grant execute on function public.remove_event_reminder(uuid) to authenticated;
