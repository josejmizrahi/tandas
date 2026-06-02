-- d23_calendar_events_primitive
-- Reconstruido desde supabase_migrations.schema_migrations (live DB wyvkqveienzixinonhum)
-- en R.1 para restaurar la replicabilidad del repo (drift fix: la sesion original
-- aplico esta migration via MCP pero no commiteo el archivo al repo).

-- =====================================================================
-- V3-D.23 — Calendar Event primitive
--
-- Goal: introduce calendar events (scheduled occurrences) as a first-class
-- primitive separate from the existing `group_events` audit log.
--
-- Tables (new):
--   group_calendar_events           — the event itself (single or recurring)
--   group_calendar_event_attendees  — invitees + RSVP state
--   group_calendar_event_reminders  — basic reminders
--
-- Audit log: continues to be `public.group_events`, accessed via
-- `record_system_event(group_id, event_type, entity_kind, entity_id, ...)`.
-- For this primitive: entity_kind = 'calendar_event'; event_type =
-- 'calendar_event.{created|updated|cancelled|archived|attendee_added|attendee_removed|rsvp_updated|reminder_added|reminder_removed}'.
--
-- Permissions (new keys in `events` category):
--   events.read, events.create, events.update, events.archive,
--   events.cancel, events.manage_attendees, events.rsvp,
--   events.manage_reminders
--
-- Per-group seeding (all 3 system roles):
--   founder: all 8 perms
--   admin:   read, create, update, cancel, manage_attendees, manage_reminders, rsvp
--   member:  read, rsvp
--
-- RPCs:
--   create_event, update_event, cancel_event, archive_event,
--   list_group_events, get_event_detail,
--   add_event_attendee, remove_event_attendee, respond_event,
--   add_event_reminder, remove_event_reminder
--
-- Decisions/governance linkage: keep door open via reference_kind='calendar_event'
-- on group_decisions (no CHECK constraint to add — column is free-form text).
--
-- Recurrence: stored as opaque RRULE-ish text in `recurrence_rule`. The
-- parent row appears in list_group_events whenever its start_at falls
-- inside the requested range. No engine expansion in this phase.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Tables
-- ---------------------------------------------------------------------

create table if not exists public.group_calendar_events (
    id uuid primary key default gen_random_uuid(),
    group_id uuid not null references public.groups(id) on delete cascade,
    title text not null check (length(btrim(title)) > 0),
    description text,
    event_type text not null default 'social'
        check (event_type in (
            'social','meal','meeting_candidate','ceremony',
            'work_session','deadline','maintenance','trip','ritual','other'
        )),
    starts_at timestamptz not null,
    ends_at timestamptz,
    timezone text,
    location_name text,
    location_address text,
    location_url text,
    recurrence_rule text,
    recurrence_parent_id uuid references public.group_calendar_events(id) on delete set null,
    visibility text not null default 'group'
        check (visibility in ('group','invited','admins','public_link')),
    status text not null default 'scheduled'
        check (status in ('scheduled','cancelled','completed','archived')),
    created_by uuid references auth.users(id),
    metadata jsonb not null default '{}'::jsonb,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    archived_at timestamptz,
    constraint group_calendar_events_ends_after_starts
        check (ends_at is null or ends_at >= starts_at)
);

create index if not exists group_calendar_events_group_idx
    on public.group_calendar_events(group_id);
create index if not exists group_calendar_events_starts_at_idx
    on public.group_calendar_events(starts_at);
create index if not exists group_calendar_events_group_starts_idx
    on public.group_calendar_events(group_id, starts_at);
create index if not exists group_calendar_events_status_idx
    on public.group_calendar_events(status);
create index if not exists group_calendar_events_recurrence_parent_idx
    on public.group_calendar_events(recurrence_parent_id)
    where recurrence_parent_id is not null;

create or replace function public._touch_calendar_event_updated_at()
returns trigger language plpgsql as $$
begin
    new.updated_at = now();
    return new;
end;
$$;

drop trigger if exists group_calendar_events_touch_updated_at on public.group_calendar_events;
create trigger group_calendar_events_touch_updated_at
    before update on public.group_calendar_events
    for each row execute function public._touch_calendar_event_updated_at();

