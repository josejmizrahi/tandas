-- Rollback for 00296 — remove the 3 universal Beta-1 templates.
-- Safe only if no rule_versions FK into them (Beta 1 launch hasn't happened
-- yet at time of rollback) AND mig 00297 hasn't aliased the legacy 12 to
-- them yet (would break alias_of FK).

delete from public.rule_templates
 where id in (
   'deadline_enforcement',
   'missed_obligation_consequence',
   'approval_required'
 );
