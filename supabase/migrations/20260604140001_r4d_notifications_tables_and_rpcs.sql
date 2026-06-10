-- =============================================================================
-- R.4D · notifications + notification_deliveries + actor_inbox_items
-- =============================================================================
-- Additive. attention_inbox() stays untouched for iOS back-compat.
-- New RPCs:
--   emit_notification(...)           — SECDEF write helper
--   mark_notification_read(...)      — SECDEF, recipient-only
--   mark_notification_archived(...)  — SECDEF, recipient-only
--   mark_all_notifications_read(...) — SECDEF, recipient-only batch
--   actor_inbox_items(...)           — SECDEF unified inbox (superset of
--                                       attention_inbox + RSVP-pending +
--                                       unread notifications)
-- =============================================================================

-- 1. notifications ---------------------------------------------------------
create table if not exists public.notifications (
  id                  uuid primary key default gen_random_uuid(),
  recipient_actor_id  uuid not null references public.actors(id) on delete cascade,
  context_actor_id    uuid references public.actors(id) on delete set null,
  notification_type   text not null,
  title               text not null,
  body                text,
  target_type         text,
  target_id           uuid,
  status              text not null default 'unread'
    check (status in ('unread','read','archived')),
  metadata            jsonb not null default '{}'::jsonb,
  created_at          timestamptz not null default now(),
  read_at             timestamptz
);

comment on table public.notifications is
  'R.4D: outbound notifications targeted at an actor. status moves unread→read→archived. target_(type|id) point to the underlying entity (decision, obligation, event, …).';

create index if not exists idx_notifications_recipient_status
  on public.notifications(recipient_actor_id, status, created_at desc);
create index if not exists idx_notifications_target
  on public.notifications(target_type, target_id)
  where target_id is not null;

drop trigger if exists notifications_set_read_at on public.notifications;
create or replace function public._notifications_touch_read_at()
returns trigger language plpgsql as $$
begin
  if new.status = 'read' and old.status <> 'read' and new.read_at is null then
    new.read_at := now();
  end if;
  return new;
end;
$$;
create trigger notifications_set_read_at
  before update on public.notifications
  for each row execute function public._notifications_touch_read_at();

alter table public.notifications enable row level security;

drop policy if exists "notifications_read_own" on public.notifications;
create policy "notifications_read_own"
  on public.notifications
  for select
  to authenticated, service_role
  using (recipient_actor_id = public.current_actor_id());

revoke all on public.notifications from anon;
grant select on public.notifications to authenticated, service_role;

-- 2. notification_deliveries -----------------------------------------------
create table if not exists public.notification_deliveries (
  id                uuid primary key default gen_random_uuid(),
  notification_id   uuid not null references public.notifications(id) on delete cascade,
  channel           text not null
    check (channel in ('in_app','email','push','sms','whatsapp')),
  status            text not null default 'pending'
    check (status in ('pending','sent','delivered','failed','suppressed')),
  provider_response jsonb not null default '{}'::jsonb,
  created_at        timestamptz not null default now(),
  delivered_at      timestamptz
);

comment on table public.notification_deliveries is
  'R.4D: per-channel delivery record for a notification. in_app rows are emitted alongside the notification itself by emit_notification(); push/email/sms providers fill in status+delivered_at via future webhooks.';

create index if not exists idx_notification_deliveries_notification
  on public.notification_deliveries(notification_id);

alter table public.notification_deliveries enable row level security;

drop policy if exists "notification_deliveries_read_own" on public.notification_deliveries;
create policy "notification_deliveries_read_own"
  on public.notification_deliveries
  for select
  to authenticated, service_role
  using (
    exists (select 1 from public.notifications n
            where n.id = notification_id
              and n.recipient_actor_id = public.current_actor_id())
  );

revoke all on public.notification_deliveries from anon;
grant select on public.notification_deliveries to authenticated, service_role;

-- =============================================================================
-- 3. emit_notification — internal helper used by future hooks + smoke
-- =============================================================================
create or replace function public.emit_notification(
  p_recipient_actor_id uuid,
  p_notification_type  text,
  p_title              text,
  p_body               text default null,
  p_context_actor_id   uuid default null,
  p_target_type        text default null,
  p_target_id          uuid default null,
  p_metadata           jsonb default '{}'::jsonb,
  p_channels           text[] default array['in_app']
) returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_id uuid;
  v_channel text;
begin
  if p_recipient_actor_id is null then
    raise exception 'recipient_actor_id required' using errcode = '22023';
  end if;
  if coalesce(btrim(p_notification_type), '') = '' then
    raise exception 'notification_type required' using errcode = '22023';
  end if;
  if coalesce(btrim(p_title), '') = '' then
    raise exception 'title required' using errcode = '22023';
  end if;

  insert into public.notifications
    (recipient_actor_id, context_actor_id, notification_type, title, body,
     target_type, target_id, metadata)
  values
    (p_recipient_actor_id, p_context_actor_id, p_notification_type,
     btrim(p_title), p_body, p_target_type, p_target_id,
     coalesce(p_metadata, '{}'::jsonb))
  returning id into v_id;

  -- Materialize one delivery row per requested channel.
  if p_channels is not null then
    foreach v_channel in array p_channels loop
      insert into public.notification_deliveries(notification_id, channel,
        status, delivered_at)
      values (v_id, v_channel,
              case when v_channel = 'in_app' then 'delivered' else 'pending' end,
              case when v_channel = 'in_app' then now() else null end);
    end loop;
  end if;

  return jsonb_build_object('notification_id', v_id);
