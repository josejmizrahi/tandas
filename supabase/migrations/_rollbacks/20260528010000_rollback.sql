-- Rollback for 20260528010000_promote_norm_to_rule.sql (V2-G6).
DROP FUNCTION IF EXISTS public.promote_norm_to_rule(uuid, text, integer);
