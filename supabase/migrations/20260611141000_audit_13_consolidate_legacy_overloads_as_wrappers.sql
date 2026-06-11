-- ============================================================================
-- AUDIT.13 — Consolidar overloads legacy como wrappers delegantes (2026-06-11)
-- ============================================================================
-- Continúa AUDIT.12. Los dos overloads legacy eran IMPLEMENTACIONES
-- INDEPENDIENTES duplicadas (el verdadero problema de "no duplicar
-- conceptos"), no firmas alternativas. En vez de droparlos (rompería el
-- dispatcher de governance y ~7 smokes posicionales), se convierten en
-- wrappers de una línea que delegan a la implementación canónica:
--
--   · create_rule 8-args → delega a la firma con targeting (r2s_6) con
--     p_target_scope/p_target_filter en null (defaults canónicos:
--     'event_type' / '{}'). El INSERT duplicado desaparece.
--   · resolve_reservation_conflict 2-args → delega al modelo 'winner' de
--     r2s_7. Equivalencia verificada rama por rama: loser→'rejected',
--     winner requested→'approved', conflicto→'resolved' con metadata.winner,
--     mismos 3 activity events, mismo no_op:true sobre conflictos no-open.
--
-- CREATE OR REPLACE conserva ACLs y ownership. El drop físico de las firmas
-- queda para cuando el dispatcher r7_x y los smokes históricos se modernicen
-- (sin prisa: ya no hay lógica duplicada, solo una firma de cortesía).
-- Verificación: suite _smoke_mvp2_* completa en live tras aplicar.
-- ============================================================================

create or replace function public.create_rule(
  p_context_actor_id uuid,
  p_title text,
  p_trigger_event_type text default null,
  p_condition_tree jsonb default null,
  p_consequences jsonb default null,
  p_body text default null,
  p_rule_type text default 'automation',
  p_severity integer default 1
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
begin
  return public.create_rule(
    p_context_actor_id, p_title, p_trigger_event_type, p_condition_tree,
    p_consequences, null::text, null::jsonb, p_body, p_rule_type, p_severity);
end;
$$;

comment on function public.create_rule(uuid, text, text, jsonb, jsonb, text, text, integer) is
  'LEGACY WRAPPER (AUDIT.13 2026-06-11): delega a create_rule(...p_target_scope, p_target_filter...) con targeting default. Antes era una implementación duplicada. Drop físico pendiente de modernizar el dispatcher r7_x y los callers posicionales.';

create or replace function public.resolve_reservation_conflict(
  p_conflict_id uuid,
  p_winner_reservation_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
begin
  return public.resolve_reservation_conflict(
    p_conflict_id, 'winner', p_winner_reservation_id, '{}'::jsonb);
end;
$$;

comment on function public.resolve_reservation_conflict(uuid, uuid) is
  'LEGACY WRAPPER (AUDIT.13 2026-06-11): delega al modelo ''winner'' de r2s_7 (semántica equivalente verificada: loser→rejected, winner→approved, mismos activity events, no_op sobre no-open). Antes era una implementación duplicada.';
