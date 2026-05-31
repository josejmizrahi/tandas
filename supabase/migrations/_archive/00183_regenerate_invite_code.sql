-- =============================================================================
-- mig 00176 — regenerate_invite_code RPC
-- =============================================================================
--
-- Adds a SECURITY DEFINER RPC that rotates a group's `invite_code`, gated
-- by Permission.modifyGovernance via the existing `has_permission()` lookup
-- (mig 00063). Emits an `inviteCodeRotated` system_event so the timeline
-- captures who rotated and when. Old code stops working immediately —
-- any pending invite holding the previous string returns
-- inviteCodeNotFound from `join_group_by_code` (mig 00003 line 41).
--
-- Why `modifyGovernance` and not `modifyMembers`:
--   Rotating affects everyone already holding the code (every pending
--   invite invalidates the next millisecond). That's a structural
--   decision about how the group is joined, which is closer to
--   governance than to day-to-day member management. Founders + custom
--   admin roles get it by default; templates can extend.
--
-- iOS surface:
--   `LiveGroupsRepository.regenerateInviteCode(groupId:)` (Mock + Live)
--   driving a destructive CTA in `GroupInfoSheet.inviteSection`, gated
--   by `GovernanceService.hasPermission(.modifyGovernance)` so the
--   button is hidden for everyone else (fail-closed, matching how
--   `canInviteMembers` is computed in `MainTabView`).
--
-- Doctrine compliance:
--   - `system_events` is append-only (mig 00162 atom guard) — we only
--     INSERT, never UPDATE/DELETE.
--   - `record_system_event` already exists (mig 00014 line 249) and is
--     the canonical entry point.
--   - No new enum value in DB; `event_type` is `text` so the new
--     `inviteCodeRotated` string is data-only. The Swift enum gets a
--     case added separately (and `make gen` regenerates the codable).
-- =============================================================================

create or replace function public.regenerate_invite_code(
  p_group_id uuid
) returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor_id uuid := auth.uid();
  v_new_code text;
begin
  if v_actor_id is null then
    raise exception 'unauthenticated' using errcode = '42501';
  end if;

  if not public.has_permission(p_group_id, v_actor_id, 'modifyGovernance') then
    raise exception 'forbidden — Permission.modifyGovernance required'
      using errcode = '42501';
  end if;

  -- 8 chars, lowercase, alphanumeric. Match the original column default
  -- in 00001_core_schema.sql:65 exactly so the join_group_by_code lookup
  -- and the iOS uppercase display surface stay identical.
  v_new_code := substr(md5(random()::text || clock_timestamp()::text), 1, 8);

  update public.groups
     set invite_code = v_new_code
   where id = p_group_id;

  -- Append-only audit row. Payload carries the rotator's user_id so the
  -- group timeline can render "X rotó el código del grupo" without
  -- joining out to auth.users (the timeline reader is already group-RLS
  -- scoped).
  perform public.record_system_event(
    p_group_id    => p_group_id,
    p_event_type  => 'inviteCodeRotated',
    p_resource_id => null,
    p_member_id   => v_actor_id,
    p_payload     => jsonb_build_object('rotated_by', v_actor_id)
  );

  return v_new_code;
end;
$$;

revoke execute on function public.regenerate_invite_code(uuid) from public, anon;
grant  execute on function public.regenerate_invite_code(uuid) to authenticated;

comment on function public.regenerate_invite_code(uuid) is
  'Rotates groups.invite_code. Gated by Permission.modifyGovernance via has_permission(). Emits inviteCodeRotated system_event. iOS surface: GroupInfoSheet "Regenerar código" destructive CTA.';
