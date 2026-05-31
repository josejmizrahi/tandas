-- Mig 00197: surface duration/quorum/threshold knobs in expense_threshold_vote
-- template defaults. Builder Sprint 8 — admin chooses vote settings at publish
-- time instead of inheriting global defaults.
--
-- The startVote consequence executor reads these from cons.config and
-- passes them to sink.startVote → start_vote RPC. Nulls fall through to
-- group_policy defaults; this template now ships sensible Money-vote
-- defaults instead.

update public.rule_templates
set default_params = jsonb_build_object(
  'threshold_cents',    500000,
  'duration_hours',     48,
  'quorum_percent',     50,
  'threshold_percent',  50
)
where id = 'expense_threshold_vote';
