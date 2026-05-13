-- Rollback 00136 — drop the balance projection views. No data to
-- preserve — these are read-time aggregations.

drop view if exists public.member_balances_per_resource;
drop view if exists public.member_balances_per_group;
