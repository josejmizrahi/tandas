-- V3-D.18 — patch _group_decisions_partial_guard: con el nuevo modelo,
-- 'passed' deja de ser terminal y pasa a ser un estado intermedio
-- (esperando execute_decision). Terminales reales: rejected, executed,
-- cancelled. La transición passed → executed es la ÚNICA permitida de
-- las cuatro mutaciones materiales — el guard sigue bloqueando todo lo
-- demás. Como ya hay datos viejos con status='passed', la regla de
-- "OLD ya en terminal" se evalúa contra la nueva lista; los rows
-- legacy 'passed' quedan mutables al nuevo branch executed (correcto).

CREATE OR REPLACE FUNCTION public._group_decisions_partial_guard()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public'
AS $function$
BEGIN
  -- D.18: 'passed' ya no es terminal — admite la transición a 'executed'.
  -- Terminales hard: rejected, executed, cancelled.
  IF OLD.status NOT IN ('rejected','executed','cancelled') THEN
    -- Pre-terminal. Una sola excepción del guard previo: si OLD='passed'
    -- y NEW='executed', dejamos la transición pasar; otros cambios siguen
    -- prohibidos (passed → open por ejemplo).
    IF OLD.status = 'passed' AND NEW.status <> OLD.status AND NEW.status <> 'executed' THEN
      RAISE EXCEPTION 'invalid transition from passed: %', NEW.status
        USING errcode = '23514';
    END IF;
    RETURN NEW;
  END IF;

  -- En estado terminal: bloquear mutación de campos materiales.
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
  RETURN NEW;
END;
$function$;

COMMENT ON FUNCTION public._group_decisions_partial_guard() IS
  'V3-D.18 — terminal now = rejected/executed/cancelled. Allows passed → executed transition; everything else from passed is blocked.';
