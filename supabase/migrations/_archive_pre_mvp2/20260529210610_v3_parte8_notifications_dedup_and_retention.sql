-- V3 PARTE 8 — notifications_outbox dedup + retention-aware delete guard
--
-- Estado previo:
-- - Sin UNIQUE: si el engine emite la misma consequence dos veces
--   (retry, race en el dispatcher), el destinatario recibe duplicado.
-- - _notifications_outbox_no_delete hard-block: no hay path para
--   retention; los rows dispatched de hace meses se acumulan sin cota.
--
-- Cambios:
-- 1. UNIQUE partial index sobre (group_id, category, payload->>'idempotency_key')
--    WHERE payload ? 'idempotency_key'. Las RPCs que emiten deben
--    setear payload.idempotency_key cuando quieran dedup (opt-in).
--    Rows existentes (4 verified) no tienen idempotency_key → no
--    backfill drift.
-- 2. Relajar _notifications_outbox_no_delete: DELETE permitido cuando
--    OLD.dispatched_at IS NOT NULL AND OLD.dispatched_at < now() - 30d.
--    Permite que un cron de retention separado limpie histórico sin
--    bypass de RLS. Rows undispatched o recientes siguen bloqueados.

CREATE UNIQUE INDEX IF NOT EXISTS notifications_outbox_idempotency
  ON public.notifications_outbox(
    group_id,
    category,
    (payload->>'idempotency_key')
  )
  WHERE payload ? 'idempotency_key';

CREATE OR REPLACE FUNCTION public._notifications_outbox_no_delete()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
  IF OLD.dispatched_at IS NULL THEN
    RAISE EXCEPTION 'cannot delete undispatched notification (id=%, status=%)',
      OLD.id, OLD.dispatch_status
      USING errcode = '23514';
  END IF;
  IF OLD.dispatched_at > now() - interval '30 days' THEN
    RAISE EXCEPTION 'retention: notification % must be at least 30 days post-dispatch (dispatched_at=%)',
      OLD.id, OLD.dispatched_at
      USING errcode = '23514';
  END IF;
  RETURN OLD;
END;
$function$;

COMMENT ON INDEX public.notifications_outbox_idempotency IS
  'V3 PARTE 8: dedup partial UNIQUE. Las RPCs/engine que quieran idempotencia setean payload.idempotency_key. Opt-in: rows sin la clave no compiten por el slot.';

COMMENT ON FUNCTION public._notifications_outbox_no_delete() IS
  'V3 PARTE 8: relaxed guard. DELETE permitido solo cuando dispatched_at IS NOT NULL AND < now()-30d. Rows undispatched o recientes siguen bloqueados. Permite retention cron sin bypass de RLS.';
