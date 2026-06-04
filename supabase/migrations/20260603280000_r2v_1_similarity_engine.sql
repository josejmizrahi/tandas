-- ============================================================================
-- R.2V.1 — SIMILARITY ENGINE (read-only)
-- ============================================================================
-- Doctrina R.2V: Ruul debe asumir que los usuarios crean duplicados. No los
-- forzamos a modelar perfectamente — el sistema observa y sugiere. R.2V.1
-- entrega los dos motores de scoring (`context_similarity` + `resource_similarity`)
-- en modo read-only: no toca data, no muta nada, no propone merges.
--
-- Las RPCs de duplicados/sugerencias/merge/creation-guards llegan en R.2V.2-3.
-- iOS en R.2V.4.
--
-- Scoring (decidido founder):
--
--   context_similarity:
--     name        30%   trgm(display_name)
--     members     25%   Jaccard de actor_ids con membership activa
--     resources   20%   pares con trgm(display_name) > 0.5 / max(count)
--     decisions   10%   pares con trgm(title) > 0.5 / max(count)
--     obligations  5%   pares con trgm(title) > 0.5 / max(count)
--     documents   10%   pares con trgm(display_name) > 0.5 / max(count)
--
--   resource_similarity:
--     name        40%   trgm(display_name)
--     owners      30%   Jaccard de holder_actor_ids con right_kind='OWN' activos
--     type        15%   igual = 1 else 0
--     context     15%   mismo context_actor_id = 1 else 0
--
-- Threshold para incluir: score >= 0.30 (no spam). Sort score desc.
-- Reasons[] = strings semánticos para que la UI no calcule nada.
-- ============================================================================

create extension if not exists pg_trgm;

-- ────────────────────────────────────────────────────────────────────────────
-- Helper interno: similitud entre dos sets de textos via pg_trgm (paired).
-- Devuelve count_similar / greatest(count_a, count_b), 0 si ambos vacíos.
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public._r2v_text_set_similarity(
  p_a text[],
  p_b text[],
  p_threshold real default 0.5
)
returns numeric
language plpgsql
immutable
parallel safe
set search_path = public
as $$
declare
  v_count_similar int;
  v_max_count int;
begin
  if p_a is null or p_b is null then return 0; end if;
  v_max_count := greatest(coalesce(array_length(p_a, 1), 0),
                          coalesce(array_length(p_b, 1), 0));
  if v_max_count = 0 then return 0; end if;

  select count(*)
    into v_count_similar
    from unnest(p_a) as a
    join unnest(p_b) as b
      on similarity(coalesce(a, ''), coalesce(b, '')) >= p_threshold;

  return least(1.0, v_count_similar::numeric / v_max_count::numeric);
end;
$$;

revoke all on function public._r2v_text_set_similarity(text[], text[], real)
  from public, anon, authenticated;
grant execute on function public._r2v_text_set_similarity(text[], text[], real) to service_role;