create table if not exists public.group_calendar_event_attendees (
    id uuid primary key default gen_random_uuid(),
    event_id uuid not null references public.group_calendar_events(id) on delete cascade,
    membership_id uuid references public.group_memberships(id) on delete set null,
    invited_email text,
    invited_phone text,
    display_name text,
    role text not null default 'attendee'
        check (role in ('host','cohost','attendee','optional','observer')),
    rsvp_status text not null default 'pending'
        check (rsvp_status in ('pending','accepted','declined','tentative','maybe')),
    rsvp_note text,
    responded_at timestamptz,
    created_at timestamptz not null default now(),
    constraint group_calendar_event_attendees_has_target
        check (
            membership_id is not null
         or invited_email is not null
         or invited_phone is not null
        )
);

create unique index if not exists group_calendar_event_attendees_unique_membership
    on public.group_calendar_event_attendees(event_id, membership_id)
    where membership_id is not null;
create unique index if not exists group_calendar_event_attendees_unique_email
    on public.group_calendar_event_attendees(event_id, lower(invited_email))
    where invited_email is not null and membership_id is null;
create unique index if not exists group_calendar_event_attendees_unique_phone
    on public.group_calendar_event_attendees(event_id, invited_phone)
    where invited_phone is not null and membership_id is null;
create index if not exists group_calendar_event_attendees_event_idx
    on public.group_calendar_event_attendees(event_id);

create table if not exists public.group_calendar_event_reminders (
    id uuid primary key default gen_random_uuid(),
    event_id uuid not null references public.group_calendar_events(id) on delete cascade,
    reminder_type text not null default 'push'
        check (reminder_type in ('push','email','sms','inbox','noop')),
    offset_minutes integer not null check (offset_minutes >= 0),
    target text not null default 'attendees'
        check (target in ('attendees','hosts','all_members','specific_membership')),
    target_membership_id uuid references public.group_memberships(id) on delete cascade,
    created_at timestamptz not null default now()
);

create index if not exists group_calendar_event_reminders_event_idx
    on public.group_calendar_event_reminders(event_id);

-- ---------------------------------------------------------------------
-- 2. Permissions catalog + per-group role seeding
-- ---------------------------------------------------------------------

insert into public.permissions (key, description, category) values
    ('events.read',              'Leer eventos del grupo (segun visibility)', 'events'),
    ('events.create',            'Crear eventos del grupo',                   'events'),
    ('events.update',            'Editar eventos (host, admin o permiso)',    'events'),
    ('events.archive',           'Archivar eventos',                          'events'),
    ('events.cancel',            'Cancelar eventos',                          'events'),
    ('events.manage_attendees',  'Invitar/quitar asistentes',                 'events'),
    ('events.rsvp',              'Responder al propio RSVP',                  'events'),
    ('events.manage_reminders',  'Crear/quitar recordatorios',                'events')
on conflict (key) do nothing;

-- Seed perms onto every existing group's 3 system roles.
do $$
declare
    v_role record;
    v_founder text[] := array[
        'events.read','events.create','events.update','events.archive',
        'events.cancel','events.manage_attendees','events.rsvp','events.manage_reminders'
    ];
    v_admin text[] := array[
        'events.read','events.create','events.update',
        'events.cancel','events.manage_attendees','events.manage_reminders','events.rsvp'
    ];
    v_member text[] := array[
        'events.read','events.rsvp'
    ];
    v_perms text[];
    v_perm text;
begin
    for v_role in
        select id, key from public.group_roles where key in ('founder','admin','member')
    loop
        v_perms := case v_role.key
            when 'founder' then v_founder
            when 'admin'   then v_admin
            when 'member'  then v_member
        end;
        foreach v_perm in array v_perms loop
            insert into public.group_role_permissions(role_id, permission_key)
            values (v_role.id, v_perm)
            on conflict do nothing;
        end loop;
    end loop;
end$$;

-- ---------------------------------------------------------------------
-- 3. RLS
-- ---------------------------------------------------------------------

alter table public.group_calendar_events            enable row level security;
alter table public.group_calendar_event_attendees   enable row level security;
alter table public.group_calendar_event_reminders   enable row level security;

drop policy if exists "calendar_events_read" on public.group_calendar_events;
create policy "calendar_events_read" on public.group_calendar_events
    for select to authenticated using (
        public.is_group_member(group_id)
        and (
            visibility in ('group','public_link')
         or (
                visibility = 'invited' and exists (
                    select 1 from public.group_calendar_event_attendees a
                    join public.group_memberships gm on gm.id = a.membership_id
                    where a.event_id = group_calendar_events.id
                      and gm.user_id = (select auth.uid())
                      and gm.status  = 'active'
                )
            )
         or (
                visibility = 'admins' and public.has_group_permission(group_id, 'events.update')
            )
         or public.has_group_permission(group_id, 'events.update')
         or public.has_group_permission(group_id, 'events.cancel')
         or public.has_group_permission(group_id, 'events.archive')
        )
    );

