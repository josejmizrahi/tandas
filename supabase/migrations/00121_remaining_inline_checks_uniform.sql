-- 00121 — Convert the remaining 8 inline-enum CHECK constraints to the
-- uniform `is_known_*` function-backed pattern (introduced for
-- system_events.event_type in 00092/00095 and replicated for vote_type
-- in 00116, rsvp_status in 00118, policy_type + target_scope in 00119).
--
-- Tables:
--   events.status                    → is_known_event_status
--   fines.status                     → is_known_fine_status
--   groups.category                  → is_known_group_category
--   group_members.role               → is_known_group_member_role
--   notification_tokens.platform     → is_known_notification_platform
--   otp_codes.channel                → is_known_otp_channel
--   rule_shapes.kind                 → is_known_rule_shape_kind
--   event_attendance.check_in_method → is_known_check_in_method
--
-- Prod-audited: every row matches the new whitelist, so the
-- NOT VALID + VALIDATE swap is lock-light (single ACCESS EXCLUSIVE
-- on metadata, shared lock during VALIDATE).
--
-- Phase 2 ergonomics: extending any whitelist becomes a single
-- `create or replace function` migration — no table-level DDL.

create or replace function public.is_known_event_status(p_status text)
returns boolean language sql immutable parallel safe set search_path = public as $$
  select p_status = any (array['scheduled','in_progress','completed','cancelled']);
$$;
revoke execute on function public.is_known_event_status(text) from public, anon;
grant  execute on function public.is_known_event_status(text) to authenticated, service_role;
alter table public.events drop constraint if exists events_status_check;
alter table public.events add constraint events_status_check
  check (public.is_known_event_status(status)) not valid;
alter table public.events validate constraint events_status_check;

create or replace function public.is_known_fine_status(p_status text)
returns boolean language sql immutable parallel safe set search_path = public as $$
  select p_status = any (array['proposed','officialized','paid','voided','in_appeal']);
$$;
revoke execute on function public.is_known_fine_status(text) from public, anon;
grant  execute on function public.is_known_fine_status(text) to authenticated, service_role;
alter table public.fines drop constraint if exists fines_status_check;
alter table public.fines add constraint fines_status_check
  check (public.is_known_fine_status(status)) not valid;
alter table public.fines validate constraint fines_status_check;

create or replace function public.is_known_group_category(p_category text)
returns boolean language sql immutable parallel safe set search_path = public as $$
  select p_category = any (array[
    'socialRecurring','sharedResource','rotatingSavings','patrimonialFamily',
    'amateurTeam','groupTravel','religiousCultural','professionalInformal',
    'digitalCommunity','commitmentPact'
  ]);
$$;
revoke execute on function public.is_known_group_category(text) from public, anon;
grant  execute on function public.is_known_group_category(text) to authenticated, service_role;
alter table public.groups drop constraint if exists groups_category_check;
alter table public.groups add constraint groups_category_check
  check (public.is_known_group_category(category)) not valid;
alter table public.groups validate constraint groups_category_check;

create or replace function public.is_known_group_member_role(p_role text)
returns boolean language sql immutable parallel safe set search_path = public as $$
  -- Legacy values. The richer role contract lives in groups.roles jsonb
  -- (mig 00063) + has_permission RPC; this text column stays for queries
  -- that key on the cheap shorthand.
  select p_role = any (array['admin','member']);
$$;
revoke execute on function public.is_known_group_member_role(text) from public, anon;
grant  execute on function public.is_known_group_member_role(text) to authenticated, service_role;
alter table public.group_members drop constraint if exists group_members_role_check;
alter table public.group_members add constraint group_members_role_check
  check (public.is_known_group_member_role(role)) not valid;
alter table public.group_members validate constraint group_members_role_check;

create or replace function public.is_known_notification_platform(p_platform text)
returns boolean language sql immutable parallel safe set search_path = public as $$
  -- No iOS enum mirror; this function is canonical for the platform
  -- column. New platforms (e.g. 'desktop', 'macos') extend by editing
  -- this function in a follow-up migration.
  select p_platform = any (array['ios','android','web']);
$$;
revoke execute on function public.is_known_notification_platform(text) from public, anon;
grant  execute on function public.is_known_notification_platform(text) to authenticated, service_role;
alter table public.notification_tokens drop constraint if exists notification_tokens_platform_check;
alter table public.notification_tokens add constraint notification_tokens_platform_check
  check (public.is_known_notification_platform(platform)) not valid;
alter table public.notification_tokens validate constraint notification_tokens_platform_check;

create or replace function public.is_known_otp_channel(p_channel text)
returns boolean language sql immutable parallel safe set search_path = public as $$
  select p_channel = any (array['whatsapp','sms']);
$$;
revoke execute on function public.is_known_otp_channel(text) from public, anon;
grant  execute on function public.is_known_otp_channel(text) to authenticated, service_role;
alter table public.otp_codes drop constraint if exists otp_codes_channel_check;
alter table public.otp_codes add constraint otp_codes_channel_check
  check (public.is_known_otp_channel(channel)) not valid;
alter table public.otp_codes validate constraint otp_codes_channel_check;

create or replace function public.is_known_rule_shape_kind(p_kind text)
returns boolean language sql immutable parallel safe set search_path = public as $$
  select p_kind = any (array['trigger','condition','consequence']);
$$;
revoke execute on function public.is_known_rule_shape_kind(text) from public, anon;
grant  execute on function public.is_known_rule_shape_kind(text) to authenticated, service_role;
alter table public.rule_shapes drop constraint if exists rule_shapes_kind_check;
alter table public.rule_shapes add constraint rule_shapes_kind_check
  check (public.is_known_rule_shape_kind(kind)) not valid;
alter table public.rule_shapes validate constraint rule_shapes_kind_check;

create or replace function public.is_known_check_in_method(p_method text)
returns boolean language sql immutable parallel safe set search_path = public as $$
  -- NULL is a valid state (member RSVPd but hasn't arrived yet). The
  -- CHECK clause short-circuits on NULL so this function only sees
  -- non-null values; if a caller forces NULL through here we return
  -- true to keep the contract consistent with the inline form.
  select p_method is null or p_method = any (array['self','qr_scan','host_marked']);
$$;
revoke execute on function public.is_known_check_in_method(text) from public, anon;
grant  execute on function public.is_known_check_in_method(text) to authenticated, service_role;
alter table public.event_attendance drop constraint if exists event_attendance_check_in_method_check;
alter table public.event_attendance add constraint event_attendance_check_in_method_check
  check (check_in_method is null or public.is_known_check_in_method(check_in_method)) not valid;
alter table public.event_attendance validate constraint event_attendance_check_in_method_check;
