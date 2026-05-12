-- Rollback 00124 — quitar el trigger guard. Esto reabre el agujero
-- donde un admin puede mutar groups.governance directo. Sólo usar si
-- el trigger rompe un path legítimo y se necesita un fix forward.

drop trigger if exists groups_governance_guard on public.groups;
drop function if exists public.guard_groups_governance_update();
