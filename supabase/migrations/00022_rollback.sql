-- 00022 rollback — drop notifications_outbox.
-- Data-destructive: any pending notifications are lost. Only run if you
-- truly want to remove the outbox feature (V1 stub doesn't have any other
-- consumer, so this is safe in V1).
--
-- Note: 00023_appeal_voting_v2.sql writes to this table from start_vote
-- and finalize_vote. If you roll back 00022 you MUST also roll back 00023
-- (or those RPCs will fail at runtime).

drop policy if exists notifications_outbox_select_own on public.notifications_outbox;
drop index  if exists public.notifications_outbox_pending_idx;
drop index  if exists public.notifications_outbox_group_recipient_idx;
drop index  if exists public.notifications_outbox_type_idx;
drop table  if exists public.notifications_outbox;
