-- 00341 — Fan out event_invitation notifications to non-host members
-- when the host self-confirms (rsvpSubmitted with via='auto_host_confirm').
--
-- Chain
-- =====
-- create_event_v2 / auto-generate-events → INSERT resources(event)
--   → trg_auto_rsvp_host_going (mig 00340) → INSERT rsvp_actions(via=auto_host_confirm)
--   → trg_on_rsvp_action_emit_system_event (mig 00337/00339) → INSERT system_event(rsvpSubmitted, payload.via=auto_host_confirm)
--   → trg_fanout_event_invitation (THIS mig) → INSERT notifications_outbox per non-host member
--   → cron dispatch-notifications-every-minute → APNs push

create or replace function public.fanout_event_invitation_on_host_confirm()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_resource         public.resources;
  v_host_member_id   uuid;
  v_host_display     text;
  v_title            text;
  v_starts_at        text;
  v_location_name    text;
  v_cover_url        text;
  v_payload          jsonb;
  v_count            int := 0;
begin
  -- Outer guard: only react to host-driven rsvpSubmitted atoms.
  if NEW.event_type <> 'rsvpSubmitted' then return NEW; end if;
  if (NEW.payload->>'via') <> 'auto_host_confirm' then return NEW; end if;

  v_host_member_id := NEW.member_id;
  if v_host_member_id is null then return NEW; end if;

  -- Resolve the event for cover, title, location for the notification payload.
  select * into v_resource from public.resources where id = NEW.resource_id;
  if not found or v_resource.resource_type <> 'event' then return NEW; end if;

  v_title         := v_resource.metadata->>'title';
  v_starts_at     := v_resource.metadata->>'starts_at';
  v_location_name := v_resource.metadata->>'location_name';
  v_cover_url     := v_resource.metadata->>'cover_image_url';

  -- Host display name for the notification copy.
  select coalesce(p.display_name, 'Tu anfitrión')
    into v_host_display
    from public.group_members gm
    join public.profiles p on p.id = gm.user_id
   where gm.id = v_host_member_id;

  v_payload := jsonb_strip_nulls(jsonb_build_object(
    'event_id',       NEW.resource_id,
    'title',          coalesce(v_title, 'Evento'),
    'starts_at',      v_starts_at,
    'location_name',  v_location_name,
    'cover_image_url', v_cover_url,
    'host_member_id', v_host_member_id,
    'host_display',   v_host_display
  ));

  -- Fan out one notifications_outbox row per active group member ≠ host.
  -- Dedup per (recipient_member_id, notification_type, event_id) so a
  -- re-fire of rsvpSubmitted doesn't double-notify.
  for v_count in
    insert into public.notifications_outbox (
      group_id,
      recipient_member_id,
      notification_type,
      payload,
      deep_link,
      scheduled_for
    )
    select
      NEW.group_id,
      gm.id,
      'event_invitation',
      v_payload,
      'ruul://event/' || NEW.resource_id::text || '/invitation',
      now()
    from public.group_members gm
    where gm.group_id = NEW.group_id
      and gm.active   = true
      and gm.id       <> v_host_member_id
      and not exists (
        select 1 from public.notifications_outbox o
         where o.recipient_member_id = gm.id
           and o.notification_type   = 'event_invitation'
           and (o.payload->>'event_id') = NEW.resource_id::text
      )
    returning 1
  loop end loop;

  return NEW;
end;
$$;

revoke execute on function public.fanout_event_invitation_on_host_confirm() from public, anon;
grant  execute on function public.fanout_event_invitation_on_host_confirm() to authenticated, service_role;

drop trigger if exists trg_fanout_event_invitation on public.system_events;
create trigger trg_fanout_event_invitation
  after insert on public.system_events
  for each row
  when (NEW.event_type = 'rsvpSubmitted')
  execute function public.fanout_event_invitation_on_host_confirm();

comment on function public.fanout_event_invitation_on_host_confirm() is
  'mig 00341: fans out event_invitation notifications to non-host group members when the host self-confirms (rsvpSubmitted with via=auto_host_confirm). Deduped per (recipient, event). Consumed by dispatch-notifications-every-minute cron for APNs delivery; iOS opens InvitationView via ruul://event/{id}/invitation deeplink.';;
