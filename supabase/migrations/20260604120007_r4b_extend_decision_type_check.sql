
-- R.4B: extend decisions.decision_type CHECK to include the domain values used
-- by the new template catalog (governance, money, resources, reservations).
-- Pre-existing values stay accepted; no row migration needed.
alter table public.decisions
  drop constraint if exists decisions_decision_type_check;

alter table public.decisions
  add constraint decisions_decision_type_check
  check (decision_type in (
    -- legacy values (preserved)
    'expense_approval', 'rule_change', 'member_admission',
    'resource_purchase', 'reservation_dispute', 'generic',
    -- R.4B template domains
    'governance', 'money', 'resources', 'reservations'
  ));
