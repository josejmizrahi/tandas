-- The 2-arg signature kept lingering after V2-G3.3 added a 3-arg
-- variant via CREATE OR REPLACE (PG treats different arg counts as
-- different functions). Drop the legacy 2-arg so the only resolvable
-- callable is the 3-arg one — which has DEFAULT NULL for the new
-- parent slot, keeping the existing `cast_vote` 2-arg call site
-- working without changes.
DROP FUNCTION IF EXISTS public.evaluate_rules_for_event(uuid, text);
