-- Rollback for 00024_rule_mutation_audit.sql
-- Restores the previous rules_update_admin policy and drops the trigger,
-- function, and governance-aware policy added by 00024.

drop policy if exists "rules_update_governance" on public.rules;
create policy "rules_update_admin" on public.rules for update to authenticated
using (public.is_group_admin(group_id, auth.uid())) with check (public.is_group_admin(group_id, auth.uid()));

drop trigger if exists rules_mutation_audit on public.rules;
drop function if exists public.emit_rule_mutation_events();
drop function if exists public.can_modify_rules(uuid, uuid);
