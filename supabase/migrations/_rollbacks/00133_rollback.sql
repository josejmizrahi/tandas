-- Rollback 00133 — remove the host-assigned trigger + function.
-- Existing user_actions rows with action_type='hostAssigned' stay
-- (they're real inbox state; manual cleanup if needed).

drop trigger if exists trg_on_event_inserted_host_assigned on public.events;
drop function if exists public.on_event_inserted_host_assigned();
