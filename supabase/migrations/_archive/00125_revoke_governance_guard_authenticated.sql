-- 00125 — Reconcile remote: revoke EXECUTE from authenticated on
-- the governance guard trigger function.
--
-- 00124 issued `revoke from public, anon` but left `authenticated`
-- with EXECUTE, so the trigger function was callable directly as
-- `/rest/v1/rpc/guard_groups_governance_update` by any signed-in
-- user. Security advisor flagged it as
-- `authenticated_security_definer_function_executable` immediately
-- after 00124 applied.
--
-- The trigger fires via the function owner (postgres), not via the
-- caller's role, so revoking from authenticated does not break the
-- BEFORE UPDATE OF governance ON groups trigger. Idempotent: re-run
-- is a no-op.

revoke execute on function public.guard_groups_governance_update() from authenticated;
