-- Rollback 00125 — restaurar EXECUTE para authenticated. Sólo
-- usar si revocar rompe un path legítimo (no debería: la función es
-- trigger-only).

grant execute on function public.guard_groups_governance_update() to authenticated;
