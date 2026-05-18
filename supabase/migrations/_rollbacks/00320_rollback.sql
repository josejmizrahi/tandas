-- Rollback for 00320 — remove the 2 new universals + restore alias targets.

-- Reset aliases that pointed at the new universals back to missed_obligation_consequence
-- (the previous alias target from 00297).
update public.rule_templates
   set alias_of = 'missed_obligation_consequence'
 where id in ('no_show_fine','same_day_cancel_fine');

-- Drop the new universals (no rules should reference them yet if rolling back fresh).
delete from public.rule_templates
 where id in ('no_show_consequence','late_cancellation_consequence');
