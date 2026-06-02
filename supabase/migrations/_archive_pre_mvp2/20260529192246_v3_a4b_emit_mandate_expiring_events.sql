-- 20260530000400 — V3-A4b: emisor de mandate.expiring_in_24h.
--
-- Cierra parcialmente §K.3 fanout (mandate por vencer). Esta RPC se
-- diseña para ser invocada por edge function con cron schedule diario
-- (cron pg_cron no está activo en este proyecto Supabase).
--
-- A4a (obligation.overdue) NO se aterriza aquí: group_obligations no tiene
-- columna due_at — la doctrina de "cuándo vence una obligación" requiere
-- decisión founder (¿desde sanction.ends_at? ¿metadata? ¿plan de pago?).
-- Marcado como deferred en §0.3 + §M.1 V3-A4a hasta que se resuelva.
--
-- Diseño:
--   - SELECT mandates con status='granted', revoked_at IS NULL,
--     ends_at BETWEEN now() AND now() + 24h.
--   - Idempotency: NO re-emitir si ya existe group_events con
--     event_type='mandate.expiring_in_24h' y entity_id=mandate.id
--     en las últimas 24h.
--   - Para cada match: record_system_event con payload incluyendo
--     hours_until_expiration y representative + principal IDs.
--   - Retorna count para observabilidad.

CREATE OR REPLACE FUNCTION public.emit_mandate_expiring_events()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public', 'pg_catalog'
AS $function$
DECLARE
  v_count int := 0;
  v_m     record;
  v_hours numeric;
BEGIN
  FOR v_m IN
    SELECT m.id, m.group_id, m.representative_membership_id, m.principal_type,
           m.principal_id, m.mandate_type, m.ends_at, m.scope
      FROM public.group_mandates m
     WHERE m.status      = 'granted'
       AND m.revoked_at  IS NULL
       AND m.ends_at     IS NOT NULL
       AND m.ends_at     >  now()
       AND m.ends_at     <= now() + interval '24 hours'
       AND NOT EXISTS (
         SELECT 1 FROM public.group_events e
          WHERE e.event_type = 'mandate.expiring_in_24h'
            AND e.entity_kind = 'mandate'
            AND e.entity_id  = m.id
            AND e.created_at >= now() - interval '24 hours'
       )
  LOOP
    v_hours := EXTRACT(EPOCH FROM (v_m.ends_at - now())) / 3600.0;

    PERFORM public.record_system_event(
      v_m.group_id,
      'mandate.expiring_in_24h',
      'mandate',
      v_m.id,
      'Un mandato vence en menos de 24 horas',
      jsonb_build_object(
        'mandate_id',                    v_m.id,
        'mandate_type',                  v_m.mandate_type,
        'representative_membership_id',  v_m.representative_membership_id,
        'principal_type',                v_m.principal_type,
        'principal_id',                  v_m.principal_id,
        'ends_at',                       v_m.ends_at,
        'hours_until_expiration',        round(v_hours, 2),
        'scope',                         v_m.scope
      )
    );

    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END;
$function$;

-- SECURITY DEFINER: invocable por edge function (service-role) o por admin.
REVOKE EXECUTE ON FUNCTION public.emit_mandate_expiring_events() FROM public, anon;
GRANT  EXECUTE ON FUNCTION public.emit_mandate_expiring_events() TO authenticated;

COMMENT ON FUNCTION public.emit_mandate_expiring_events() IS
  'V3-A4b (mig 20260530000400): emisor cron-invocable de mandate.expiring_in_24h. Scanea group_mandates con status=granted, revoked_at NULL, ends_at en próximas 24h. Idempotent vía dedup contra group_events del mismo mandate en últimas 24h. Retorna count de events emitidos. Diseñado para edge function con schedule diario; pg_cron no disponible en proyecto.';
