-- 00079 rollback — Drop the bare-group create_group_with_admin RPC.
--
-- Note: cannot fully restore the legacy overloads since the columns they
-- referenced (event_label, frequency_*, fund_*, etc.) were dropped by
-- BigBang (00078). Rolling back this migration leaves the project without
-- a working create_group_with_admin RPC. Use only if you're rolling back
-- 00078 in the same operation.

drop function if exists public.create_group_with_admin(
  text, text, text, text, text, text, text
);
