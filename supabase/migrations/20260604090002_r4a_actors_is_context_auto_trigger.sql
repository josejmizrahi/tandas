-- =============================================================================
-- R.4A · auto-maintain actors.is_context
-- =============================================================================
-- Without this, actors.is_context defaults to false on every fresh insert,
-- so contexts created via create_context() are not flagged.
-- This trigger derives is_context from actor_subtype on every INSERT/UPDATE,
-- keeping the column authoritative without requiring any caller to set it.
-- =============================================================================

create or replace function public._actors_set_is_context()
returns trigger
language plpgsql
as $$
begin
  new.is_context := new.actor_subtype in (
    'friend_group','family','company','trust','trip','community','project'
  );
  return new;
end;
$$;

drop trigger if exists actors_set_is_context on public.actors;
create trigger actors_set_is_context
  before insert or update of actor_subtype on public.actors
  for each row execute function public._actors_set_is_context();

-- Re-run the backfill in case any rows drifted.
update public.actors
   set is_context = (actor_subtype in (
     'friend_group','family','company','trust','trip','community','project'
   ))
 where is_context <> (actor_subtype in (
     'friend_group','family','company','trust','trip','community','project'
   ));
