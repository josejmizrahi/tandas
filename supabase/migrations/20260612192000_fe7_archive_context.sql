-- ────────────────────────────────────────────────────────────────────────────
-- FE.7 (P1.4) — archivar contexto. Semántica conservadora (founder delegó):
-- acción peligrosa colectiva → governance PULL (default requiere voto,
-- overrideable por policy 'context_archive_requires_vote'); la historia se
-- conserva intacta (solo actors.archived_at — context_candidates ya filtra
-- `archived_at is null` desde F.NAV.3, así que desaparece de las listas de
-- todos los miembros sin tocar átomos). Reversible a futuro vía unarchive.
-- ────────────────────────────────────────────────────────────────────────────

-- 1) Catálogo R.7: acción gobernable.
insert into public.governance_action_catalog
  (action_key, display_name, domain, default_requires_decision, policy_key,
   execution_rpc, push_supported, dangerous)
values
  ('context.archive', 'Archivar espacio', 'contexts', true,
   'context_archive_requires_vote', 'archive_context', true, true)
on conflict (action_key) do nothing;

insert into public.activity_event_catalog (event_type, domain, description, expected_subject_type)
values ('context.archived', 'context', 'El espacio fue archivado', 'context')
on conflict (event_type) do nothing;

-- 2) RPC con PULL gate (patrón set_membership_state).
create or replace function public.archive_context(p_context_actor_id uuid)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_kind text;
  v_archived timestamptz;
  v_pol jsonb;
  v_ga uuid;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;

  select actor_kind, archived_at into v_kind, v_archived
    from public.actors where id = p_context_actor_id;
  if v_kind is null then
    raise exception 'context not found' using errcode = 'P0002';
  end if;
  if v_kind = 'person' then
    raise exception 'cannot archive a person actor' using errcode = '22023';
  end if;
  if v_archived is not null then
    return jsonb_build_object('context_actor_id', p_context_actor_id,
                              'archived', true, 'already_archived', true);
  end if;

  if not public.has_actor_authority(p_context_actor_id, v_caller, 'members.manage') then
    raise exception 'not authorized to archive this context' using errcode = '42501';
  end if;

  -- PULL gate: default requiere voto salvo policy explícita en false.
  v_pol := public.governance_policy(p_context_actor_id, 'context_archive_requires_vote');
  if v_pol is null or v_pol = 'true'::jsonb then
    v_ga := public._governance_action_approved(p_context_actor_id, 'context.archive', p_context_actor_id);
    if v_ga is null then
      raise exception 'governance_required: archiving this context requires an approved decision'
        using errcode = '42501',
        hint = 'call request_governance_action(context, ''context.archive'', ''actor'', context_id) and get it approved first';
    end if;
  end if;

  update public.actors
     set archived_at = now(), status = 'archived'
   where id = p_context_actor_id;

  perform public._emit_activity(p_context_actor_id, v_caller, 'context.archived', 'context',
    p_context_actor_id, '{}'::jsonb);

  return jsonb_build_object('context_actor_id', p_context_actor_id, 'archived', true);
end; $$;

revoke all on function public.archive_context(uuid) from public, anon;
grant execute on function public.archive_context(uuid) to authenticated, service_role;

comment on function public.archive_context(uuid) is
  'FE.7: archiva un contexto (actors.archived_at) tras aprobación governance (PULL, policy context_archive_requires_vote). La historia del grupo se conserva; context_candidates lo excluye.';

-- 3) Smoke
create or replace function public._smoke_mvp2_archive_context()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_auth_a uuid := gen_random_uuid();
  v_a uuid;
  v_ctx uuid;
  v_result jsonb;
  v_caught boolean := false;
begin
  v_a := public._create_person_actor_for_auth_user(v_auth_a, 'Smoke Arch A', '+520000000940', null);

  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_a::text)::text, true);
  v_result := public.create_context('_smoke_archive Club', 'collective', 'friend_group');
  v_ctx := (v_result->>'context_actor_id')::uuid;

  -- Sin decisión aprobada → governance_required.
  begin
    perform public.archive_context(v_ctx);
  exception when sqlstate '42501' then
    v_caught := true;
  end;
  if not v_caught then
    raise exception 'archive smoke: permitió archivar sin decisión aprobada';
  end if;

  -- Policy en false → directo.
  perform public.create_governance_policy(v_ctx, 'context_archive_requires_vote', 'false'::jsonb);
  v_result := public.archive_context(v_ctx);
  if not (v_result->>'archived')::boolean then
    raise exception 'archive smoke: archive_context no archivó con policy false';
  end if;
  if not exists (select 1 from public.actors where id = v_ctx and archived_at is not null) then
    raise exception 'archive smoke: archived_at no quedó seteado';
  end if;

  -- context_candidates ya no lo lista.
  v_result := public.context_candidates();
  if exists (
    select 1 from jsonb_array_elements(coalesce(v_result->'contexts', '[]'::jsonb)) c
    where (c->>'context_actor_id')::uuid = v_ctx
  ) then
    raise exception 'archive smoke: context_candidates sigue listando el contexto archivado';
  end if;

  -- Activity + idempotencia.
  if not exists (
    select 1 from public.activity_events
    where context_actor_id = v_ctx and event_type = 'context.archived'
  ) then
    raise exception 'archive smoke: activity context.archived no emitida';
  end if;
  v_result := public.archive_context(v_ctx);
  if not coalesce((v_result->>'already_archived')::boolean, false) then
    raise exception 'archive smoke: segunda llamada no fue no-op idempotente';
  end if;

  -- Cleanup (activity_events append-only — residuo aceptado).
  perform set_config('request.jwt.claims', null, true);
  delete from public.governance_policies where context_actor_id = v_ctx;
  delete from public.context_invites where context_actor_id = v_ctx;
  delete from public.role_assignments where context_actor_id = v_ctx;
  delete from public.role_permissions rp using public.roles r
    where r.id = rp.role_id and r.context_actor_id = v_ctx;
  delete from public.roles where context_actor_id = v_ctx;
  delete from public.actor_memberships where context_actor_id = v_ctx;
  delete from public.actor_relationships
    where subject_actor_id in (v_a, v_ctx) or object_actor_id in (v_a, v_ctx);
  delete from public.actors where id = v_ctx;
  delete from public.person_profiles where actor_id = v_a;
  delete from public.actors where id = v_a;
  delete from auth.users where id = v_auth_a;

  raise notice '_smoke_mvp2_archive_context passed';
end; $$;

revoke all on function public._smoke_mvp2_archive_context() from public, anon, authenticated;

comment on function public._smoke_mvp2_archive_context() is
  'Smoke MVP2: archive_context (governance_required sin decisión, directo con policy false, candidates lo excluye, idempotente).';
