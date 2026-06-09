-- ============================================================================
-- R.5A fix — Zombie action capabilities sync
-- ============================================================================
-- Audit 2026-06-09: 5 actions del resource_action_catalog tienen
-- required_capability que NINGÚN subtype declara. Las 5 nunca aparecen en el
-- toolbar de ningún recurso. Eran legacy keys (`monetary`, `approval_required`)
-- previos a R.5A.B.2 expansion. Fix: re-mapear al naming moderno.
--
-- - approve_document: approval_required → approvable
-- - record_expense:   monetary → payable
-- - record_contribution: monetary → payable
-- - view_transactions: monetary → auditable (read-only access)
-- - generate_settlement: monetary → settleable
--
-- Smoke target: select required_capability from resource_action_catalog
-- where action_key in (...) — debe match modern names.
-- Idempotente vía WHERE clauses.
-- ============================================================================

update public.resource_action_catalog
   set required_capability = 'approvable'
 where action_key = 'approve_document'
   and required_capability = 'approval_required';

update public.resource_action_catalog
   set required_capability = 'payable'
 where action_key = 'record_expense'
   and required_capability = 'monetary';

update public.resource_action_catalog
   set required_capability = 'payable'
 where action_key = 'record_contribution'
   and required_capability = 'monetary';

update public.resource_action_catalog
   set required_capability = 'auditable'
 where action_key = 'view_transactions'
   and required_capability = 'monetary';

update public.resource_action_catalog
   set required_capability = 'settleable'
 where action_key = 'generate_settlement'
   and required_capability = 'monetary';

-- Smoke inline: verifica que las 5 actions ahora tienen capability satisfecha
do $$
declare
  v_zombies int;
begin
  select count(*) into v_zombies
  from public.resource_action_catalog ac
  left join (select distinct capability_key from public.resource_subtype_capabilities) sc
    on sc.capability_key = ac.required_capability
  where ac.required_capability is not null
    and sc.capability_key is null
    and ac.action_key in ('approve_document','record_expense','record_contribution','view_transactions','generate_settlement');

  if v_zombies > 0 then
    raise exception 'R.5A fix zombie: % action_keys still zombie after remap', v_zombies;
  end if;
end$$;
