-- 00026_archive_rule_on_repeal_pass.sql
-- Spec gap discovered mid-execution of EditRulesView (Plan UI P0 #1).
--
-- The plan's archive flow assumed the existing vote machinery would archive
-- a rule when a `rule_repeal` vote passes. Inspection of finalize_vote
-- (00023_appeal_voting_v2.sql) revealed it only updates votes.status +
-- emits voteResolved, with no side-effect on the referenced rule.
--
-- This migration adds an AFTER UPDATE trigger on votes that watches for
-- status transitioning open → resolved for vote_type='rule_repeal' with
-- payload.resolution='passed', and archives the rule. Decoupled from
-- finalize_vote so it works regardless of which RPC drives resolution.
--
-- Note: the rules UPDATE here also fires rules_mutation_audit (00024),
-- emitting a ruleEnabledChanged event in addition to the voteResolved
-- event finalize_vote already emits. Spec acknowledges this dual emission
-- as accepted-as-is V1.

create or replace function public.archive_rule_on_repeal_pass()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.vote_type = 'rule_repeal'
     and new.status = 'resolved'
     and old.status = 'open'
     and (new.payload->>'resolution') = 'passed'
     and new.reference_id is not null then
    update public.rules
    set status = 'archived', enabled = false
    where id = new.reference_id;
  end if;
  return new;
end;
$$;

comment on function public.archive_rule_on_repeal_pass() is
  'Archives a rule when its rule_repeal vote resolves passed. Watches votes.status open→resolved. Added 2026-05-05 as part of EditRulesView (Plan UI P0 #1).';

drop trigger if exists archive_rule_on_repeal_pass on public.votes;
create trigger archive_rule_on_repeal_pass
after update on public.votes
for each row
execute function public.archive_rule_on_repeal_pass();
