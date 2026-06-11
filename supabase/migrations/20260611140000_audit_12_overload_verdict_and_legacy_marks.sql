-- ============================================================================
-- AUDIT.12 — Veredicto de overloads: marcas LEGACY sin drops (2026-06-11)
-- ============================================================================
-- Cierre del análisis de Fase 2 ítem 2 (SupabaseCleanupMigrationPlan). Los 6
-- nombres con doble overload se verificaron contra iOS + call-sites de toda la
-- cadena. Resultado:
--
-- NO SON LEGACY (APIs duales intencionales — no dropear):
--   · record_game_result: iOS consume la firma winner/loser (8 args); el
--     batch jsonb (5 args, r9_b) es la API de motor. Dual hasta que iOS
--     migre al batch.
--   · context/event/resource_available_actions: la 1-arg es la API
--     caller-derived (la usan los descriptors B6/B7 y decenas de smokes);
--     la 2-arg con p_actor_id es la API actor-explícito del governance-mode
--     (r7_d). Capas, no duplicados.
--
-- LEGACY REALES (se marcan aquí; drop diferido porque smokes históricos los
-- llaman posicionalmente y el refactor debe ser su propia migración):
--   · create_rule 8-args (sin targeting r2s_6). OJO al dropear: la posición 6
--     cambia de p_body a p_target_scope entre firmas → un drop sin refactor
--     de callers posicionales daría breakage SILENCIOSO (ambos son text).
--   · resolve_reservation_conflict 2-args (sin p_resolution_model r2s_7).
-- ============================================================================

do $$
begin
  if exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname = 'create_rule'
      and pg_get_function_identity_arguments(p.oid) like '%p_severity integer'
      and pg_get_function_identity_arguments(p.oid) not like '%p_target_scope%'
  ) then
    comment on function public.create_rule(uuid, text, text, jsonb, jsonb, text, text, integer) is
      'LEGACY OVERLOAD (AUDIT.12 2026-06-11): usar la firma con p_target_scope/p_target_filter (r2s_6). Drop pendiente de refactor de smokes posicionales — la posición 6 cambia de p_body a p_target_scope (ambos text: riesgo de breakage silencioso).';
  end if;

  if exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname = 'resolve_reservation_conflict'
      and pg_get_function_identity_arguments(p.oid) = 'p_conflict_id uuid, p_winner_reservation_id uuid'
  ) then
    comment on function public.resolve_reservation_conflict(uuid, uuid) is
      'LEGACY OVERLOAD (AUDIT.12 2026-06-11): usar la firma con p_resolution_model (r2s_7). Drop pendiente de refactor de smokes que la llaman posicionalmente.';
  end if;
end $$;
