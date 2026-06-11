-- ============================================================================
-- AUDIT.8 — Registro de deprecación de RPCs legacy (2026-06-11)
-- ============================================================================
-- Fase 2 ítem 1 del SupabaseCleanupMigrationPlan: COMMENT ON, sin drops.
-- Lista verificada contra (a) consumo iOS (grep SupabaseRuulRPCClient),
-- (b) call-sites internos en toda la cadena de migrations:
--   · set_event_participant_plus_one → superseded por
--     set_event_participant_plus_count (r5z 20260610180000).
--   · request_governed_action → entrada legacy R.5; el canónico R.7 es
--     request_governance_action. Los smokes R.5 la siguen ejercitando: NO
--     se dropea, solo se marca.
--   · actor_inbox_items → superseded por attention_inbox (F.NAV).
--   · decision_results → superseded por decision_detail; función drift
--     live-only (sin definición en disco) → el DO block la salta en replay.
-- Excluidas tras verificación de callers: governance_policy (consumida por
-- record_expense R.9.C), update_governance_policy (flujo de policies),
-- current_person_actor_id (alias intencional R.4A), evaluate_rules_for_event
-- (entrada manual del motor), mark_notification_*/emit_notification (R.4D
-- pendiente de frontend), overloads *_available_actions (callers internos de
-- descriptors; su drop es Fase 2 ítem 2 con verificación dedicada).
-- ============================================================================

do $$
declare
  r record;
  v_notes constant jsonb := jsonb_build_object(
    'set_event_participant_plus_one', 'DEPRECATED (AUDIT.8 2026-06-11): usar set_event_participant_plus_count. Se conserva por compatibilidad; no consumida por iOS.',
    'request_governed_action',        'DEPRECATED (AUDIT.8 2026-06-11): entrada legacy R.5; usar request_governance_action (entrypoint canónico R.7). Ejercitada aún por smokes R.5.',
    'actor_inbox_items',              'DEPRECATED (AUDIT.8 2026-06-11): usar attention_inbox().',
    'decision_results',               'DEPRECATED (AUDIT.8 2026-06-11): usar decision_detail(). Función drift live-only (sin migration en disco).'
  );
  v_fn text;
  n int := 0;
begin
  for v_fn in select jsonb_object_keys(v_notes) loop
    for r in
      select p.oid, p.proname, pg_get_function_identity_arguments(p.oid) as args
      from pg_proc p
      where p.pronamespace = 'public'::regnamespace and p.proname = v_fn
    loop
      execute format('comment on function public.%I(%s) is %L',
                     r.proname, r.args, v_notes->>v_fn);
      n := n + 1;
    end loop;
  end loop;
  raise notice 'audit_8: % funciones marcadas DEPRECATED', n;
end $$;
