-- Mig 00319: restrict visibility of placeholder profiles to group admins.
--
-- Reason: placeholder.phone is sensitive (admin-entered, not opt-in). The
-- existing profiles_select policy lets every co-member of any shared group
-- read the row, which would leak the phone to all group members.
--
-- Postgres permissive policies OR together — adding another permissive
-- policy can ONLY broaden visibility. To narrow, we add a RESTRICTIVE
-- policy that requires the row to either (a) not be an unclaimed
-- placeholder, (b) be the caller themselves, or (c) belong to a group
-- where the caller is admin. Restrictive policies AND with permissive
-- ones, so this acts as a gate.
--
-- Source: Docs/superpowers/specs/2026-05-17-placeholder-members-design.md §15.7

drop policy if exists profiles_select_placeholder_admin_gate on public.profiles;
create policy profiles_select_placeholder_admin_gate on public.profiles
  as restrictive
  for select
  using (
    is_placeholder = false
    or claimed_at is not null
    or auth.uid() = id
    or exists (
      select 1 from public.group_members gm
      where gm.user_id = profiles.id
        and public.is_group_admin(gm.group_id, auth.uid())
    )
  );

comment on policy profiles_select_placeholder_admin_gate on public.profiles is
  'Restrictive gate: an unclaimed placeholder profile is only visible to group admins of the placeholder''s group (plus the placeholder itself). Combines AND with profiles_select so non-admin members of the group cannot read the phone.';
