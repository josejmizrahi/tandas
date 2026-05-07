-- 00041 rollback — Drop resource_id columns from fines + review_periods.
--
-- Safe because event_id remains the authoritative legacy reference
-- for V1 (cohabitation pattern). Any Phase 2 fine rows that used
-- ONLY resource_id would lose their reference — the rollback assumes
-- this hasn't shipped yet.

drop function if exists public.fines_resource_id_parity_check();

drop index if exists public.fine_review_periods_resource_id_idx;
alter table public.fine_review_periods
  drop column if exists resource_id;

drop index if exists public.fines_resource_id_idx;
alter table public.fines
  drop column if exists resource_id;
