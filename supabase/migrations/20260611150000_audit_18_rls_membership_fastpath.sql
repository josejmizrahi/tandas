-- ============================================================================
-- AUDIT.18 — RLS fast-path: membresías una vez por query (2026-06-11)
-- ============================================================================
-- Palanca #1 de lectura de la revisión de escalabilidad (2026-06-11).
-- Problema: las policies SELECT con qual `is_context_member(context_actor_id)`
-- ejecutan la función por CADA FILA candidata (lookup SPI a actor_memberships
-- por fila). Con datos chicos no se nota; con 50k contextos es el primer
-- incendio de lectura.
--
-- Solución (mejor que claims en JWT: cero staleness, cero config de Dashboard):
-- `my_context_ids()` STABLE + quals `context_actor_id IN (SELECT ...)`.
-- El subquery es no-correlacionado → el planner lo evalúa UNA vez por
-- statement (InitPlan/hashed subplan) en lugar de por fila.
--
-- Equivalencia semántica EXACTA con is_context_member(ctx):
--   ctx = current_actor_id()  OR  membresía 'active' del actor actual.
-- Se reescriben SOLO las 10 policies cuyo qual es exactamente
-- `is_context_member(context_actor_id)` (verificado contra pg_policies).
-- Las policies compuestas (activity_events, actors, resources, money…) se
-- quedan como están — su reescritura es trabajo dedicado por tabla (Fase 3).
-- Verificación: suite _smoke_mvp2_* completa (los smokes de visibilidad
-- r2b/r2c/r2k ejercitan estas tablas con actores dentro y fuera del contexto).
-- ============================================================================

create or replace function public.my_context_ids()
returns setof uuid
language sql
stable
security definer
set search_path = public, auth
as $$
  select public.current_actor_id()
  union
  select am.context_actor_id
  from public.actor_memberships am
  where am.member_actor_id = public.current_actor_id()
    and am.membership_status = 'active';
$$;

revoke all on function public.my_context_ids() from public, anon;
grant execute on function public.my_context_ids() to authenticated, service_role;

comment on function public.my_context_ids() is
  'AUDIT.18: contextos visibles del actor actual (personal + membresías active). STABLE: en quals RLS `col IN (SELECT my_context_ids())` se evalúa una vez por query (initplan), no por fila.';

-- Las 10 policies de membresía simple, reescritas 1:1
drop policy if exists events_select on public.calendar_events;
create policy events_select on public.calendar_events
  for select to authenticated
  using (context_actor_id in (select public.my_context_ids()));

drop policy if exists invites_select on public.context_invites;
create policy invites_select on public.context_invites
  for select to authenticated
  using (context_actor_id in (select public.my_context_ids()));

drop policy if exists decisions_select on public.decisions;
create policy decisions_select on public.decisions
  for select to authenticated
  using (context_actor_id in (select public.my_context_ids()));

drop policy if exists governance_actions_select on public.governance_actions;
create policy governance_actions_select on public.governance_actions
  for select to authenticated
  using (context_actor_id in (select public.my_context_ids()));

drop policy if exists governance_policies_select on public.governance_policies;
create policy governance_policies_select on public.governance_policies
  for select to authenticated
  using (context_actor_id in (select public.my_context_ids()));

drop policy if exists resource_conflicts_select_members on public.resource_conflicts;
create policy resource_conflicts_select_members on public.resource_conflicts
  for select to authenticated
  using (context_actor_id in (select public.my_context_ids()));

drop policy if exists role_assignments_select on public.role_assignments;
create policy role_assignments_select on public.role_assignments
  for select to authenticated
  using (context_actor_id in (select public.my_context_ids()));

drop policy if exists roles_select on public.roles;
create policy roles_select on public.roles
  for select to authenticated
  using (context_actor_id in (select public.my_context_ids()));

drop policy if exists rules_select on public.rules;
create policy rules_select on public.rules
  for select to authenticated
  using (context_actor_id in (select public.my_context_ids()));

drop policy if exists vote_delegations_select on public.vote_delegations;
create policy vote_delegations_select on public.vote_delegations
  for select to authenticated
  using (context_actor_id in (select public.my_context_ids()));
