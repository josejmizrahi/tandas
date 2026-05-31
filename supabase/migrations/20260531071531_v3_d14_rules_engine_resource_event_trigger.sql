-- V3 FASE D.14 — Mig B: AFTER INSERT trigger on group_events that fires the engine
-- on every resource.* event. Chosen over patching 17 RPCs:
--   - single deterministic wiring point
--   - zero churn to lifecycle RPCs
--   - filtered to resource.* so money/decisions/etc unaffected
-- Depth bound via existing GUC ruul.rule_eval_depth (max 5). Idempotency via
-- existing UNIQUE(idempotency_key). Failed consequences captured as
-- status='failed' in actions_emitted, never bubbled up to abort the host txn.

BEGIN;

CREATE OR REPLACE FUNCTION public._trigger_evaluate_resource_event()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.event_type LIKE 'resource.%' THEN
    PERFORM public.evaluate_rules_for_event(NEW.uuid_id, 'sync', NULL);
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS group_events_resource_eval_trg ON public.group_events;
CREATE TRIGGER group_events_resource_eval_trg
  AFTER INSERT ON public.group_events
  FOR EACH ROW
  EXECUTE FUNCTION public._trigger_evaluate_resource_event();

COMMIT;
