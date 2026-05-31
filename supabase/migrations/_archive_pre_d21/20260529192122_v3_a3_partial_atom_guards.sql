-- 20260529192122 — V3-A3: partial atom guards para notifications_outbox y group_decisions.
--
-- Cierra §1.2-(12) "Faltan guards (decisión pendiente)".
-- group_rule_evaluations YA tiene guard completo (verificado §0.2); aquí cubrimos
-- las dos tablas restantes con guards parciales que respetan el lifecycle real:
--
-- notifications_outbox:
--   Mutables (cron drain): dispatch_status, attempts, last_error, dispatched_at.
--   Inmutables: id, group_id, recipient_user_id, category, payload, created_at.
--
-- group_decisions:
--   Terminales = status ∈ ('passed','rejected'). Verificado vía SELECT DISTINCT;
--   "closed" del doc no existe en el dominio real.
--   Tras terminal: bloquear cambios materiales (decision_type, method, result,
--   thresholds, legitimacy_source, status reversión, etc.). updated_at sí puede
--   refrescar (el trigger set_updated_at lo hace en cada UPDATE legítimo).

CREATE OR REPLACE FUNCTION public._notifications_outbox_partial_guard()
RETURNS trigger
LANGUAGE plpgsql AS $function$
BEGIN
  IF NEW.id              IS DISTINCT FROM OLD.id              THEN RAISE EXCEPTION 'immutable: notifications_outbox.id'              USING errcode = '23514'; END IF;
  IF NEW.group_id        IS DISTINCT FROM OLD.group_id        THEN RAISE EXCEPTION 'immutable: notifications_outbox.group_id'        USING errcode = '23514'; END IF;
  IF NEW.recipient_user_id IS DISTINCT FROM OLD.recipient_user_id THEN RAISE EXCEPTION 'immutable: notifications_outbox.recipient_user_id' USING errcode = '23514'; END IF;
  IF NEW.category        IS DISTINCT FROM OLD.category        THEN RAISE EXCEPTION 'immutable: notifications_outbox.category'        USING errcode = '23514'; END IF;
  IF NEW.payload         IS DISTINCT FROM OLD.payload         THEN RAISE EXCEPTION 'immutable: notifications_outbox.payload'         USING errcode = '23514'; END IF;
  IF NEW.created_at      IS DISTINCT FROM OLD.created_at      THEN RAISE EXCEPTION 'immutable: notifications_outbox.created_at'      USING errcode = '23514'; END IF;
  RETURN NEW;
END;
$function$;

COMMENT ON FUNCTION public._notifications_outbox_partial_guard() IS
  'V3-A3a (mig 20260529192122): partial atom guard. Solo dispatch_status, attempts, last_error, dispatched_at son mutables (cron drain). Resto inmutable.';

DROP TRIGGER IF EXISTS notifications_outbox_partial_guard ON public.notifications_outbox;
CREATE TRIGGER notifications_outbox_partial_guard
BEFORE UPDATE ON public.notifications_outbox
FOR EACH ROW
EXECUTE FUNCTION public._notifications_outbox_partial_guard();

CREATE OR REPLACE FUNCTION public._notifications_outbox_no_delete()
RETURNS trigger
LANGUAGE plpgsql AS $function$
BEGIN
  RAISE EXCEPTION 'notifications_outbox is append-only; deletion handled by retention cron only' USING errcode = '23514';
END;
$function$;

-- NOTE: cron retention podría querer DELETE. Cuando se implemente, ajustar.
DROP TRIGGER IF EXISTS notifications_outbox_no_delete ON public.notifications_outbox;
CREATE TRIGGER notifications_outbox_no_delete
BEFORE DELETE ON public.notifications_outbox
FOR EACH ROW
EXECUTE FUNCTION public._notifications_outbox_no_delete();

