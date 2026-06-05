-- R.2V.4.2: bajar threshold del creation guard de 0.60 → 0.40 para que
-- prefijos cortos típicos del usuario ("Casa", "Cuenta", "Proyecto") emerjan
-- candidates en lugar de quedar bajo umbral pg_trgm.

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
   where s.name_score >= 0.40
   limit 10;

  return coalesce(v_result, '[]'::jsonb);
end;
$$;

comment on function public.context_creation_candidates(text) is
  'R.2V.4.2: creation guard para contextos. Devuelve hasta 10 candidatos con similarity >= 0.40.';

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
   where s.name_score >= 0.40
   limit 10;

  return coalesce(v_result, '[]'::jsonb);
end;
$$;

comment on function public.resource_creation_candidates(text, uuid) is
  'R.2V.4.2: creation guard para recursos dentro de un contexto. Devuelve hasta 10 candidatos con similarity >= 0.40.';
