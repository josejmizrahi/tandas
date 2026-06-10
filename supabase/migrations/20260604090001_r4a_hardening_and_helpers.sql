-- =============================================================================
-- R.4A · Hardening + helpers
-- =============================================================================
-- Additive, backward-compatible. No renames. No contract changes.
-- Closes structural gaps surfaced by the R.4A audit:
--   1. Missing updated_at trigger on trust_edges (only table without it).
--   2. Missing non-partial operational index on resources(created_by_actor_id).
--      The existing idx_resources_client_id is partial (WHERE client_id IS NOT NULL).
--   3. actors.is_context boolean: canonical "this actor is operationally usable
--      as a context" flag, with backfill + partial index.
--   4. Helpers:
--        is_context_actor(uuid)
--        current_person_actor_id()     -- explicit alias of current_actor_id()
--        actor_has_permission(actor, ctx, perm)  -- arg-reordered wrapper
--          over has_actor_authority(ctx, actor, perm).
-- All other items from R.4A scope (XOR check, idempotency indexes, every other
-- unique constraint, every other updated_at trigger) were already in place.
-- =============================================================================

-- 1. updated_at trigger for trust_edges -------------------------------------
do $$
begin
  if not exists (
    select 1 from pg_trigger t
    join pg_class c on c.oid = t.tgrelid
    where c.relname = 'trust_edges'
      and not t.tgisinternal
      and pg_get_triggerdef(t.oid) ilike '%updated_at%'
  ) then
    create trigger trust_edges_set_updated_at
      before update on public.trust_edges
      for each row execute function public.touch_updated_at();
  end if;
end$$;

-- 2. Operational index resources(created_by_actor_id) -----------------------
create index if not exists idx_resources_created_by
  on public.resources(created_by_actor_id)
  where archived_at is null;

-- 3. actors.is_context column ----------------------------------------------
do $$
begin
  if not exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='actors' and column_name='is_context'
  ) then
    alter table public.actors
      add column is_context boolean not null default false;

    -- Backfill: any actor with an operational subtype is a context.
    update public.actors
       set is_context = true
     where actor_subtype in (
       'friend_group','family','company','trust','trip','community','project'
     );
  end if;
end$$;

-- Partial index — only the subset we actually query as contexts.
create index if not exists idx_actors_is_context
  on public.actors(is_context)
  where is_context = true;

-- 4. Helpers ----------------------------------------------------------------

-- 4a. is_context_actor(uuid): is this actor flagged as a context?
create or replace function public.is_context_actor(p_actor_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (select is_context from public.actors where id = p_actor_id),
    false
  );
$$;

-- 4b. current_person_actor_id(): explicit name for the person actor
-- behind auth.uid(). Semantically identical to current_actor_id().
create or replace function public.current_person_actor_id()
returns uuid
language sql
stable
security definer
set search_path = public, auth
as $$
  select actor_id
    from public.person_profiles
   where auth_user_id = auth.uid();
$$;

-- 4c. actor_has_permission(actor, ctx, perm):
-- Consolidated wrapper around has_actor_authority(ctx, member, perm) with the
-- (actor, ctx, perm) arg order requested by callers. Same semantics:
--   - self-context: full authority
--   - role_assignments active in window
--   - role_permissions.allowed = true
--   - membership_status = 'active'
create or replace function public.actor_has_permission(
  p_actor_id uuid,
  p_context_actor_id uuid,
  p_permission_key text
)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.has_actor_authority(
    p_context_actor_id,
    p_actor_id,
    p_permission_key
  );
$$;

-- GRANT EXECUTE per backend doctrine ---------------------------------------
revoke all on function public.is_context_actor(uuid)        from anon;
revoke all on function public.current_person_actor_id()      from anon;
revoke all on function public.actor_has_permission(uuid, uuid, text) from anon;

grant execute on function public.is_context_actor(uuid)         to authenticated, service_role;
grant execute on function public.current_person_actor_id()      to authenticated, service_role;
grant execute on function public.actor_has_permission(uuid, uuid, text) to authenticated, service_role;