-- ----------------------------------------------------------------------------
-- group_decisions partial guard
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public._group_decisions_partial_guard()
RETURNS trigger
LANGUAGE plpgsql AS $function$
BEGIN
  IF OLD.status NOT IN ('passed','rejected') THEN
    RETURN NEW;
  END IF;

  IF NEW.status            IS DISTINCT FROM OLD.status            THEN RAISE EXCEPTION 'immutable after terminal: group_decisions.status'            USING errcode = '23514'; END IF;
  IF NEW.decision_type     IS DISTINCT FROM OLD.decision_type     THEN RAISE EXCEPTION 'immutable after terminal: group_decisions.decision_type'     USING errcode = '23514'; END IF;
  IF NEW.method            IS DISTINCT FROM OLD.method            THEN RAISE EXCEPTION 'immutable after terminal: group_decisions.method'            USING errcode = '23514'; END IF;
  IF NEW.legitimacy_source IS DISTINCT FROM OLD.legitimacy_source THEN RAISE EXCEPTION 'immutable after terminal: group_decisions.legitimacy_source' USING errcode = '23514'; END IF;
  IF NEW.threshold_pct     IS DISTINCT FROM OLD.threshold_pct     THEN RAISE EXCEPTION 'immutable after terminal: group_decisions.threshold_pct'     USING errcode = '23514'; END IF;
  IF NEW.quorum_pct        IS DISTINCT FROM OLD.quorum_pct        THEN RAISE EXCEPTION 'immutable after terminal: group_decisions.quorum_pct'        USING errcode = '23514'; END IF;
  IF NEW.committee_only    IS DISTINCT FROM OLD.committee_only    THEN RAISE EXCEPTION 'immutable after terminal: group_decisions.committee_only'    USING errcode = '23514'; END IF;
  IF NEW.reference_kind    IS DISTINCT FROM OLD.reference_kind    THEN RAISE EXCEPTION 'immutable after terminal: group_decisions.reference_kind'    USING errcode = '23514'; END IF;
  IF NEW.reference_id      IS DISTINCT FROM OLD.reference_id      THEN RAISE EXCEPTION 'immutable after terminal: group_decisions.reference_id'      USING errcode = '23514'; END IF;
  IF NEW.result            IS DISTINCT FROM OLD.result            THEN RAISE EXCEPTION 'immutable after terminal: group_decisions.result'            USING errcode = '23514'; END IF;
  IF NEW.decided_at        IS DISTINCT FROM OLD.decided_at        THEN RAISE EXCEPTION 'immutable after terminal: group_decisions.decided_at'        USING errcode = '23514'; END IF;
  IF NEW.opens_at          IS DISTINCT FROM OLD.opens_at          THEN RAISE EXCEPTION 'immutable after terminal: group_decisions.opens_at'          USING errcode = '23514'; END IF;
  IF NEW.closes_at         IS DISTINCT FROM OLD.closes_at         THEN RAISE EXCEPTION 'immutable after terminal: group_decisions.closes_at'         USING errcode = '23514'; END IF;
  IF NEW.title             IS DISTINCT FROM OLD.title             THEN RAISE EXCEPTION 'immutable after terminal: group_decisions.title'             USING errcode = '23514'; END IF;
  IF NEW.body              IS DISTINCT FROM OLD.body              THEN RAISE EXCEPTION 'immutable after terminal: group_decisions.body'              USING errcode = '23514'; END IF;
  IF NEW.created_by        IS DISTINCT FROM OLD.created_by        THEN RAISE EXCEPTION 'immutable after terminal: group_decisions.created_by'        USING errcode = '23514'; END IF;
  IF NEW.created_at        IS DISTINCT FROM OLD.created_at        THEN RAISE EXCEPTION 'immutable after terminal: group_decisions.created_at'        USING errcode = '23514'; END IF;
  IF NEW.metadata          IS DISTINCT FROM OLD.metadata          THEN RAISE EXCEPTION 'immutable after terminal: group_decisions.metadata'          USING errcode = '23514'; END IF;
  -- updated_at se permite (set_updated_at lo refresca en cada UPDATE legítimo).
  RETURN NEW;
END;
$function$;

COMMENT ON FUNCTION public._group_decisions_partial_guard() IS
  'V3-A3b (mig 20260529192122): partial guard. Tras OLD.status ∈ (passed, rejected) ningún campo material cambia. updated_at queda mutable para set_updated_at trigger.';

DROP TRIGGER IF EXISTS group_decisions_partial_guard ON public.group_decisions;
CREATE TRIGGER group_decisions_partial_guard
BEFORE UPDATE ON public.group_decisions
FOR EACH ROW
EXECUTE FUNCTION public._group_decisions_partial_guard();
