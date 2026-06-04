-- ============================================================================
-- R.2V.2 — Duplicate candidates + relationship suggestions + merge candidates
-- ============================================================================
-- Lecturas agregadas sobre el motor R.2V.1. Sigue siendo read-only — NO emite
-- activity events, NO muta nada. Las emisiones de `duplicate.detected`,
-- `relationship.suggested`, `suggestion.dismissed` se cablearán cuando existan
-- acciones reales (R.2V.3 merge + R.2V.4 dismiss UI).
--
-- Thresholds (founder lock R.2V):
--   duplicate_candidates  >= 0.50 (sugerir)
--   merge_candidates      >= 0.85 (high confidence — la UI puede mostrar
--                                  "Posible duplicado fuerte" o similar)
--   relationship name     >= 0.40 (keyword común; menos exigente que duplicate)
--
-- Doctrina: los frontends NO calculan score; consumen jsonb directamente.
-- ============================================================================

-- ────────────────────────────────────────────────────────────────────────────
-- duplicate_candidates() — pares de contextos/recursos del caller con score
-- >= 0.50. Itera sobre los contextos del caller y agrega pares deduped.
-- Devuelve: { "contexts": [...], "resources": [...] }
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.duplicate_candidates(
  p_min_score numeric default 0.50,
  p_max_pairs int default 50
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_contexts_json jsonb := '[]'::jsonb;
  v_resources_json jsonb := '[]'::jsonb;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;

  -- Pares de contextos donde el caller es miembro de al menos uno. Deduplicamos
  -- ordenando por uuid asc para que sólo aparezca cada par una vez.
  with my_contexts as (
    select context_actor_id as id
      from public.actor_memberships
     where member_actor_id = v_caller and membership_status = 'active'
  ),
  candidate_pairs as (
    select
      least(c1.id, c2.id) as a_id,
      greatest(c1.id, c2.id) as b_id
      from my_contexts c1
      join my_contexts c2 on c1.id <> c2.id
  ),
  unique_pairs as (
    select distinct a_id, b_id from candidate_pairs
  ),
  scored as (
    select
      up.a_id, up.b_id,
      a.display_name as a_name, b.display_name as b_name,
      jsonb_array_elements(public.context_similarity(up.a_id)) as sim
      from unique_pairs up
      join public.actors a on a.id = up.a_id
      join public.actors b on b.id = up.b_id
  ),
  resolved as (
    select
      a_id, b_id, a_name, b_name,
      (sim->>'score')::numeric as score,
      sim->'reasons' as reasons
      from scored
     where (sim->>'context_id')::uuid = b_id
  )
  select jsonb_agg(jsonb_build_object(
      'a_context_id', r.a_id,
      'a_display_name', r.a_name,
      'b_context_id', r.b_id,
      'b_display_name', r.b_name,
      'score', r.score,
      'reasons', r.reasons
    ) order by r.score desc, r.a_name, r.b_name)
    into v_contexts_json
    from resolved r
   where r.score >= p_min_score
   limit p_max_pairs;

  v_contexts_json := coalesce(v_contexts_json, '[]'::jsonb);

  -- Pares de recursos del caller (vía contextos donde es miembro o rights propios).
  with my_resources as (
    select r.id
      from public.resources r
     where r.archived_at is null
       and (
         (r.canonical_owner_actor_id is not null and public.is_context_member(r.canonical_owner_actor_id))
         or exists (
           select 1 from public.resource_rights rr
            where rr.resource_id = r.id
              and rr.holder_actor_id = v_caller
              and rr.revoked_at is null
              and (rr.expired_at is null or rr.expired_at > now())
         )
       )
  ),
  candidate_pairs_r as (
    select
      least(r1.id, r2.id) as a_id,
      greatest(r1.id, r2.id) as b_id
      from my_resources r1
      join my_resources r2 on r1.id <> r2.id
  ),
  unique_pairs_r as (
    select distinct a_id, b_id from candidate_pairs_r
  ),
  scored_r as (
    select
      up.a_id, up.b_id,
      ra.display_name as a_name, rb.display_name as b_name,
      jsonb_array_elements(public.resource_similarity(up.a_id)) as sim
      from unique_pairs_r up
      join public.resources ra on ra.id = up.a_id
      join public.resources rb on rb.id = up.b_id
  ),
  resolved_r as (
    select
      a_id, b_id, a_name, b_name,
      (sim->>'score')::numeric as score,
      sim->'reasons' as reasons
      from scored_r
     where (sim->>'resource_id')::uuid = b_id
  )
  select jsonb_agg(jsonb_build_object(
      'a_resource_id', r.a_id,
      'a_display_name', r.a_name,
      'b_resource_id', r.b_id,
      'b_display_name', r.b_name,
      'score', r.score,
      'reasons', r.reasons
    ) order by r.score desc, r.a_name, r.b_name)
    into v_resources_json
    from resolved_r r
   where r.score >= p_min_score
   limit p_max_pairs;

  v_resources_json := coalesce(v_resources_json, '[]'::jsonb);

  return jsonb_build_object(
    'contexts', v_contexts_json,
    'resources', v_resources_json,
    'threshold', p_min_score,
    'as_of', now()
  );
end;
$$;

revoke all on function public.duplicate_candidates(numeric, int) from public, anon;
grant execute on function public.duplicate_candidates(numeric, int) to authenticated, service_role;

comment on function public.duplicate_candidates(numeric, int) is
  'R.2V.2: pares de contextos/recursos del caller con score >= threshold (default 0.50). Deduped, sort score desc.';

-- ────────────────────────────────────────────────────────────────────────────
-- merge_candidates() — subset de duplicate_candidates con score >= 0.85.
-- "High confidence": la UI puede ofrecer "Fusionar" sin más confirmación.
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.merge_candidates()
returns jsonb
language sql
stable
security definer
set search_path = public, auth
as $$
  select public.duplicate_candidates(0.85, 50);
$$;

revoke all on function public.merge_candidates() from public, anon;
grant execute on function public.merge_candidates() to authenticated, service_role;

comment on function public.merge_candidates() is
  'R.2V.2: candidatos de merge (score >= 0.85). Wrapper de duplicate_candidates.';

-- ────────────────────────────────────────────────────────────────────────────
-- relationship_suggestions(p_actor_id) — sugiere relaciones `contains` entre
-- pares de contextos del actor donde:
--   1. name trgm >= 0.40 (keyword común — p.ej. "Proyecto Nave" + "Fideicomiso Nave")
--   2. No son duplicados fuertes (score < 0.85)
--   3. No existe ya una relación contains activa entre ellos
--
-- Confidence (0–1) = name trgm score. La UI decide presentación; el backend no
-- propone "cuál es padre / hijo": ambos campos van. Default direction = (a → b)
-- por uuid asc para idempotencia.
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.relationship_suggestions(
  p_actor_id uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_target_actor uuid := coalesce(p_actor_id, v_caller);
  v_result jsonb;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  -- Sólo el propio actor puede consultar sus sugerencias.
  if v_target_actor <> v_caller then
    raise exception 'cannot query relationship suggestions for another actor' using errcode = '42501';
  end if;

  with my_contexts as (
    select context_actor_id as id, a.display_name
      from public.actor_memberships am
      join public.actors a on a.id = am.context_actor_id
     where am.member_actor_id = v_target_actor
       and am.membership_status = 'active'
       and a.archived_at is null
       and a.actor_kind in ('collective', 'legal_entity')
  ),
  pairs as (
    select
      least(c1.id, c2.id) as a_id,
      greatest(c1.id, c2.id) as b_id,
      case when c1.id < c2.id then c1.display_name else c2.display_name end as a_name,
      case when c1.id < c2.id then c2.display_name else c1.display_name end as b_name
      from my_contexts c1
      join my_contexts c2 on c1.id <> c2.id
  ),
  unique_pairs as (
    select distinct a_id, b_id, a_name, b_name from pairs
  ),
  scored as (
    select
      up.a_id, up.b_id, up.a_name, up.b_name,
      similarity(up.a_name, up.b_name)::numeric as name_score
      from unique_pairs up
     where similarity(up.a_name, up.b_name) >= 0.40
       and not exists (
         select 1 from public.actor_relationships ar
          where ar.relationship_type = 'contains'
            and ((ar.subject_actor_id = up.a_id and ar.object_actor_id = up.b_id)
              or (ar.subject_actor_id = up.b_id and ar.object_actor_id = up.a_id))
            and (ar.ends_at is null or ar.ends_at > now())
       )
  )
  select jsonb_agg(jsonb_build_object(
      'suggested_relationship', 'contains',
      'a_context_id', s.a_id,
      'a_display_name', s.a_name,
      'b_context_id', s.b_id,
      'b_display_name', s.b_name,
      'confidence', round(s.name_score, 4),
      'reasons', jsonb_build_array(
        case when s.name_score >= 0.70 then 'name_strong_match'
             when s.name_score >= 0.40 then 'name_partial_match'
             else 'name_weak_match'
        end
      )
    ) order by s.name_score desc, s.a_name, s.b_name)
    into v_result
    from scored s;

  return coalesce(v_result, '[]'::jsonb);
end;
$$;

revoke all on function public.relationship_suggestions(uuid) from public, anon;
grant execute on function public.relationship_suggestions(uuid) to authenticated, service_role;

comment on function public.relationship_suggestions(uuid) is
  'R.2V.2: sugiere `contains` entre pares de contextos del actor con name trgm >= 0.40 sin contains activo. Default actor = caller.';
