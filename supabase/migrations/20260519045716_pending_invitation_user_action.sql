-- 00342 — Extend the host-confirm fan-out to also emit
-- `user_actions(pendingInvitation)` per non-host member so the iOS
-- Inbox can render Instagram-style cards with inline Aceptar /
-- Ahora no buttons. notifications_outbox still drives the APNs push
-- + the full-screen InvitationView when tapped from cold; the
-- user_action drives the in-app inbox surface.
--
-- Dedup per (recipient_user_id, action_type, reference_id) so a
-- re-fire of rsvpSubmitted doesn't double-add cards. Auto-resolves
-- via a separate trigger when the recipient actually RSVPs (see
-- on_rsvp_action_resolve_pending_invitation below).

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
  v_user_payload     jsonb;
  v_body             text;
begin
  if NEW.event_type <> 'rsvpSubmitted' then return NEW; end if;
  if (NEW.payload->>'via') <> 'auto_host_confirm' then return NEW; end if;

  v_host_member_id := NEW.member_id;
  if v_host_member_id is null then return NEW; end if;

  select * into v_resource from public.resources where id = NEW.resource_id;
  if not found or v_resource.resource_type <> 'event' then return NEW; end if;

  v_title         := v_resource.metadata->>'title';
  v_starts_at     := v_resource.metadata->>'starts_at';
  v_location_name := v_resource.metadata->>'location_name';
  v_cover_url     := v_resource.metadata->>'cover_image_url';

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

  -- 1. APNs push queue — drives cold-tap InvitationView.
  insert into public.notifications_outbox (
    group_id, recipient_member_id, notification_type, payload, deep_link, scheduled_for
  )
  select NEW.group_id, gm.id, 'event_invitation', v_payload,
         'ruul://event/' || NEW.resource_id::text || '/invitation', now()
  from public.group_members gm
  where gm.group_id = NEW.group_id
    and gm.active   = true
    and gm.id       <> v_host_member_id
    and not exists (
      select 1 from public.notifications_outbox o
       where o.recipient_member_id = gm.id
         and o.notification_type   = 'event_invitation'
         and (o.payload->>'event_id') = NEW.resource_id::text
    );

  -- 2. user_actions(pendingInvitation) — drives the in-app Inbox card
  -- with inline Aceptar / Ahora no buttons. user_id (auth.users.id) is
  -- the inbox row owner; we look it up from group_members.
  v_user_payload := jsonb_build_object(
    'event_id',       NEW.resource_id,
    'host_display',   v_host_display,
    'host_member_id', v_host_member_id,
    'title',          coalesce(v_title, 'Evento'),
    'starts_at',      v_starts_at,
    'location_name',  v_location_name,
    'cover_image_url', v_cover_url
  );
  v_body := coalesce(v_host_display, 'Tu anfitrión') || ' confirmó. ¿Vas?';

  insert into public.user_actions (
    user_id, group_id, action_type, reference_id, title, body, priority
  )
  select gm.user_id, NEW.group_id, 'pendingInvitation', NEW.resource_id,
         coalesce(v_title, 'Evento'), v_body, 'medium'
  from public.group_members gm
  where gm.group_id = NEW.group_id
    and gm.active   = true
    and gm.id       <> v_host_member_id
    and not exists (
      select 1 from public.user_actions ua
       where ua.user_id     = gm.user_id
         and ua.action_type = 'pendingInvitation'
         and ua.reference_id = NEW.resource_id
    );

  return NEW;
end;
$$;

-- Auto-resolve the pendingInvitation card when the recipient actually
-- RSVPs (going or declined). Trigger fires on rsvp_actions INSERT.
create or replace function public.resolve_pending_invitation_on_rsvp()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid;
begin
  -- via='auto_host_confirm' is the host's own auto-RSVP — don't try to
  -- resolve cards (host doesn't have a pendingInvitation for their
  -- own event).
  if (NEW.metadata->>'via') = 'auto_host_confirm' then return NEW; end if;

  select user_id into v_user_id
    from public.group_members
   where id = NEW.member_id
   limit 1;
  if v_user_id is null then return NEW; end if;

  update public.user_actions
     set resolved_at = now()
   where user_id     = v_user_id
     and action_type = 'pendingInvitation'
     and reference_id = NEW.resource_id
     and resolved_at is null;

  return NEW;
end;
$$;

drop trigger if exists trg_resolve_pending_invitation_on_rsvp on public.rsvp_actions;
create trigger trg_resolve_pending_invitation_on_rsvp
  after insert on public.rsvp_actions
  for each row
  execute function public.resolve_pending_invitation_on_rsvp();

comment on function public.fanout_event_invitation_on_host_confirm() is
  'mig 00342: emits BOTH notifications_outbox (APNs push for full-screen InvitationView) AND user_actions(pendingInvitation) (in-app Inbox card with inline Aceptar/Ahora no).';
comment on function public.resolve_pending_invitation_on_rsvp() is
  'mig 00342: auto-resolves the pendingInvitation card when the recipient submits any non-auto RSVP. Idempotent — only updates rows where resolved_at IS NULL.';;
