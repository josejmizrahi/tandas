
create or replace function public._smoke_r4a_hardening_helpers()
returns void
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_auth_a uuid := gen_random_uuid();
  v_person uuid;
  v_familia uuid;
  v_other_person uuid;
  v_auth_b uuid := gen_random_uuid();
  v_te_id uuid;
  v_te_orig timestamptz;
  v_te_new  timestamptz;
  v_new_actor_id uuid := gen_random_uuid();
  v_back_count integer;
  v_canonical boolean;
  v_alias boolean;
begin
  v_person := public._create_person_actor_for_auth_user(
    v_auth_a, '_smoke_r4a founder', '+520000000940', null
  );
  v_other_person := public._create_person_actor_for_auth_user(
    v_auth_b, '_smoke_r4a outsider', '+520000000941', null
  );

  perform set_config('request.jwt.claims',
    jsonb_build_object('sub', v_auth_a::text)::text, true);

  v_familia := (
    public.create_context('_smoke_r4a Familia','collective','family')
      ->>'context_actor_id'
  )::uuid;

  -- C1: trust_edges trigger registered correctly
  if not exists (
    select 1
      from pg_trigger t
      join pg_class c on c.oid = t.tgrelid
      join pg_proc  f on f.oid = t.tgfoid
     where c.relname = 'trust_edges'
       and f.proname = 'touch_updated_at'
       and not t.tgisinternal
  ) then
    raise exception 'r4a C1: trust_edges has no trigger bound to touch_updated_at';
  end if;

  -- C1b: trigger actually fires (sets updated_at to txn now())
  v_te_id := gen_random_uuid();
  insert into public.trust_edges(
    id, source_actor_id, target_actor_id, trust_level, trust_type
  )
  values (v_te_id, v_person, v_other_person, 3, 'personal');

  select updated_at into v_te_orig from public.trust_edges where id = v_te_id;
  update public.trust_edges set trust_level = 4 where id = v_te_id;
  select updated_at into v_te_new from public.trust_edges where id = v_te_id;

  if v_te_new is null or v_te_new < v_te_orig or v_te_new <> now() then
    raise exception 'r4a C1b: trust_edges trigger did not set updated_at to now() (orig=% new=% txn_now=%)',
      v_te_orig, v_te_new, now();
  end if;

  -- C2: actors.is_context derived for fresh insert (person → false)
  insert into public.actors(id, actor_kind, actor_subtype, display_name)
    values (v_new_actor_id, 'person', 'person', '_smoke_r4a default check');

  if (select is_context from public.actors where id = v_new_actor_id) <> false then
    raise exception 'r4a C2: is_context not false for person subtype';
  end if;

  -- C2b: collective/family insert via create_context → is_context true (trigger derived)
  if (select is_context from public.actors where id = v_familia) <> true then
    raise exception 'r4a C2b: create_context did not yield is_context = true';
  end if;

  -- C3: all 7 operational subtypes are flagged
  select count(*) into v_back_count
    from public.actors
   where actor_subtype in ('friend_group','family','company','trust','trip','community','project')
     and is_context = false;

  if v_back_count <> 0 then
    raise exception 'r4a C3: % operational actors not flagged', v_back_count;
  end if;

  if exists (
    select 1 from public.actors
    where actor_subtype in ('person','system') and is_context = true
  ) then
    raise exception 'r4a C3b: person/system actor incorrectly flagged is_context';
  end if;

  -- C4
  if public.is_context_actor(v_familia) is not true then
    raise exception 'r4a C4: is_context_actor(familia) returned false';
  end if;

  -- C5
  if public.is_context_actor(v_person) is not false then
    raise exception 'r4a C5: is_context_actor(person) returned true';
  end if;

  -- C6
  if public.is_context_actor(gen_random_uuid()) is not false then
    raise exception 'r4a C6: is_context_actor(missing) did not return false';
  end if;

  -- C7
  if public.current_person_actor_id() is distinct from v_person then
    raise exception 'r4a C7a: current_person_actor_id did not return founder';
  end if;
  if public.current_person_actor_id() is distinct from public.current_actor_id() then
    raise exception 'r4a C7b: current_person_actor_id <> current_actor_id';
  end if;

  -- C8
  v_canonical := public.has_actor_authority(v_familia, v_person, 'members.manage');
  v_alias     := public.actor_has_permission(v_person, v_familia, 'members.manage');
  if v_canonical is distinct from v_alias then
    raise exception 'r4a C8a: founder perm divergence canonical=% alias=%', v_canonical, v_alias;
  end if;
  if v_canonical is not true then
    raise exception 'r4a C8b: founder lacks members.manage (seed broken?)';
  end if;

  v_canonical := public.has_actor_authority(v_familia, v_other_person, 'members.manage');
  v_alias     := public.actor_has_permission(v_other_person, v_familia, 'members.manage');
  if v_canonical is distinct from v_alias then
    raise exception 'r4a C8c: outsider perm divergence canonical=% alias=%', v_canonical, v_alias;
  end if;
  if v_canonical is not false then
    raise exception 'r4a C8d: outsider unexpectedly has members.manage';
  end if;

  -- C9: self-context shortcut
  if public.actor_has_permission(v_person, v_person, 'arbitrary.permission') is not true then
    raise exception 'r4a C9: self-context shortcut failed';
  end if;

  -- C10
  if not exists (
    select 1 from pg_indexes
    where schemaname='public' and indexname='idx_actors_is_context'
  ) then
    raise exception 'r4a C10a: idx_actors_is_context missing';
  end if;
  if not exists (
    select 1 from pg_indexes
    where schemaname='public' and indexname='idx_resources_created_by'
  ) then
    raise exception 'r4a C10b: idx_resources_created_by missing';
  end if;

  -- Cleanup. activity_events stays; FK ON DELETE SET NULL handles dangling refs.
  perform set_config('request.jwt.claims', null, true);

  delete from public.trust_edges where id = v_te_id;
  delete from public.actors where id = v_new_actor_id;
  delete from public.role_assignments where context_actor_id = v_familia;
  delete from public.role_permissions rp using public.roles r
    where r.id = rp.role_id and r.context_actor_id = v_familia;
  delete from public.roles where context_actor_id = v_familia;
  delete from public.actor_memberships where context_actor_id = v_familia;
  delete from public.actors where id = v_familia;
  delete from public.person_profiles where actor_id in (v_person, v_other_person);
  delete from public.actors where id in (v_person, v_other_person);
  delete from auth.users where id in (v_auth_a, v_auth_b);

  raise notice '_smoke_r4a_hardening_helpers passed (11 casos)';
end;
$$;

revoke all on function public._smoke_r4a_hardening_helpers() from anon;
grant execute on function public._smoke_r4a_hardening_helpers() to service_role;
