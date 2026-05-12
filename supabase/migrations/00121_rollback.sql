-- 00121_rollback.sql
-- Reverts the 8 function-backed CHECKs to their inline-enum forms and
-- drops the helper functions. Whitelist content is preserved verbatim.

alter table public.events drop constraint if exists events_status_check;
alter table public.events add constraint events_status_check
  check (status = any (array['scheduled'::text,'in_progress'::text,'completed'::text,'cancelled'::text]));

alter table public.fines drop constraint if exists fines_status_check;
alter table public.fines add constraint fines_status_check
  check (status = any (array['proposed'::text,'officialized'::text,'paid'::text,'voided'::text,'in_appeal'::text]));

alter table public.groups drop constraint if exists groups_category_check;
alter table public.groups add constraint groups_category_check
  check (category = any (array['socialRecurring'::text,'sharedResource'::text,'rotatingSavings'::text,'patrimonialFamily'::text,'amateurTeam'::text,'groupTravel'::text,'religiousCultural'::text,'professionalInformal'::text,'digitalCommunity'::text,'commitmentPact'::text]));

alter table public.group_members drop constraint if exists group_members_role_check;
alter table public.group_members add constraint group_members_role_check
  check (role = any (array['admin'::text,'member'::text]));

alter table public.notification_tokens drop constraint if exists notification_tokens_platform_check;
alter table public.notification_tokens add constraint notification_tokens_platform_check
  check (platform = any (array['ios'::text,'android'::text,'web'::text]));

alter table public.otp_codes drop constraint if exists otp_codes_channel_check;
alter table public.otp_codes add constraint otp_codes_channel_check
  check (channel = any (array['whatsapp'::text,'sms'::text]));

alter table public.rule_shapes drop constraint if exists rule_shapes_kind_check;
alter table public.rule_shapes add constraint rule_shapes_kind_check
  check (kind = any (array['trigger'::text,'condition'::text,'consequence'::text]));

alter table public.event_attendance drop constraint if exists event_attendance_check_in_method_check;
alter table public.event_attendance add constraint event_attendance_check_in_method_check
  check (check_in_method is null or check_in_method = any (array['self'::text,'qr_scan'::text,'host_marked'::text]));

drop function if exists public.is_known_event_status(text);
drop function if exists public.is_known_fine_status(text);
drop function if exists public.is_known_group_category(text);
drop function if exists public.is_known_group_member_role(text);
drop function if exists public.is_known_notification_platform(text);
drop function if exists public.is_known_otp_channel(text);
drop function if exists public.is_known_rule_shape_kind(text);
drop function if exists public.is_known_check_in_method(text);