end;
$$;

revoke all on function public.emit_notification(uuid, text, text, text, uuid, text, uuid, jsonb, text[]) from anon;
grant execute on function public.emit_notification(uuid, text, text, text, uuid, text, uuid, jsonb, text[])
  to authenticated, service_role;

-- =============================================================================
-- 4. mark_notification_read / _archived / _all_read
-- =============================================================================
create or replace function public.mark_notification_read(p_notification_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_n public.notifications%rowtype;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  select * into v_n from public.notifications where id = p_notification_id;
  if v_n.id is null then
    raise exception 'notification not found' using errcode = 'P0002';
  end if;
  if v_n.recipient_actor_id <> v_caller then
    raise exception 'not authorized' using errcode = '42501';
  end if;
  if v_n.status = 'read' then
    return jsonb_build_object('notification_id', p_notification_id, 'status', 'read', 'already_read', true);
  end if;
  update public.notifications set status = 'read' where id = p_notification_id;
  return jsonb_build_object('notification_id', p_notification_id, 'status', 'read');
end;
$$;

create or replace function public.mark_notification_archived(p_notification_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_n public.notifications%rowtype;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  select * into v_n from public.notifications where id = p_notification_id;
  if v_n.id is null then
    raise exception 'notification not found' using errcode = 'P0002';
  end if;
  if v_n.recipient_actor_id <> v_caller then
    raise exception 'not authorized' using errcode = '42501';
  end if;
  update public.notifications set status = 'archived' where id = p_notification_id;
  return jsonb_build_object('notification_id', p_notification_id, 'status', 'archived');
end;
$$;

create or replace function public.mark_all_notifications_read(p_context_actor_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_count int;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  update public.notifications
     set status = 'read'
   where recipient_actor_id = v_caller
     and status = 'unread'
     and (p_context_actor_id is null or context_actor_id = p_context_actor_id);
  get diagnostics v_count = row_count;
  return jsonb_build_object('marked_read', v_count);
end;
$$;

revoke all on function public.mark_notification_read(uuid) from anon;
revoke all on function public.mark_notification_archived(uuid) from anon;
revoke all on function public.mark_all_notifications_read(uuid) from anon;
grant execute on function public.mark_notification_read(uuid) to authenticated, service_role;
grant execute on function public.mark_notification_archived(uuid) to authenticated, service_role;
grant execute on function public.mark_all_notifications_read(uuid) to authenticated, service_role;

-- =============================================================================
-- 5. actor_inbox_items — unified inbox (superset of attention_inbox)
-- =============================================================================
-- Returns a JSONB array with canonical item shape:
--   { kind, subject_id, context_actor_id, context_display_name,
--     title, reason, cta_action_key, cta_scope_kind, cta_scope_id, occurred_at,
--     metadata? }
--
-- Kinds emitted:
--   reservation_conflict | decision_vote | obligation_pay | obligation_complete
--   invitation | rsvp_pending | notification
-- =============================================================================
create or replace function public.actor_inbox_items(
  p_actor_id uuid default null,
  p_limit    int  default 50,
  p_include_read boolean default false
) returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth
as $$
declare
  v_actor uuid := coalesce(p_actor_id, public.current_actor_id());
  v_items jsonb := '[]'::jsonb;
begin
  if v_actor is null then
    raise exception 'unauthenticated' using errcode = '28000';
  end if;
  -- Only the actor themselves (or service_role) can read their inbox.
  if v_actor <> public.current_actor_id() then
    raise exception 'not authorized to read another actor inbox' using errcode = '42501';
  end if;

  -- reservation_conflict
  v_items := v_items || coalesce((
    select jsonb_agg(jsonb_build_object(
      'kind', 'reservation_conflict',
      'subject_id', c.id,
      'context_actor_id', r.context_actor_id,
      'context_display_name', (select display_name from public.actors where id = r.context_actor_id),
      'title', 'Conflicto de reservación',
      'reason', 'Hay reservaciones que se solapan en un recurso donde participas',
      'cta_action_key', 'resolve_conflict',
      'cta_scope_kind', 'reservation',
      'cta_scope_id', r.id,
      'occurred_at', c.created_at
    ))
    from public.reservation_conflicts c
    join public.resource_reservations r
      on r.id = c.reservation_a_id or r.id = c.reservation_b_id
    where c.resolution_status = 'open'
      and (r.requested_by_actor_id = v_actor or r.reserved_for_actor_id = v_actor)
  ), '[]'::jsonb);

  -- decision_vote
  v_items := v_items || coalesce((
    select jsonb_agg(jsonb_build_object(
      'kind', 'decision_vote',
      'subject_id', d.id,
      'context_actor_id', d.context_actor_id,
      'context_display_name', (select display_name from public.actors where id = d.context_actor_id),
      'title', d.title,
      'reason', 'Decisión abierta donde puedes votar',
      'cta_action_key', 'vote',
      'cta_scope_kind', 'decision',
      'cta_scope_id', d.id,
      'occurred_at', d.created_at
    ))
    from public.decisions d
    where d.status = 'open'
      and public.has_actor_authority(d.context_actor_id, v_actor, 'decisions.vote')
      and not exists (
        select 1 from public.decision_votes dv
        where dv.decision_id = d.id and dv.voter_actor_id = v_actor
      )
  ), '[]'::jsonb);

  -- obligation_pay / obligation_complete
  v_items := v_items || coalesce((
    select jsonb_agg(jsonb_build_object(
      'kind', case when o.obligation_kind = 'money' then 'obligation_pay' else 'obligation_complete' end,
      'subject_id', o.id,
      'context_actor_id', o.context_actor_id,
      'context_display_name', (select display_name from public.actors where id = o.context_actor_id),
      'title', coalesce(o.title, 'Compromiso pendiente'),
      'reason', case when o.obligation_kind = 'money' then 'Tienes un pago pendiente'
                     else 'Tienes un compromiso pendiente' end,
      'cta_action_key', case when o.obligation_kind = 'money' then 'pay' else 'mark_completed' end,
      'cta_scope_kind', 'obligation',
      'cta_scope_id', o.id,
      'occurred_at', o.created_at
    ))
    from public.obligations o
    where o.status = 'open' and o.debtor_actor_id = v_actor
  ), '[]'::jsonb);

  -- invitation (pending memberships)
  v_items := v_items || coalesce((
    select jsonb_agg(jsonb_build_object(
      'kind', 'invitation',
      'subject_id', m.id,
      'context_actor_id', m.context_actor_id,
      'context_display_name', (select display_name from public.actors where id = m.context_actor_id),
      'title', 'Invitación pendiente',
      'reason', 'Te invitaron a un contexto',
      'cta_action_key', 'accept_invitation',
      'cta_scope_kind', 'context',
      'cta_scope_id', m.context_actor_id,
      'occurred_at', m.created_at
    ))
    from public.actor_memberships m
    where m.member_actor_id = v_actor and m.membership_status = 'invited'
  ), '[]'::jsonb);

  -- rsvp_pending (event_participants.status='invited' and event in the future)
  v_items := v_items || coalesce((
    select jsonb_agg(jsonb_build_object(
      'kind', 'rsvp_pending',
      'subject_id', ep.id,
      'context_actor_id', e.context_actor_id,
      'context_display_name', (select display_name from public.actors where id = e.context_actor_id),
      'title', e.title,
      'reason', 'Tienes una invitación a un evento sin responder',
      'cta_action_key', 'rsvp',
      'cta_scope_kind', 'event',
      'cta_scope_id', e.id,
      'occurred_at', coalesce(ep.metadata->>'invited_at', e.created_at::text)::timestamptz
    ))
    from public.event_participants ep
    join public.calendar_events e on e.id = ep.event_id
    where ep.participant_actor_id = v_actor
      and ep.status = 'invited'
      and (e.starts_at is null or e.starts_at > now())
  ), '[]'::jsonb);

  -- notification (in-app unread, optionally including read)
  v_items := v_items || coalesce((
    select jsonb_agg(jsonb_build_object(
      'kind', 'notification',
      'subject_id', n.id,
      'context_actor_id', n.context_actor_id,
      'context_display_name', case when n.context_actor_id is not null
        then (select display_name from public.actors where id = n.context_actor_id)
        else null end,
      'title', n.title,
      'reason', coalesce(n.body, ''),
      'cta_action_key', 'open_notification',
      'cta_scope_kind', coalesce(n.target_type, 'notification'),
      'cta_scope_id', coalesce(n.target_id, n.id),
      'occurred_at', n.created_at,
      'metadata', jsonb_build_object(
        'notification_type', n.notification_type,
        'status', n.status,
        'read_at', n.read_at
      )
    ))
    from public.notifications n
    where n.recipient_actor_id = v_actor
      and n.status <> 'archived'
      and (p_include_read or n.status = 'unread')
  ), '[]'::jsonb);

  return coalesce((
    select jsonb_agg(item)
    from (
      select item
      from jsonb_array_elements(v_items) item
      order by (item->>'occurred_at')::timestamptz desc nulls last
      limit greatest(coalesce(p_limit, 50), 1)
    ) sorted
  ), '[]'::jsonb);
end;
$$;

revoke all on function public.actor_inbox_items(uuid, int, boolean) from anon;
grant execute on function public.actor_inbox_items(uuid, int, boolean) to authenticated, service_role;