drop policy if exists "calendar_event_attendees_read" on public.group_calendar_event_attendees;
create policy "calendar_event_attendees_read" on public.group_calendar_event_attendees
    for select to authenticated using (
        exists (
            select 1 from public.group_calendar_events e
            where e.id = group_calendar_event_attendees.event_id
              and public.is_group_member(e.group_id)
        )
    );

drop policy if exists "calendar_event_reminders_read" on public.group_calendar_event_reminders;
create policy "calendar_event_reminders_read" on public.group_calendar_event_reminders
    for select to authenticated using (
        exists (
            select 1 from public.group_calendar_events e
            where e.id = group_calendar_event_reminders.event_id
              and public.is_group_member(e.group_id)
        )
    );

-- Writes all go through SECURITY DEFINER RPCs; deny direct DML.

-- ---------------------------------------------------------------------
-- 4. RPCs
-- ---------------------------------------------------------------------

-- Helper: current active membership id for the caller in a group.
create or replace function public._calendar_event_caller_membership(p_group_id uuid)
returns uuid
language sql
stable
security definer
set search_path = public
as $$
    select id from public.group_memberships
    where group_id = p_group_id
      and user_id  = (select auth.uid())
      and status   = 'active'
    limit 1;
$$;

-- Helper: does the caller have write/manage auth on this specific event?
-- True when caller is host/cohost OR has events.update OR events.cancel
-- (depending on context, callers check the appropriate perm).
create or replace function public._calendar_event_is_host(p_event_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
    select exists (
        select 1
        from public.group_calendar_event_attendees a
        join public.group_memberships gm on gm.id = a.membership_id
        where a.event_id = p_event_id
          and a.role in ('host','cohost')
          and gm.user_id = (select auth.uid())
          and gm.status  = 'active'
    );
$$;

-- 4.1 — create_event
create or replace function public.create_event(
    p_group_id uuid,
    p_title text,
    p_description text default null,
    p_event_type text default 'social',
    p_starts_at timestamptz default null,
    p_ends_at timestamptz default null,
    p_timezone text default null,
    p_location_name text default null,
    p_location_address text default null,
    p_location_url text default null,
    p_recurrence_rule text default null,
    p_visibility text default 'group',
    p_metadata jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
    v_event_id uuid;
    v_membership_id uuid;
    v_uid uuid := (select auth.uid());
begin
    if v_uid is null then
        raise exception 'auth_required' using errcode = '42501';
    end if;
    if not public.is_group_member(p_group_id) then
        raise exception 'not_a_member' using errcode = '42501';
    end if;
    if not public.has_group_permission(p_group_id, 'events.create') then
        raise exception 'missing_permission: events.create' using errcode = '42501';
    end if;
    if p_title is null or length(btrim(p_title)) = 0 then
        raise exception 'title_required' using errcode = '22023';
    end if;
    if p_starts_at is null then
        raise exception 'starts_at_required' using errcode = '22023';
    end if;
    if p_ends_at is not null and p_ends_at < p_starts_at then
        raise exception 'ends_before_starts' using errcode = '22023';
    end if;

    insert into public.group_calendar_events (
        group_id, title, description, event_type, starts_at, ends_at,
        timezone, location_name, location_address, location_url,
        recurrence_rule, visibility, metadata, created_by
    ) values (
        p_group_id, btrim(p_title), p_description, p_event_type, p_starts_at, p_ends_at,
        p_timezone, p_location_name, p_location_address, p_location_url,
        p_recurrence_rule, p_visibility, coalesce(p_metadata, '{}'::jsonb), v_uid
    ) returning id into v_event_id;

    v_membership_id := public._calendar_event_caller_membership(p_group_id);
    if v_membership_id is not null then
        insert into public.group_calendar_event_attendees (
            event_id, membership_id, role, rsvp_status, responded_at
        ) values (
            v_event_id, v_membership_id, 'host', 'accepted', now()
        )
        on conflict do nothing;
    end if;

    perform public.record_system_event(
        p_group_id,
        'calendar_event.created',
        'calendar_event',
        v_event_id,
        btrim(p_title),
        jsonb_build_object(
            'event_type', p_event_type,
            'starts_at', p_starts_at,
            'visibility', p_visibility,
            'recurring', p_recurrence_rule is not null
        )
    );

    return v_event_id;
end;
$$;

-- 4.2 — update_event
create or replace function public.update_event(
    p_event_id uuid,
    p_title text default null,
    p_description text default null,
    p_event_type text default null,
    p_starts_at timestamptz default null,
    p_ends_at timestamptz default null,
    p_timezone text default null,
    p_location_name text default null,
    p_location_address text default null,
    p_location_url text default null,
    p_recurrence_rule text default null,
    p_visibility text default null,
    p_metadata jsonb default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
    v_event public.group_calendar_events;
    v_uid uuid := (select auth.uid());
    v_can_update boolean;
begin
    if v_uid is null then
        raise exception 'auth_required' using errcode = '42501';
    end if;
    select * into v_event from public.group_calendar_events where id = p_event_id;
    if not found then
        raise exception 'event_not_found' using errcode = '42704';
    end if;
    if v_event.status in ('cancelled','archived') then
        raise exception 'event_is_terminal: %', v_event.status using errcode = '22023';
    end if;

    v_can_update :=
        public.has_group_permission(v_event.group_id, 'events.update')
     or public._calendar_event_is_host(p_event_id);
    if not v_can_update then
        raise exception 'missing_permission: events.update' using errcode = '42501';
    end if;

    update public.group_calendar_events
    set title             = coalesce(nullif(btrim(p_title), ''), title),
        description       = coalesce(p_description, description),
        event_type        = coalesce(p_event_type, event_type),
        starts_at         = coalesce(p_starts_at, starts_at),
        ends_at           = coalesce(p_ends_at, ends_at),
        timezone          = coalesce(p_timezone, timezone),
        location_name     = coalesce(p_location_name, location_name),
        location_address  = coalesce(p_location_address, location_address),
        location_url      = coalesce(p_location_url, location_url),
        recurrence_rule   = coalesce(p_recurrence_rule, recurrence_rule),
        visibility        = coalesce(p_visibility, visibility),
        metadata          = case when p_metadata is null then metadata else metadata || p_metadata end
    where id = p_event_id;

    perform public.record_system_event(
        v_event.group_id,
        'calendar_event.updated',
        'calendar_event',
        p_event_id,
        coalesce(nullif(btrim(p_title), ''), v_event.title),
        jsonb_build_object('updated_fields', jsonb_strip_nulls(jsonb_build_object(
            'title', p_title, 'description', p_description, 'event_type', p_event_type,
            'starts_at', p_starts_at, 'ends_at', p_ends_at, 'visibility', p_visibility,
            'recurrence_rule', p_recurrence_rule, 'location_name', p_location_name
        )))
    );
end;
$$;

-- 4.3 — cancel_event
create or replace function public.cancel_event(
    p_event_id uuid,
    p_reason text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
    v_event public.group_calendar_events;
    v_uid uuid := (select auth.uid());
    v_can boolean;
begin
    if v_uid is null then
        raise exception 'auth_required' using errcode = '42501';
    end if;
    select * into v_event from public.group_calendar_events where id = p_event_id;
    if not found then
        raise exception 'event_not_found' using errcode = '42704';
    end if;
    if v_event.status in ('cancelled','archived') then
        raise exception 'event_is_terminal: %', v_event.status using errcode = '22023';
    end if;
    v_can :=
        public.has_group_permission(v_event.group_id, 'events.cancel')
     or public._calendar_event_is_host(p_event_id);
    if not v_can then
        raise exception 'missing_permission: events.cancel' using errcode = '42501';
    end if;

    update public.group_calendar_events
    set status   = 'cancelled',
        metadata = metadata || jsonb_build_object('cancel_reason', p_reason)
    where id = p_event_id;

    perform public.record_system_event(
        v_event.group_id,
        'calendar_event.cancelled',
        'calendar_event',
        p_event_id,
        v_event.title,
        jsonb_build_object('reason', p_reason)
    );
end;
$$;

-- 4.4 — archive_event
create or replace function public.archive_event(p_event_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
    v_event public.group_calendar_events;
    v_uid uuid := (select auth.uid());
    v_can boolean;
begin
    if v_uid is null then
        raise exception 'auth_required' using errcode = '42501';
    end if;
    select * into v_event from public.group_calendar_events where id = p_event_id;
    if not found then
        raise exception 'event_not_found' using errcode = '42704';
    end if;
    if v_event.status = 'archived' then
        raise exception 'event_already_archived' using errcode = '22023';
    end if;
    v_can :=
        public.has_group_permission(v_event.group_id, 'events.archive')
     or public._calendar_event_is_host(p_event_id);
    if not v_can then
        raise exception 'missing_permission: events.archive' using errcode = '42501';
    end if;

    update public.group_calendar_events
    set status      = 'archived',
        archived_at = now()
    where id = p_event_id;

    perform public.record_system_event(
        v_event.group_id,
        'calendar_event.archived',
        'calendar_event',
        p_event_id,
        v_event.title,
        '{}'::jsonb
    );
end;
$$;

-- 4.5 — list_group_events
create or replace function public.list_group_events(
    p_group_id uuid,
    p_from timestamptz default null,
    p_to timestamptz default null,
    p_include_cancelled boolean default false,
    p_include_archived boolean default false
)
returns table(
    id uuid,
    group_id uuid,
    title text,
    description text,
    event_type text,
    starts_at timestamptz,
    ends_at timestamptz,
    timezone text,
    location_name text,
    location_address text,
    location_url text,
    recurrence_rule text,
    recurrence_parent_id uuid,
    visibility text,
    status text,
    metadata jsonb,
    created_by uuid,
    created_at timestamptz,
    archived_at timestamptz,
    attendee_count integer,
    accepted_count integer,
    my_rsvp_status text,
    my_attendee_role text
)
language sql
stable
security definer
set search_path = public
as $$
    with caller_mem as (
        select id as membership_id
        from public.group_memberships
        where group_id = p_group_id
          and user_id  = (select auth.uid())
          and status   = 'active'
        limit 1
    )
    select
        e.id, e.group_id, e.title, e.description, e.event_type,
        e.starts_at, e.ends_at, e.timezone,
        e.location_name, e.location_address, e.location_url,
        e.recurrence_rule, e.recurrence_parent_id,
        e.visibility, e.status, e.metadata, e.created_by, e.created_at, e.archived_at,
        coalesce(att_counts.total, 0)::integer        as attendee_count,
        coalesce(att_counts.accepted, 0)::integer     as accepted_count,
        my_rsvp.rsvp_status                           as my_rsvp_status,
        my_rsvp.role                                  as my_attendee_role
    from public.group_calendar_events e
    left join lateral (
        select
            count(*) filter (where true) as total,
            count(*) filter (where rsvp_status = 'accepted') as accepted
        from public.group_calendar_event_attendees a
        where a.event_id = e.id
    ) att_counts on true
    left join lateral (
        select rsvp_status, role
        from public.group_calendar_event_attendees a
        join caller_mem cm on cm.membership_id = a.membership_id
        where a.event_id = e.id
        limit 1
    ) my_rsvp on true
    where e.group_id = p_group_id
      and (
          public.is_group_member(p_group_id)
      )
      and (p_from is null or e.starts_at >= p_from)
      and (p_to   is null or e.starts_at <= p_to)
      and (p_include_cancelled or e.status <> 'cancelled')
      and (p_include_archived  or e.status <> 'archived')
      and (
          e.visibility in ('group','public_link')
       or (
            e.visibility = 'invited' and my_rsvp.rsvp_status is not null
          )
       or (
            e.visibility = 'admins' and public.has_group_permission(p_group_id, 'events.update')
          )
       or e.created_by = (select auth.uid())
       or public.has_group_permission(p_group_id, 'events.update')
       or public.has_group_permission(p_group_id, 'events.cancel')
      )
    order by e.starts_at asc, e.created_at asc;
$$;

-- 4.6 — get_event_detail
create or replace function public.get_event_detail(p_event_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
    v_event public.group_calendar_events;
    v_uid uuid := (select auth.uid());
    v_membership_id uuid;
    v_attendees jsonb;
    v_reminders jsonb;
    v_perms jsonb;
    v_visible boolean;
    v_can_update boolean;
    v_can_cancel boolean;
    v_can_archive boolean;
    v_can_manage_att boolean;
    v_can_manage_rem boolean;
    v_can_rsvp boolean;
begin
    if v_uid is null then
        raise exception 'auth_required' using errcode = '42501';
    end if;
    select * into v_event from public.group_calendar_events where id = p_event_id;
    if not found then
        raise exception 'event_not_found' using errcode = '42704';
    end if;
    if not public.is_group_member(v_event.group_id) then
        raise exception 'not_a_member' using errcode = '42501';
    end if;

    v_membership_id := public._calendar_event_caller_membership(v_event.group_id);

    v_can_update     := public.has_group_permission(v_event.group_id, 'events.update')
                     or public._calendar_event_is_host(p_event_id);
    v_can_cancel     := public.has_group_permission(v_event.group_id, 'events.cancel')
                     or public._calendar_event_is_host(p_event_id);
    v_can_archive    := public.has_group_permission(v_event.group_id, 'events.archive')
                     or public._calendar_event_is_host(p_event_id);
    v_can_manage_att := public.has_group_permission(v_event.group_id, 'events.manage_attendees')
                     or public._calendar_event_is_host(p_event_id);
    v_can_manage_rem := public.has_group_permission(v_event.group_id, 'events.manage_reminders')
                     or public._calendar_event_is_host(p_event_id);
    v_can_rsvp       := public.has_group_permission(v_event.group_id, 'events.rsvp');

    v_visible :=
        v_event.visibility in ('group','public_link')
     or v_can_update or v_can_cancel
     or v_event.created_by = v_uid
     or (
            v_event.visibility = 'invited' and exists (
                select 1 from public.group_calendar_event_attendees a
                where a.event_id = p_event_id
                  and a.membership_id = v_membership_id
            )
        )
     or (v_event.visibility = 'admins' and v_can_update);

    if not v_visible then
        raise exception 'event_not_visible' using errcode = '42501';
    end if;

    select coalesce(jsonb_agg(jsonb_build_object(
        'id', a.id,
        'membership_id', a.membership_id,
        'invited_email', a.invited_email,
        'invited_phone', a.invited_phone,
        'display_name', coalesce(a.display_name, p.display_name, p.full_name),
        'role', a.role,
        'rsvp_status', a.rsvp_status,
        'rsvp_note', a.rsvp_note,
        'responded_at', a.responded_at,
        'created_at', a.created_at,
        'user_id', gm.user_id
    ) order by
        case a.role when 'host' then 0 when 'cohost' then 1 when 'attendee' then 2 when 'optional' then 3 else 4 end,
        a.created_at
    ), '[]'::jsonb)
    into v_attendees
    from public.group_calendar_event_attendees a
    left join public.group_memberships gm on gm.id = a.membership_id
    left join public.profiles p on p.user_id = gm.user_id
    where a.event_id = p_event_id;

    select coalesce(jsonb_agg(jsonb_build_object(
        'id', r.id,
        'reminder_type', r.reminder_type,
        'offset_minutes', r.offset_minutes,
        'target', r.target,
        'target_membership_id', r.target_membership_id,
        'created_at', r.created_at
    ) order by r.offset_minutes desc), '[]'::jsonb)
    into v_reminders
    from public.group_calendar_event_reminders r
    where r.event_id = p_event_id;

    v_perms := jsonb_build_object(
        'can_update',           v_can_update,
        'can_cancel',           v_can_cancel,
        'can_archive',          v_can_archive,
        'can_manage_attendees', v_can_manage_att,
        'can_manage_reminders', v_can_manage_rem,
        'can_rsvp',             v_can_rsvp
    );

    return jsonb_build_object(
        'event', to_jsonb(v_event),
        'attendees', v_attendees,
        'reminders', v_reminders,
        'permissions', v_perms,
        'caller_membership_id', v_membership_id
    );
end;
$$;

-- 4.7 — add_event_attendee
create or replace function public.add_event_attendee(
    p_event_id uuid,
    p_membership_id uuid default null,
    p_invited_email text default null,
    p_invited_phone text default null,
    p_display_name text default null,
    p_role text default 'attendee'
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
    v_event public.group_calendar_events;
    v_uid uuid := (select auth.uid());
    v_attendee_id uuid;
    v_can boolean;
begin
    if v_uid is null then
        raise exception 'auth_required' using errcode = '42501';
    end if;
    select * into v_event from public.group_calendar_events where id = p_event_id;
    if not found then
        raise exception 'event_not_found' using errcode = '42704';
    end if;
    if v_event.status in ('cancelled','archived') then
        raise exception 'event_is_terminal: %', v_event.status using errcode = '22023';
    end if;
    if p_membership_id is null and p_invited_email is null and p_invited_phone is null then
        raise exception 'attendee_target_required' using errcode = '22023';
    end if;
    v_can :=
        public.has_group_permission(v_event.group_id, 'events.manage_attendees')
     or public._calendar_event_is_host(p_event_id);
    if not v_can then
        raise exception 'missing_permission: events.manage_attendees' using errcode = '42501';
    end if;

    if p_membership_id is not null then
        if not exists (
            select 1 from public.group_memberships
            where id = p_membership_id and group_id = v_event.group_id
        ) then
            raise exception 'membership_not_in_group' using errcode = '22023';
        end if;
    end if;

    insert into public.group_calendar_event_attendees (
        event_id, membership_id, invited_email, invited_phone, display_name, role
    ) values (
        p_event_id, p_membership_id, p_invited_email, p_invited_phone, p_display_name, coalesce(p_role, 'attendee')
    )
    on conflict do nothing
    returning id into v_attendee_id;

    if v_attendee_id is null then
        select id into v_attendee_id from public.group_calendar_event_attendees
        where event_id = p_event_id
          and (membership_id is not distinct from p_membership_id)
          and (lower(coalesce(invited_email,'')) = lower(coalesce(p_invited_email,'')))
          and (coalesce(invited_phone,'') = coalesce(p_invited_phone,''))
        limit 1;
    end if;

    perform public.record_system_event(
        v_event.group_id,
        'calendar_event.attendee_added',
        'calendar_event',
        p_event_id,
        v_event.title,
        jsonb_build_object(
            'attendee_id', v_attendee_id,
            'membership_id', p_membership_id,
            'invited_email', p_invited_email,
            'role', p_role
        )
    );

    return v_attendee_id;
end;
$$;

-- 4.8 — remove_event_attendee
create or replace function public.remove_event_attendee(p_event_attendee_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
    v_att public.group_calendar_event_attendees;
    v_event public.group_calendar_events;
    v_uid uuid := (select auth.uid());
    v_can boolean;
    v_remaining_hosts integer;
begin
    if v_uid is null then
        raise exception 'auth_required' using errcode = '42501';
    end if;
    select * into v_att from public.group_calendar_event_attendees where id = p_event_attendee_id;
    if not found then
        raise exception 'attendee_not_found' using errcode = '42704';
    end if;
    select * into v_event from public.group_calendar_events where id = v_att.event_id;
    v_can :=
        public.has_group_permission(v_event.group_id, 'events.manage_attendees')
     or public._calendar_event_is_host(v_att.event_id);
    if not v_can then
        raise exception 'missing_permission: events.manage_attendees' using errcode = '42501';
    end if;

    if v_att.role = 'host' then
        select count(*) into v_remaining_hosts
        from public.group_calendar_event_attendees
        where event_id = v_att.event_id and role = 'host' and id <> p_event_attendee_id;
        if v_remaining_hosts = 0 then
            raise exception 'cannot_remove_last_host' using errcode = '23514';
        end if;
    end if;

    delete from public.group_calendar_event_attendees where id = p_event_attendee_id;

    perform public.record_system_event(
        v_event.group_id,
        'calendar_event.attendee_removed',
        'calendar_event',
        v_att.event_id,
        v_event.title,
        jsonb_build_object(
            'attendee_id', p_event_attendee_id,
            'membership_id', v_att.membership_id,
            'role', v_att.role
        )
    );
end;
$$;

-- 4.9 — respond_event (own RSVP)
create or replace function public.respond_event(
    p_event_id uuid,
    p_rsvp_status text,
    p_rsvp_note text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
    v_event public.group_calendar_events;
    v_uid uuid := (select auth.uid());
    v_membership_id uuid;
    v_attendee_id uuid;
begin
    if v_uid is null then
        raise exception 'auth_required' using errcode = '42501';
    end if;
    if p_rsvp_status not in ('pending','accepted','declined','tentative','maybe') then
        raise exception 'invalid_rsvp_status' using errcode = '22023';
    end if;
    select * into v_event from public.group_calendar_events where id = p_event_id;
    if not found then
        raise exception 'event_not_found' using errcode = '42704';
    end if;
    if v_event.status in ('cancelled','archived') then
        raise exception 'event_is_terminal: %', v_event.status using errcode = '22023';
    end if;
    if not public.is_group_member(v_event.group_id) then
        raise exception 'not_a_member' using errcode = '42501';
    end if;
    if not public.has_group_permission(v_event.group_id, 'events.rsvp') then
        raise exception 'missing_permission: events.rsvp' using errcode = '42501';
    end if;

    v_membership_id := public._calendar_event_caller_membership(v_event.group_id);
    if v_membership_id is null then
        raise exception 'no_active_membership' using errcode = '42501';
    end if;

    -- Auto-create attendee row for group-visible events if missing.
    select id into v_attendee_id
    from public.group_calendar_event_attendees
    where event_id = p_event_id and membership_id = v_membership_id;

    if v_attendee_id is null then
        if v_event.visibility in ('invited','admins') then
            raise exception 'not_invited' using errcode = '42501';
        end if;
        insert into public.group_calendar_event_attendees (
            event_id, membership_id, role, rsvp_status, rsvp_note, responded_at
        ) values (
            p_event_id, v_membership_id, 'attendee', p_rsvp_status, p_rsvp_note, now()
        )
        returning id into v_attendee_id;
    else
        update public.group_calendar_event_attendees
        set rsvp_status = p_rsvp_status,
            rsvp_note   = coalesce(p_rsvp_note, rsvp_note),
            responded_at = now()
        where id = v_attendee_id;
    end if;

    perform public.record_system_event(
        v_event.group_id,
        'calendar_event.rsvp_updated',
        'calendar_event',
        p_event_id,
        v_event.title,
        jsonb_build_object(
            'attendee_id', v_attendee_id,
            'membership_id', v_membership_id,
            'rsvp_status', p_rsvp_status
        )
    );

    return v_attendee_id;
end;
$$;

-- 4.10 — add_event_reminder
create or replace function public.add_event_reminder(
    p_event_id uuid,
    p_reminder_type text default 'push',
    p_offset_minutes integer default 60,
    p_target text default 'attendees',
    p_target_membership_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
    v_event public.group_calendar_events;
    v_uid uuid := (select auth.uid());
    v_reminder_id uuid;
    v_can boolean;
begin
    if v_uid is null then
        raise exception 'auth_required' using errcode = '42501';
    end if;
    select * into v_event from public.group_calendar_events where id = p_event_id;
    if not found then
        raise exception 'event_not_found' using errcode = '42704';
    end if;
    if v_event.status in ('cancelled','archived') then
        raise exception 'event_is_terminal: %', v_event.status using errcode = '22023';
    end if;
    if p_offset_minutes is null or p_offset_minutes < 0 then
        raise exception 'invalid_offset_minutes' using errcode = '22023';
    end if;
    v_can :=
        public.has_group_permission(v_event.group_id, 'events.manage_reminders')
     or public._calendar_event_is_host(p_event_id);
    if not v_can then
        raise exception 'missing_permission: events.manage_reminders' using errcode = '42501';
    end if;

    insert into public.group_calendar_event_reminders (
        event_id, reminder_type, offset_minutes, target, target_membership_id
    ) values (
        p_event_id, coalesce(p_reminder_type, 'push'),
        p_offset_minutes, coalesce(p_target, 'attendees'),
        case when p_target = 'specific_membership' then p_target_membership_id else null end
    )
    returning id into v_reminder_id;

    perform public.record_system_event(
        v_event.group_id,
        'calendar_event.reminder_added',
        'calendar_event',
        p_event_id,
        v_event.title,
        jsonb_build_object(
            'reminder_id', v_reminder_id,
            'reminder_type', p_reminder_type,
            'offset_minutes', p_offset_minutes,
            'target', p_target
        )
    );

    return v_reminder_id;
end;
$$;

-- 4.11 — remove_event_reminder
create or replace function public.remove_event_reminder(p_reminder_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
    v_rem public.group_calendar_event_reminders;
    v_event public.group_calendar_events;
    v_uid uuid := (select auth.uid());
    v_can boolean;
begin
    if v_uid is null then
        raise exception 'auth_required' using errcode = '42501';
    end if;
    select * into v_rem from public.group_calendar_event_reminders where id = p_reminder_id;
    if not found then
        raise exception 'reminder_not_found' using errcode = '42704';
    end if;
    select * into v_event from public.group_calendar_events where id = v_rem.event_id;
    v_can :=
        public.has_group_permission(v_event.group_id, 'events.manage_reminders')
     or public._calendar_event_is_host(v_rem.event_id);
    if not v_can then
        raise exception 'missing_permission: events.manage_reminders' using errcode = '42501';
    end if;

    delete from public.group_calendar_event_reminders where id = p_reminder_id;

    perform public.record_system_event(
        v_event.group_id,
        'calendar_event.reminder_removed',
        'calendar_event',
        v_rem.event_id,
        v_event.title,
        jsonb_build_object('reminder_id', p_reminder_id)
    );
end;
$$;

-- ---------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------

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
