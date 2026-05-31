-- 00024_rule_mutation_audit.sql
-- Adds:
--   1. public.can_modify_rules(group_id, user_id) — governance-aware UPDATE gate.
--   2. public.emit_rule_mutation_events() trigger fn — atomic audit emission
--      for rules.enabled / rules.consequences mutations.
--   3. rules_mutation_audit AFTER UPDATE trigger.
--   4. Replaces rules_update_admin policy with rules_update_governance which
--      consults can_modify_rules instead of is_group_admin.
--
-- Companion to EditRulesView (Plan UI P0 #1, Fase 0 #5).

-- ───────────────────────────────────────────────────────────────────────
-- 1. can_modify_rules — single source of truth for "can this user UPDATE
--    rules in this group?". Consulted by RLS and (in a follow-up) by
--    GovernanceService.canPerform(.modifyRules).
-- ───────────────────────────────────────────────────────────────────────
create or replace function public.can_modify_rules(p_group_id uuid, p_user_id uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_governance_value text;
  v_member group_members;
begin
  select * into v_member
  from public.group_members
  where group_id = p_group_id and user_id = p_user_id and active
  limit 1;
  if not found then return false; end if;

  select governance->>'whoCanModifyRules' into v_governance_value
  from public.groups where id = p_group_id;

  return case v_governance_value
    when 'founder'   then v_member.role = 'founder'
    when 'anyMember' then true
    -- 'majorityVote' / 'supermajorityVote' / 'host' / 'treasurer' all
    -- require routing through a vote (or a non-V1 path); direct UPDATE
    -- is denied so client checks must funnel users to the vote flow.
    else false
  end;
end;
$$;

revoke execute on function public.can_modify_rules(uuid, uuid) from public, anon;
grant  execute on function public.can_modify_rules(uuid, uuid) to authenticated;

comment on function public.can_modify_rules(uuid, uuid) is
  'Returns true if the user may UPDATE rules in the group, per governance.whoCanModifyRules. '
  'Added 2026-05-05 with EditRulesView (Plan UI P0 #1).';

-- ───────────────────────────────────────────────────────────────────────
-- 2. emit_rule_mutation_events — fires AFTER UPDATE on rules; emits one
--    system_events row per mutated column (enabled, consequences). Both
--    are emitted if both change in the same statement.
-- ───────────────────────────────────────────────────────────────────────
create or replace function public.emit_rule_mutation_events()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_member_id uuid;
begin
  select id into v_member_id
  from public.group_members
  where group_id = new.group_id
    and user_id = auth.uid()
    and active
  limit 1;

  if new.enabled is distinct from old.enabled then
    insert into public.system_events (group_id, event_type, resource_id, member_id, payload)
    values (new.group_id, 'ruleEnabledChanged', new.id, v_member_id, jsonb_build_object(
      'rule_title', new.title,
      'before', old.enabled,
      'after', new.enabled
    ));
  end if;

  if new.consequences is distinct from old.consequences then
    insert into public.system_events (group_id, event_type, resource_id, member_id, payload)
    values (new.group_id, 'ruleAmountChanged', new.id, v_member_id, jsonb_build_object(
      'rule_title', new.title,
      'before', old.consequences,
      'after', new.consequences
    ));
  end if;

  return new;
end;
$$;

comment on function public.emit_rule_mutation_events() is
  'Emits ruleEnabledChanged / ruleAmountChanged system_events atomically on UPDATE. '
  'Added 2026-05-05 as part of EditRulesView (Plan UI P0 #1).';

-- ───────────────────────────────────────────────────────────────────────
-- 3. Trigger wiring.
-- ───────────────────────────────────────────────────────────────────────
drop trigger if exists rules_mutation_audit on public.rules;
create trigger rules_mutation_audit
after update on public.rules
for each row
execute function public.emit_rule_mutation_events();

-- ───────────────────────────────────────────────────────────────────────
-- 4. Swap UPDATE policy: was is_group_admin, now governance-aware.
--    The previous policy gated UPDATE behind admin role only. The new
--    policy consults whoCanModifyRules so groups configured for
--    'founder' or 'anyMember' get direct edits and groups configured
--    for 'majorityVote' / 'supermajorityVote' must route through votes.
-- ───────────────────────────────────────────────────────────────────────
drop policy if exists "rules_update_admin" on public.rules;
create policy "rules_update_governance" on public.rules for update to authenticated
using (public.can_modify_rules(group_id, auth.uid()))
with check (public.can_modify_rules(group_id, auth.uid()));
