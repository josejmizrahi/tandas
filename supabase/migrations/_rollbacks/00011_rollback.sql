-- Rollback for 00011_onboarding_v1.sql
-- NOT applied automatically. Run manually in case of emergency.

drop function if exists public.update_group_config(uuid, text, text, jsonb, boolean, text, text);
drop function if exists public.mark_invite_used(uuid);
drop function if exists public.create_initial_rule(uuid, text, text, text, jsonb, jsonb);

-- Restore original create_group_with_admin (5-arg signature from 00010)
drop function if exists public.create_group_with_admin(text, text, text, text, text, text);
-- (Re-create the 00010 version manually if needed.)

drop view if exists public.invite_preview;
drop view if exists public.group_members_with_founder;
drop table if exists public.otp_codes;
drop table if exists public.invites;
alter table public.group_members drop column if exists joined_at_event_count;

drop trigger if exists groups_sync_rotation on public.groups;
drop function if exists public.sync_rotation_fields();

alter table public.groups
  drop column if exists rotation_mode,
  drop column if exists fines_enabled,
  drop column if exists frequency_config,
  drop column if exists frequency_type,
  drop column if exists cover_image_name;
