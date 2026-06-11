-- ============================================================================
-- AUDIT.6 — Completar shim r9_g: policy de resource_conflicts (2026-06-11)
-- ============================================================================
-- _smoke_mvp2_audit_baseline (audit_5) detectó en el replay de CI exactamente
-- el drift que la auditoría documenta: la policy
-- `resource_conflicts_select_members` existe en live (creada vía MCP en la era
-- R5B) pero nunca aterrizó en disco; el shim r9_g reconstruyó la tabla y
-- habilitó RLS sin la policy → en replay la tabla quedaba RLS-enabled y
-- deny-all, y el baseline (assert 2: toda tabla tiene ≥1 policy) la cazó.
-- Se replica aquí la policy idéntica a la de live (qual extraído de
-- pg_policies). En live este migration es no-op.
-- ============================================================================

do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename = 'resource_conflicts'
      and policyname = 'resource_conflicts_select_members'
  ) then
    create policy resource_conflicts_select_members
      on public.resource_conflicts
      for select
      to authenticated
      using (is_context_member(context_actor_id));
  end if;
end $$;
