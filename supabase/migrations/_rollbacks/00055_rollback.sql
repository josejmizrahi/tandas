-- Rollback for 00055_set_group_module_rpc.sql
--
-- Drops the RPC. The active_modules column is unchanged; any rows
-- already mutated by callers of this RPC remain mutated (correctly —
-- the data is consistent with the slice 1 trigger).

drop function if exists public.set_group_module(uuid, text, boolean);
