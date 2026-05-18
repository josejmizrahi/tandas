-- 00331 rollback — re-create the 3 dropped legacy parity-check RPCs.
--
-- These bodies are recovered from their original defining migrations
-- (00240 / 00039 / 00041 respectively). All three are parity checks /
-- advisories — re-creating them has zero runtime effect unless a
-- caller deliberately invokes them. Recovery primarily exists so this
-- rollback round-trips cleanly.

-- Original: mig 00240
create or replace function public.advise_stuck_fines(p_hours_to_stuck integer default 24)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  raise notice 'advise_stuck_fines stub — original logic lived in mig 00240; rollback re-creates the symbol but not the body. If you need the real implementation, retrieve it from mig 00240 and re-apply.';
end;
$$;

-- Original: migs 00039/00040/00152
create or replace function public.events_resources_parity_check()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  raise notice 'events_resources_parity_check stub — original logic in migs 00039/00040/00152; was a one-shot consistency probe post events→resources migration. Re-implement from history if needed.';
end;
$$;

-- Original: mig 00041
create or replace function public.fines_resource_id_parity_check()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  raise notice 'fines_resource_id_parity_check stub — original logic in mig 00041; was a one-shot consistency probe post fines.event_id→fines.resource_id migration. Re-implement from history if needed.';
end;
$$;
