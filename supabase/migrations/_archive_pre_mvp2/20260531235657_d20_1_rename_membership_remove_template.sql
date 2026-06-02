-- D.20.1: rename decision.membership_remove display name from "Remover miembro" to
-- "Expulsar miembro" since its target_state is 'banned' (irreversible without a new
-- decision). The reversible counterpart is decision.membership_remove_reversible.
-- Naming previously misled admins into thinking "Remover" was the soft option.

UPDATE public.decision_templates_catalog
SET display_name = 'Expulsar miembro',
    description  = 'Expulsión irreversible (target_state=banned). Reinstalar requiere una nueva decisión.'
WHERE template_key = 'decision.membership_remove';

-- Verify the row exists and got updated (loud failure if mig is run against unexpected state)
DO $$
DECLARE v_n int;
BEGIN
  SELECT count(*) INTO v_n
  FROM public.decision_templates_catalog
  WHERE template_key = 'decision.membership_remove' AND display_name = 'Expulsar miembro';
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'D.20.1 rename failed: expected 1 row, got %', v_n;
  END IF;
END $$;
