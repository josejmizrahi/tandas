-- d23_calendar_events_profile_fix
-- Reconstruido desde supabase_migrations.schema_migrations (live DB wyvkqveienzixinonhum)
-- en R.1 para restaurar la replicabilidad del repo (drift fix: la sesion original
-- aplico esta migration via MCP pero no commiteo el archivo al repo).

-- D.23 hot-fix: profiles schema uses `id` PK (1:1 with auth.users) and
-- has no `full_name`. Adjust get_event_detail to join correctly.

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
        'display_name', coalesce(a.display_name, p.display_name, p.username),
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
    left join public.profiles p on p.id = gm.user_id
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
