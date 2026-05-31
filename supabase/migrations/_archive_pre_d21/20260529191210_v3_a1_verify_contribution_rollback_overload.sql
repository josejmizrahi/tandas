-- 20260529191210 — Rollback del overload erróneo creado en 20260529191108.
--
-- Hallazgo: la RPC verify_contribution(p_contribution_id, p_outcome, p_note)
-- YA existía y cubre el flow completo (verified|rejected + auto-reputation +
-- system_event + engine eval). El doc PrimitivesArchitecture.md indicaba
-- "deferido" pero la BD real ya tenía la implementación.
--
-- Esta mig elimina el overload 3-arg (uuid, uuid, text). La firma canónica
-- vigente es:
--   verify_contribution(p_contribution_id uuid, p_outcome text, p_note text)
--   RETURNS void

DROP FUNCTION IF EXISTS public.verify_contribution(uuid, uuid, text);
