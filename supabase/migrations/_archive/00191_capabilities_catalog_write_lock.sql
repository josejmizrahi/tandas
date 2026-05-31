-- Mig 00191: Capabilities catalog write protection
--
-- `public.capabilities` is a CATALOG (28 rows) — global, not per-group,
-- not per-user. Mutations should happen only through migrations or
-- service_role one-offs, never via signed-in clients. Current state:
-- the only RLS policy is `capabilities_read_authenticated` (SELECT).
-- Without explicit INSERT/UPDATE/DELETE policies, RLS denies them by
-- default for `authenticated` — but the table grants come from the
-- default `TO authenticated` on `public.*` which Supabase issues. Belt
-- and suspenders: also REVOKE the table-level grants from authenticated
-- + anon, so even if an RLS policy gets added later by accident, the
-- table grant gates writes.

revoke insert, update, delete on public.capabilities from authenticated, anon, public;

-- Keep SELECT for authenticated (matches existing capabilities_read_authenticated).
-- service_role retains everything by default.

comment on table public.capabilities is
  'Global capability catalog (28 stable entries). Read-only for authenticated; writes only via migrations or service_role one-offs.';
