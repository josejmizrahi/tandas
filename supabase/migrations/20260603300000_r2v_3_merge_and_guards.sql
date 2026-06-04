-- ============================================================================
-- R.2V.3 — Soft merge + creation guards + dismiss suggestion
-- ============================================================================
-- Doctrina founder-locked:
--   - Soft merge v1: marker `metadata.r2v.merged_into = target_id` en el source.
--     Source SIGUE visible (archived_at = NULL). Reversible vía unmerge_context.
--   - Soft merge NO mueve memberships, rights, resources ni activity.
--     Hard merge (mover datos) queda para futuro.
--   - merge_contexts requiere `context.manage` en el source.
--   - dismiss_suggestion emite `suggestion.dismissed` — el frontend filtra
--     localmente al leer activity.
--   - Creation guard: threshold sugerir 0.60, high_confidence 0.85.
-- ============================================================================

-- ────────────────────────────────────────────────────────────────────────────
-- merge_contexts(p_source, p_target) — SOFT
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.merge_contexts(
  p_source_context_id uuid,
  p_target_context_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_source record;
  v_target record;
  v_now timestamptz := now();
  v_existing_target uuid;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  if p_source_context_id is null or p_target_context_id is null then
    raise exception 'source and target required' using errcode = '22023';
  end if;
  if p_source_context_id = p_target_context_id then
    raise exception 'cannot merge a context with itself' using errcode = '22023';
  end if;

  select id, display_name, actor_kind, metadata, archived_at
    into v_source from public.actors where id = p_source_context_id;
  if v_source.id is null then
    raise exception 'source context not found' using errcode = 'P0002';
  end if;
  if v_source.archived_at is not null then
    raise exception 'source context is archived' using errcode = '22023';
  end if;
  if v_source.actor_kind not in ('collective', 'legal_entity') then
    raise exception 'source must be collective or legal_entity' using errcode = '22023';
  end if;

  select id, display_name, actor_kind, archived_at
    into v_target from public.actors where id = p_target_context_id;
  if v_target.id is null then
    raise exception 'target context not found' using errcode = 'P0002';
  end if;
  if v_target.archived_at is not null then
    raise exception 'target context is archived' using errcode = '22023';
  end if;
  if v_target.actor_kind not in ('collective', 'legal_entity') then
    raise exception 'target must be collective or legal_entity' using errcode = '22023';
  end if;

  if not public.has_actor_authority(p_source_context_id, v_caller, 'context.manage') then
    raise exception 'not authorized to merge source % (need context.manage)', p_source_context_id
      using errcode = '42501';
  end if;

  -- Idempotencia: si ya está merged_into el mismo target, no-op
  v_existing_target := (v_source.metadata->'r2v'->>'merged_into')::uuid;
  if v_existing_target is not null and v_existing_target = p_target_context_id then
    return jsonb_build_object(
      'source_context_id', p_source_context_id,
      'target_context_id', p_target_context_id,
      'status', 'soft_merged',
      'already_merged', true,
      'merged_at', v_source.metadata->'r2v'->>'merged_at'
    );
  end if;

  -- Si está merged a OTRO target, requerir unmerge primero (evita re-direcciones silenciosas)
  if v_existing_target is not null and v_existing_target <> p_target_context_id then
    raise exception 'source % already merged into % — unmerge first',
      p_source_context_id, v_existing_target using errcode = '22023';
  end if;

  -- Aplicar marker en metadata (no toca rights/members/resources/activity)
  update public.actors
     set metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object(
           'r2v', jsonb_build_object(
             'merged_into', p_target_context_id,
             'merge_status', 'soft_merged',
             'merged_at', v_now,
             'merged_by_actor_id', v_caller
           )
         )
   where id = p_source_context_id;

  -- Activity en ambos contextos
  perform public._emit_activity(p_source_context_id, v_caller, 'context.merged',
    'actor', p_target_context_id,
    jsonb_build_object(
      'merge_kind', 'soft',
      'target_context_id', p_target_context_id,
      'role', 'source'
    ));
  -- Si el caller también es miembro del target, registramos en su timeline también.
  if public.is_context_member(p_target_context_id) then
    perform public._emit_activity(p_target_context_id, v_caller, 'context.merged',
      'actor', p_source_context_id,
      jsonb_build_object(
        'merge_kind', 'soft',
        'source_context_id', p_source_context_id,
        'role', 'target'
      ));
  end if;

  return jsonb_build_object(
    'source_context_id', p_source_context_id,
    'target_context_id', p_target_context_id,
    'status', 'soft_merged',
    'already_merged', false,
    'merged_at', v_now
  );
end;
$$;
revoke all on function public.merge_contexts(uuid, uuid) from public, anon;
grant execute on function public.merge_contexts(uuid, uuid) to authenticated, service_role;

comment on function public.merge_contexts(uuid, uuid) is
  'R.2V.3: soft merge. Escribe metadata.r2v.merged_into en source. NO mueve datos. Reversible.';

-- ────────────────────────────────────────────────────────────────────────────
-- unmerge_context(p_source) — revierte el soft merge
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.unmerge_context(p_source_context_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_source record;
  v_previous_target uuid;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  select id, metadata into v_source from public.actors where id = p_source_context_id;
  if v_source.id is null then
    raise exception 'source context not found' using errcode = 'P0002';
  end if;
  if not public.has_actor_authority(p_source_context_id, v_caller, 'context.manage') then
    raise exception 'not authorized to unmerge source % (need context.manage)', p_source_context_id
      using errcode = '42501';
  end if;

  v_previous_target := (v_source.metadata->'r2v'->>'merged_into')::uuid;

  if v_previous_target is null then
    return jsonb_build_object(
      'source_context_id', p_source_context_id,
      'unmerged', false
    );
  end if;

  update public.actors
     set metadata = case
       when (metadata->'r2v') is null then metadata
       else metadata - 'r2v'
     end
   where id = p_source_context_id;

  perform public._emit_activity(p_source_context_id, v_caller, 'context.unmerged',
    'actor', v_previous_target,
    jsonb_build_object('previous_target_context_id', v_previous_target));

  return jsonb_build_object(
    'source_context_id', p_source_context_id,
    'previous_target_context_id', v_previous_target,
    'unmerged', true
  );
end;
$$;
revoke all on function public.unmerge_context(uuid) from public, anon;
grant execute on function public.unmerge_context(uuid) to authenticated, service_role;

comment on function public.unmerge_context(uuid) is
  'R.2V.3: revierte el soft merge. Limpia metadata.r2v. Idempotente.';

-- ────────────────────────────────────────────────────────────────────────────
-- context_creation_candidates(p_display_name) — creation guard
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.context_creation_candidates(p_display_name text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_name text := btrim(coalesce(p_display_name, ''));
  v_result jsonb;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  if length(v_name) = 0 then return '[]'::jsonb; end if;

  with my_contexts as (
    select a.id, a.display_name, a.actor_kind, a.actor_subtype
      from public.actor_memberships am
      join public.actors a on a.id = am.context_actor_id
     where am.member_actor_id = v_caller
       and am.membership_status = 'active'
       and a.archived_at is null
       and a.actor_kind in ('collective', 'legal_entity')
  ),
  scored as (
    select c.id, c.display_name, c.actor_kind, c.actor_subtype,
           similarity(v_name, c.display_name)::numeric as name_score
      from my_contexts c
  )
  select jsonb_agg(jsonb_build_object(
      'context_id', s.id,
      'display_name', s.display_name,
      'actor_kind', s.actor_kind,
      'actor_subtype', s.actor_subtype,
      'score', round(s.name_score, 4),
      'high_confidence', s.name_score >= 0.85,
      'reasons', case
        when s.name_score >= 0.85 then jsonb_build_array('name_strong_match')
        else jsonb_build_array('name_partial_match')
      end
    ) order by s.name_score desc, s.display_name)
    into v_result
    from scored s
   where s.name_score >= 0.60
   limit 10;

  return coalesce(v_result, '[]'::jsonb);
end;
$$;
revoke all on function public.context_creation_candidates(text) from public, anon;
grant execute on function public.context_creation_candidates(text) to authenticated, service_role;

comment on function public.context_creation_candidates(text) is
  'R.2V.3: creation guard para contextos. Devuelve hasta 10 candidatos con similarity >= 0.60.';

-- ────────────────────────────────────────────────────────────────────────────
-- resource_creation_candidates(p_display_name, p_context_id) — creation guard
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.resource_creation_candidates(
  p_display_name text,
  p_context_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_name text := btrim(coalesce(p_display_name, ''));
  v_result jsonb;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  if not public.is_context_member(p_context_id) then
    raise exception 'not a member of context %', p_context_id using errcode = '42501';
  end if;
  if length(v_name) = 0 then return '[]'::jsonb; end if;

  with ctx_resources as (
    select r.id, r.display_name, r.resource_type
      from public.resources r
     where r.canonical_owner_actor_id = p_context_id
       and r.archived_at is null
  ),
  scored as (
    select cr.id, cr.display_name, cr.resource_type,
           similarity(v_name, cr.display_name)::numeric as name_score
      from ctx_resources cr
  )
  select jsonb_agg(jsonb_build_object(
      'resource_id', s.id,
      'display_name', s.display_name,
      'resource_type', s.resource_type,
      'score', round(s.name_score, 4),
      'high_confidence', s.name_score >= 0.85,
      'reasons', case
        when s.name_score >= 0.85 then jsonb_build_array('name_strong_match')
        else jsonb_build_array('name_partial_match')
      end
    ) order by s.name_score desc, s.display_name)
    into v_result
    from scored s
   where s.name_score >= 0.60
   limit 10;

  return coalesce(v_result, '[]'::jsonb);
end;
$$;
revoke all on function public.resource_creation_candidates(text, uuid) from public, anon;
grant execute on function public.resource_creation_candidates(text, uuid) to authenticated, service_role;

comment on function public.resource_creation_candidates(text, uuid) is
  'R.2V.3: creation guard para recursos dentro de un contexto. Devuelve hasta 10 candidatos con similarity >= 0.60.';

-- ────────────────────────────────────────────────────────────────────────────
-- dismiss_suggestion(p_subject_a, p_subject_b, p_suggestion_type)
-- Emite `suggestion.dismissed`. La UI filtra al leer activity.
-- p_suggestion_type ∈ {context_duplicate, resource_duplicate, relationship_contains}.
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.dismiss_suggestion(
  p_subject_a uuid,
  p_subject_b uuid,
  p_suggestion_type text
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_pa uuid := least(p_subject_a, p_subject_b);
  v_pb uuid := greatest(p_subject_a, p_subject_b);
  v_context_a uuid;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  if p_subject_a is null or p_subject_b is null then
    raise exception 'subjects required' using errcode = '22023';
  end if;
  if p_subject_a = p_subject_b then
    raise exception 'subjects must differ' using errcode = '22023';
  end if;
  if p_suggestion_type is null or p_suggestion_type not in
     ('context_duplicate', 'resource_duplicate', 'relationship_contains') then
    raise exception 'invalid suggestion_type %', p_suggestion_type using errcode = '22023';
  end if;

  -- Para el context_actor_id del activity: si los subjects son contextos donde
  -- el caller es miembro, usar uno de ellos. Si son resources, usar su
  -- canonical_owner. Fallback: el primer contexto donde el caller es miembro.
  if p_suggestion_type in ('context_duplicate', 'relationship_contains') then
    -- subjects son contextos
    if public.is_context_member(v_pa) then
      v_context_a := v_pa;
    elsif public.is_context_member(v_pb) then
      v_context_a := v_pb;
    else
      raise exception 'not a member of either context' using errcode = '42501';
    end if;
  else
    -- resource_duplicate: resolver context via canonical_owner
    select r.canonical_owner_actor_id into v_context_a
      from public.resources r where r.id = v_pa
       and r.canonical_owner_actor_id is not null
       and public.is_context_member(r.canonical_owner_actor_id);
    if v_context_a is null then
      select r.canonical_owner_actor_id into v_context_a
        from public.resources r where r.id = v_pb
         and r.canonical_owner_actor_id is not null
         and public.is_context_member(r.canonical_owner_actor_id);
    end if;
    if v_context_a is null then
      raise exception 'no access to either resource''s context' using errcode = '42501';
    end if;
  end if;

  perform public._emit_activity(v_context_a, v_caller, 'suggestion.dismissed',
    'suggestion', null,
    jsonb_build_object(
      'suggestion_type', p_suggestion_type,
      'subject_a', v_pa,
      'subject_b', v_pb
    ));

  return jsonb_build_object(
    'subject_a', v_pa,
    'subject_b', v_pb,
    'suggestion_type', p_suggestion_type,
    'dismissed_at', now()
  );
end;
$$;
revoke all on function public.dismiss_suggestion(uuid, uuid, text) from public, anon;
grant execute on function public.dismiss_suggestion(uuid, uuid, text) to authenticated, service_role;

comment on function public.dismiss_suggestion(uuid, uuid, text) is
  'R.2V.3: emite suggestion.dismissed. La UI filtra duplicate_candidates/relationship_suggestions leyendo activity.';