-- ────────────────────────────────────────────────────────────────────────────
-- context_similarity(p_context_id) — devuelve hasta 20 candidatos similares
-- entre los contextos donde el caller es miembro activo. Excluye el propio.
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.context_similarity(p_context_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_source record;
  v_src_member_ids uuid[];
  v_src_resource_names text[];
  v_src_decision_titles text[];
  v_src_obligation_titles text[];
  v_src_document_titles text[];
  v_result jsonb := '[]'::jsonb;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  if not public.is_context_member(p_context_id) then
    raise exception 'not a member of context %', p_context_id using errcode = '42501';
  end if;

  -- Hidratar el contexto source
  select id, display_name into v_source from public.actors where id = p_context_id;
  if v_source.id is null then
    raise exception 'context not found' using errcode = 'P0002';
  end if;

  select array_agg(member_actor_id)
    into v_src_member_ids
    from public.actor_memberships
   where context_actor_id = p_context_id and membership_status = 'active';
  v_src_member_ids := coalesce(v_src_member_ids, '{}'::uuid[]);

  select array_agg(display_name)
    into v_src_resource_names
    from public.resources
   where canonical_owner_actor_id = p_context_id and archived_at is null;
  v_src_resource_names := coalesce(v_src_resource_names, '{}'::text[]);

  select array_agg(title)
    into v_src_decision_titles
    from public.decisions
   where context_actor_id = p_context_id and title is not null;
  v_src_decision_titles := coalesce(v_src_decision_titles, '{}'::text[]);

  select array_agg(coalesce(title, obligation_type))
    into v_src_obligation_titles
    from public.obligations
   where context_actor_id = p_context_id;
  v_src_obligation_titles := coalesce(v_src_obligation_titles, '{}'::text[]);

  select array_agg(title)
    into v_src_document_titles
    from public.documents
   where context_actor_id = p_context_id and archived_at is null;
  v_src_document_titles := coalesce(v_src_document_titles, '{}'::text[]);

  -- Para cada otro contexto donde el caller es miembro activo, calcular score.
  with candidates as (
    select a.id, a.display_name
      from public.actors a
      join public.actor_memberships am on am.context_actor_id = a.id
     where am.member_actor_id = v_caller
       and am.membership_status = 'active'
       and a.id <> p_context_id
       and a.archived_at is null
       and a.actor_kind in ('collective', 'legal_entity')
  ),
  scored as (
    select
      c.id,
      c.display_name,
      -- name: trgm pg_trgm 0..1
      coalesce(similarity(v_source.display_name, c.display_name), 0)::numeric as name_score,
      -- members: Jaccard sobre actor_ids
      (
        select case when (size_a + size_b - size_intersect) = 0 then 0
                    else size_intersect::numeric / (size_a + size_b - size_intersect)::numeric end
          from (
            select
              (select count(*) from unnest(v_src_member_ids) m1) as size_a,
              (select count(*) from public.actor_memberships
                where context_actor_id = c.id and membership_status = 'active') as size_b,
              (select count(*) from public.actor_memberships am2
                where am2.context_actor_id = c.id
                  and am2.membership_status = 'active'
                  and am2.member_actor_id = any(v_src_member_ids)) as size_intersect
          ) s
      ) as members_score,
      -- resources: pairs con trgm >= 0.5
      public._r2v_text_set_similarity(
        v_src_resource_names,
        coalesce((select array_agg(display_name) from public.resources
                   where canonical_owner_actor_id = c.id and archived_at is null),
                 '{}'::text[])
      ) as resources_score,
      -- decisions: por título
      public._r2v_text_set_similarity(
        v_src_decision_titles,
        coalesce((select array_agg(title) from public.decisions
                   where context_actor_id = c.id and title is not null),
                 '{}'::text[])
      ) as decisions_score,
      -- obligations
      public._r2v_text_set_similarity(
        v_src_obligation_titles,
        coalesce((select array_agg(coalesce(title, obligation_type))
                    from public.obligations where context_actor_id = c.id),
                 '{}'::text[])
      ) as obligations_score,
      -- documents
      public._r2v_text_set_similarity(
        v_src_document_titles,
        coalesce((select array_agg(title) from public.documents
                   where context_actor_id = c.id and archived_at is null),
                 '{}'::text[])
      ) as documents_score
      from candidates c
  ),
  weighted as (
    select
      id,
      display_name,
      name_score,
      members_score,
      resources_score,
      decisions_score,
      obligations_score,
      documents_score,
      round((
        name_score * 0.30
        + members_score * 0.25
        + resources_score * 0.20
        + decisions_score * 0.10
        + obligations_score * 0.05
        + documents_score * 0.10
      )::numeric, 4) as score
      from scored
  )
  select jsonb_agg(jsonb_build_object(
    'context_id', w.id,
    'display_name', w.display_name,
    'score', w.score,
    'reasons', (
      -- Reasons semánticos — la UI no calcula nada.
      select coalesce(jsonb_agg(reason), '[]'::jsonb)
        from (
          select 'same_name' as reason where w.name_score >= 0.85
          union all
          select 'similar_name' where w.name_score >= 0.5 and w.name_score < 0.85
          union all
          select 'shared_members' where w.members_score >= 0.5
          union all
          select 'shared_resources' where w.resources_score >= 0.5
          union all
          select 'shared_decisions' where w.decisions_score >= 0.5
          union all
          select 'shared_obligations' where w.obligations_score >= 0.5
          union all
          select 'shared_documents' where w.documents_score >= 0.5
        ) r
    ),
    'breakdown', jsonb_build_object(
      'name', w.name_score,
      'members', w.members_score,
      'resources', w.resources_score,
      'decisions', w.decisions_score,
      'obligations', w.obligations_score,
      'documents', w.documents_score
    )
  ) order by w.score desc, w.display_name)
    into v_result
    from weighted w
   where w.score >= 0.30
   limit 20;

  return coalesce(v_result, '[]'::jsonb);
end;
$$;

revoke all on function public.context_similarity(uuid) from public, anon;
grant execute on function public.context_similarity(uuid) to authenticated, service_role;

comment on function public.context_similarity(uuid) is
  'R.2V.1: candidatos similares al contexto entre los contextos donde el caller es miembro. Score 0–1, sort desc, threshold 0.30, top 20.';

-- ────────────────────────────────────────────────────────────────────────────
-- resource_similarity(p_resource_id) — devuelve hasta 20 recursos similares
-- entre los recursos visibles para el caller (vía RLS de resources).
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.resource_similarity(p_resource_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_source record;
  v_src_owner_ids uuid[];
  v_result jsonb := '[]'::jsonb;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;

  select id, display_name, resource_type, canonical_owner_actor_id as context_actor_id
    into v_source
    from public.resources
   where id = p_resource_id and archived_at is null;
  if v_source.id is null then
    raise exception 'resource not found or archived' using errcode = 'P0002';
  end if;

  -- Verificar acceso del caller al recurso source (miembro del contexto que lo
  -- contiene o holder de algún right activo).
  if not (
    (v_source.context_actor_id is not null and public.is_context_member(v_source.context_actor_id))
    or exists (
      select 1 from public.resource_rights rr
       where rr.resource_id = p_resource_id
         and rr.holder_actor_id = v_caller
         and rr.revoked_at is null
         and (rr.expired_at is null or rr.expired_at > now())
    )
  ) then
    raise exception 'no access to resource %', p_resource_id using errcode = '42501';
  end if;

  select array_agg(holder_actor_id)
    into v_src_owner_ids
    from public.resource_rights
   where resource_id = p_resource_id
     and right_kind = 'OWN'
     and revoked_at is null
     and (expired_at is null or expired_at > now());
  v_src_owner_ids := coalesce(v_src_owner_ids, '{}'::uuid[]);

  with candidates as (
    select r.id, r.display_name, r.resource_type, r.canonical_owner_actor_id as context_actor_id
      from public.resources r
     where r.id <> p_resource_id
       and r.archived_at is null
       -- Acceso: caller miembro del contexto o holder de un right activo
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
  scored as (
    select
      c.id, c.display_name, c.resource_type, c.context_actor_id,
      coalesce(similarity(v_source.display_name, c.display_name), 0)::numeric as name_score,
      -- owners Jaccard
      (
        select case when (size_a + size_b - size_intersect) = 0 then 0
                    else size_intersect::numeric / (size_a + size_b - size_intersect)::numeric end
          from (
            select
              (select count(*) from unnest(v_src_owner_ids) m) as size_a,
              (select count(*) from public.resource_rights
                where resource_id = c.id and right_kind = 'OWN'
                  and revoked_at is null and (expired_at is null or expired_at > now())) as size_b,
              (select count(*) from public.resource_rights rr2
                where rr2.resource_id = c.id and rr2.right_kind = 'OWN'
                  and rr2.revoked_at is null and (rr2.expired_at is null or rr2.expired_at > now())
                  and rr2.holder_actor_id = any(v_src_owner_ids)) as size_intersect
          ) s
      ) as owners_score,
      case when c.resource_type = v_source.resource_type then 1.0::numeric else 0::numeric end as type_score,
      case when c.context_actor_id = v_source.context_actor_id then 1.0::numeric else 0::numeric end as context_score
      from candidates c
  ),
  weighted as (
    select
      id, display_name, resource_type, context_actor_id,
      name_score, owners_score, type_score, context_score,
      round((
        name_score * 0.40
        + owners_score * 0.30
        + type_score * 0.15
        + context_score * 0.15
      )::numeric, 4) as score
      from scored
  )
  select jsonb_agg(jsonb_build_object(
    'resource_id', w.id,
    'display_name', w.display_name,
    'resource_type', w.resource_type,
    'context_actor_id', w.context_actor_id,
    'score', w.score,
    'reasons', (
      select coalesce(jsonb_agg(reason), '[]'::jsonb)
        from (
          select 'same_name' as reason where w.name_score >= 0.85
          union all
          select 'similar_name' where w.name_score >= 0.5 and w.name_score < 0.85
          union all
          select 'shared_owners' where w.owners_score >= 0.5
          union all
          select 'same_type' where w.type_score >= 0.99
          union all
          select 'same_context' where w.context_score >= 0.99
        ) r
    ),
    'breakdown', jsonb_build_object(
      'name', w.name_score,
      'owners', w.owners_score,
      'type', w.type_score,
      'context', w.context_score
    )
  ) order by w.score desc, w.display_name)
    into v_result
    from weighted w
   where w.score >= 0.30
   limit 20;

  return coalesce(v_result, '[]'::jsonb);
end;
$$;

revoke all on function public.resource_similarity(uuid) from public, anon;
grant execute on function public.resource_similarity(uuid) to authenticated, service_role;

comment on function public.resource_similarity(uuid) is
  'R.2V.1: candidatos similares al recurso, scope visible para el caller. Score 0–1, threshold 0.30, top 20.';
