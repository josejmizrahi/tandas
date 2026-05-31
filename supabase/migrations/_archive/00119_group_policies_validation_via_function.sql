-- 00119 — Function-backed CHECK constraints for
-- group_policies.policy_type and group_policies.target_scope. Same
-- pattern as 00118 for rsvp_status / 00092+00095 for system_events:
-- whitelist lives in `is_known_*` functions so Phase 2 extensions
-- don't need ALTER TABLE.
--
-- Prod values right now:
--   policy_type   → direct (3), vote_required (3), admin_only (26)
--   target_scope  → covered by the inline CHECK already restricting it
--                   to group | resource_type | resource
-- All within the new whitelists; NOT VALID + VALIDATE is safe.
--
-- iOS `PolicyType` enum is the canonical source for policy_type
-- (GroupPolicy.swift). target_scope is a plain `String` in iOS today
-- with documented valid values — the SQL function becomes the
-- canonical for now and can be promoted to a Swift enum later if Phase
-- 2 needs richer typing.

create or replace function public.is_known_policy_type(p_policy_type text)
returns boolean
language sql
immutable
parallel safe
set search_path = public
as $$
  -- Keep in sync with
  -- ios/Packages/RuulCore/Sources/RuulCore/PlatformModels/GroupPolicy.swift
  -- `PolicyType` enum.
  select p_policy_type = any (array[
    'direct',
    'vote_required',
    'admin_only',
    'denied'
  ]);
$$;

revoke execute on function public.is_known_policy_type(text) from public, anon;
grant  execute on function public.is_known_policy_type(text) to authenticated, service_role;

comment on function public.is_known_policy_type(text) is
  'Whitelist check for group_policies.policy_type. Mirrors the iOS PolicyType enum. Backed by group_policies_policy_type_check CHECK constraint (00119).';

create or replace function public.is_known_policy_target_scope(p_scope text)
returns boolean
language sql
immutable
parallel safe
set search_path = public
as $$
  -- Canonical here (no iOS enum yet — GroupPolicy.swift uses
  -- `targetScope: String` with documented valid values).
  select p_scope = any (array[
    'group',
    'resource_type',
    'resource'
  ]);
$$;

revoke execute on function public.is_known_policy_target_scope(text) from public, anon;
grant  execute on function public.is_known_policy_target_scope(text) to authenticated, service_role;

comment on function public.is_known_policy_target_scope(text) is
  'Whitelist check for group_policies.target_scope. iOS uses a String type today; this function is the canonical until a Swift enum lands.';

alter table public.group_policies
  drop constraint if exists group_policies_policy_type_check;

alter table public.group_policies
  add constraint group_policies_policy_type_check
  check (public.is_known_policy_type(policy_type)) not valid;

alter table public.group_policies
  validate constraint group_policies_policy_type_check;

alter table public.group_policies
  drop constraint if exists group_policies_target_scope_check;

alter table public.group_policies
  add constraint group_policies_target_scope_check
  check (public.is_known_policy_target_scope(target_scope)) not valid;

alter table public.group_policies
  validate constraint group_policies_target_scope_check;

comment on constraint group_policies_policy_type_check on public.group_policies is
  'Hard whitelist enforcement via is_known_policy_type (00119). Update the function to add new policy types — the CHECK picks up the change automatically.';
comment on constraint group_policies_target_scope_check on public.group_policies is
  'Hard whitelist enforcement via is_known_policy_target_scope (00119). Update the function when Phase 2 introduces broader scope (e.g. resource_capability).';
