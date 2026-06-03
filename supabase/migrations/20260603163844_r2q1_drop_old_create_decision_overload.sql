-- R.2Q.1 — Eliminar la overload vieja (7 args) de create_decision para resolver ambigüedad.
-- La nueva signature (8 args, +p_voting_model) cubre todos los callers gracias al DEFAULT NULL.
DROP FUNCTION IF EXISTS public.create_decision(uuid, text, text, text, timestamptz, jsonb, text);
