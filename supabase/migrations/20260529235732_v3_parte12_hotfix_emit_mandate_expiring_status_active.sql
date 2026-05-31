-- PARTE 12 hot-fix: emit_mandate_expiring_events filtraba `status='granted'` que
-- NO existe en BD. grant_mandate inserta `status='active'`. Resultado: el emisor
-- V3-A4b nunca disparaba (siempre retornaba 0). Memoria project_v3_block_a_shipped.md
-- decía "✅ Idempotent" pero el filter principal estaba muerto.
--
-- Hot-fix paralelo a start_vote (decisions.propose→create): rename mechanical
-- al estado real. No requiere doctrina founder; ningún path inserta 'granted'.
--
-- Mantengo el rest del comportamiento idéntico, incluyendo:
--   - revoked_at IS NULL (defensa adicional sobre status).
--   - ends_at IN (now(), now()+24h].
--   - Idempotency guard (no duplica si ya hay event en último 24h).

CREATE OR REPLACE FUNCTION public.emit_mandate_expiring_events()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
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
     WHERE m.status      = 'active'
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

-- PARTE 8b posture: service_role only (cron-callable).
REVOKE ALL ON FUNCTION public.emit_mandate_expiring_events() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.emit_mandate_expiring_events() TO service_role;
