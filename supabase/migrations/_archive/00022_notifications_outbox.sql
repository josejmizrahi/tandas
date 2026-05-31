-- 00022 — notifications_outbox: auditable record of every push the system
-- intends to dispatch.
--
-- Why an outbox:
--   - Today `send-event-notification` only console.logs in V1 (APNs not yet
--     wired). Without a queryable record, we can't assert in E2E tests that
--     the right people got notified at the right times.
--   - Once APNs is wired, the outbox becomes the dispatch queue: rows
--     marked dispatch_status='pending' are picked up + sent + marked
--     'sent' (or 'failed' with an error). Standard transactional outbox
--     pattern — push delivery doesn't get lost if the function dies.
--   - In production debugging "no me llegó la notif" becomes a SQL query
--     instead of grepping logs.
--
-- Lifecycle:
--   pending  → row created, not yet dispatched
--   sent     → APNs accepted (or in V1 stub: marked sent immediately)
--   failed   → APNs rejected; error captured in dispatch_error
--   skipped  → recipient has no token / muted notifications
--
-- Order matters: this migration runs before 00023_appeal_voting_v2.sql,
-- which adds outbox writes inside start_vote() / finalize_vote().

create table if not exists public.notifications_outbox (
  id                    uuid primary key default gen_random_uuid(),
  group_id              uuid not null references public.groups(id) on delete cascade,
  recipient_member_id   uuid not null references public.group_members(id) on delete cascade,
  notification_type     text not null,
  payload               jsonb not null default '{}'::jsonb,
  deep_link             text,
  scheduled_for         timestamptz not null default now(),
  dispatched_at         timestamptz,
  dispatch_status       text not null default 'pending',
  dispatch_error        text,
  created_at            timestamptz not null default now()
);

comment on table  public.notifications_outbox is
  'Transactional outbox for push notifications. send-event-notification + start_vote + finalize_vote + finalize-fine-reviews write here; the dispatcher (V1: stub, V2: APNs sender) reads pending rows and updates dispatch_status.';
comment on column public.notifications_outbox.notification_type is
  'Maps to SystemEventType naming (eventCreated, fineOfficialized, voteOpened, voteResolved, etc.) when event-driven, or to a kind string for legacy event lifecycle pushes (created, host_reminder, deadline_warning, cancelled).';
comment on column public.notifications_outbox.dispatch_status is
  'pending | sent | failed | skipped';

create index if not exists notifications_outbox_pending_idx
  on public.notifications_outbox(scheduled_for)
  where dispatched_at is null;

create index if not exists notifications_outbox_group_recipient_idx
  on public.notifications_outbox(group_id, recipient_member_id, created_at desc);

create index if not exists notifications_outbox_type_idx
  on public.notifications_outbox(notification_type);

-- =============================================================================
-- RLS — members see their own outgoing notifications
-- =============================================================================

alter table public.notifications_outbox enable row level security;

drop policy if exists notifications_outbox_select_own on public.notifications_outbox;
create policy notifications_outbox_select_own on public.notifications_outbox
  for select
  using (
    exists (
      select 1 from public.group_members gm
      where gm.id      = notifications_outbox.recipient_member_id
        and gm.user_id = auth.uid()
    )
  );

-- INSERT/UPDATE blocked from clients — only edge functions (service role)
-- and SECURITY DEFINER RPCs (start_vote, finalize_vote) write.
