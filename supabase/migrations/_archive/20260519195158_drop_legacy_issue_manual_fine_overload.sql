-- 00354 — Drop legacy 6-arg overload of issue_manual_fine.
--
-- Same dance as mig 00352 for fund writers. Mig 00353 added the 7-arg
-- p_client_id version via `create or replace function`, which leaves
-- the legacy 6-arg overload alongside. PostgREST routes by JSON body
-- keys → inconsistent idempotency depending on body shape. Drop the
-- legacy version so the V1-03 path is the only path.
--
-- The 7-arg version handles both call shapes — `p_client_id default null`.
--
-- Idempotent: `drop function if exists` is a no-op on a clean install.
--
-- Rollback
-- ========
-- _rollbacks/20260519195158_rollback.sql recreates the 6-arg overload as
-- a thin wrapper delegating to the 7-arg version with p_client_id=null.

drop function if exists public.issue_manual_fine(uuid, uuid, numeric, text, uuid, uuid);
