-- Rollback for 00046 — drop start_fine_appeal helper.

drop function if exists public.start_fine_appeal(uuid, text);
