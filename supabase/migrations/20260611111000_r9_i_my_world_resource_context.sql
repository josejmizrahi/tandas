-- ============================================================================
-- R.9.I — my_world(): contexto dueño por recurso
-- ============================================================================
-- Gap (iOS R.5A/F.2X): los items de `resources` en my_world() no traían el
-- contexto dueño, así que MyResourcesView no podía construir
-- ResourceDetailViewV2 (que exige un AppContext real) y seguía colgada del
-- ResourceDetailView legacy (switch por resource_type, prohibido por F.2X).
--
-- Cambio ADITIVO: cada item de `resources` ahora incluye
--   · context_actor_id      — el contexto que posee/administra el recurso
--   · context_display_name  — su display name
--
-- Derivación canónica (misma asociación recurso→contexto que usan
-- list_context_resources / resource_detail, vía resources.canonical_owner_actor_id):
--   1. Si el canonical owner es un contexto (actor_kind collective/legal_entity)
--      → ese actor ES el contexto dueño.
--   2. Si el canonical owner es el propio caller (recurso personal) → el
--      contexto personal del caller = su person actor (en iOS "Mi espacio"
--      modela el contexto personal como el person actor mismo: AppContext con
--      kind == person e id == actor_id).
--   3. Si el canonical owner es OTRA persona (p. ej. veo la casa del abuelo
--      por un USE right) → null: el recurso no vive en un contexto operable
--      por mí; iOS hace fallback a mi contexto personal.
--
-- Sin cambios de schema. Sin tablas nuevas. Resto del body idéntico a R.2K.
-- ============================================================================

create or replace function public.my_world()
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_me uuid := public.current_actor_id();
begin
  if v_me is null then raise exception 'unauthenticated' using errcode = '28000'; end if;

  return jsonb_build_object(
    'actor_id', v_me,
    -- contextos donde soy miembro activo
    'contexts', coalesce((
      select jsonb_agg(jsonb_build_object(
        'context_actor_id', am.context_actor_id,
        'display_name', a.display_name,
        'actor_kind', a.actor_kind,
        'actor_subtype', a.actor_subtype,
        'membership_type', am.membership_type) order by a.display_name)
      from public.actor_memberships am
      join public.actors a on a.id = am.context_actor_id
      where am.member_actor_id = v_me and am.membership_status = 'active'), '[]'::jsonb),
    -- recursos visibles, agrupados por resource_id con reasons[] (sin duplicar filas):
    --   · mis rights directos activos
    --   · rights de holders colectivos que puedo ejercer (resources.manage)
    -- R.9.I: + context_actor_id / context_display_name (canonical owner cuando
    -- es contexto; el propio caller cuando el recurso es personal; null si el
    -- canonical owner es otra persona).
    'resources', coalesce((
      select jsonb_agg(jsonb_build_object(
        'resource_id', r.id,
        'display_name', r.display_name,
        'resource_type', r.resource_type,
        'context_actor_id', r.context_actor_id,
        'context_display_name', r.context_display_name,
        'reasons', r.reasons) order by r.display_name)
      from (
        select res.id, res.display_name, res.resource_type,
               case when ca.actor_kind in ('collective', 'legal_entity')
                      or res.canonical_owner_actor_id = v_me
                    then res.canonical_owner_actor_id end as context_actor_id,
               case when ca.actor_kind in ('collective', 'legal_entity')
                      or res.canonical_owner_actor_id = v_me
                    then ca.display_name end as context_display_name,
               jsonb_agg(distinct reason.path) as reasons
        from public.resources res
        left join public.actors ca on ca.id = res.canonical_owner_actor_id
        join lateral (
          select rr.right_kind as path
            from public.resource_rights rr
           where rr.resource_id = res.id and rr.holder_actor_id = v_me
             and rr.revoked_at is null and rr.expired_at is null
             and (rr.starts_at is null or rr.starts_at <= now())
             and (rr.ends_at is null or rr.ends_at > now())
          union all
          select rr.right_kind || ' via ' || h.display_name
            from public.resource_rights rr
            join public.actors h on h.id = rr.holder_actor_id
           where rr.resource_id = res.id and rr.holder_actor_id <> v_me
             and rr.revoked_at is null and rr.expired_at is null
             and (rr.starts_at is null or rr.starts_at <= now())
             and (rr.ends_at is null or rr.ends_at > now())
             and public.has_actor_authority(rr.holder_actor_id, v_me, 'resources.manage')
        ) reason on true
        where res.archived_at is null
        group by res.id, res.display_name, res.resource_type,
                 res.canonical_owner_actor_id, ca.actor_kind, ca.display_name
      ) r), '[]'::jsonb),
    -- mis obligations abiertas (como deudor o acreedor)
    'open_obligations', coalesce((
      select jsonb_agg(jsonb_build_object(
        'obligation_id', o.id,
        'context_actor_id', o.context_actor_id,
        'context_name', (select display_name from public.actors where id = o.context_actor_id),
        'role', case when o.debtor_actor_id = v_me then 'debtor' else 'creditor' end,
        'obligation_type', o.obligation_type,
        'amount', o.amount, 'currency', o.currency) order by o.created_at desc)
      from public.obligations o
      where (o.debtor_actor_id = v_me or o.creditor_actor_id = v_me) and o.status = 'open'), '[]'::jsonb));
end; $$;

revoke all on function public.my_world() from public, anon;
grant execute on function public.my_world() to authenticated, service_role;

comment on function public.my_world() is
  'R.2K + R.9.I: el mundo personal del actor — contextos, recursos visibles (agrupados con reasons[] + contexto dueño por recurso) y obligations abiertas propias. Nunca incluye información de contextos/actores ajenos.';

-- ────────────────────────────────────────────────────────────────────────────
-- Smoke
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public._smoke_mvp2_r9_i_my_world_context()
returns void
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  u_admin uuid; a_admin uuid;
  u_m uuid; a_m uuid;
  v_ctx uuid; v_code text;
  r_casa uuid; r_bici uuid;
  v_world jsonb;
  v_item jsonb;
begin
  select auth_id, actor_id into u_admin, a_admin from public._r2_make_person('Aldo R9I', '+5210000981');
  select auth_id, actor_id into u_m, a_m from public._r2_make_person('Memo R9I', '+5210000982');

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_admin::text)::text, true);
  v_ctx := (public.create_context('R9I Mundo', 'collective', 'friend_group'))->>'context_actor_id';
  v_code := (public.create_invite(v_ctx::uuid))->>'code';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_m::text)::text, true);
  perform public.join_by_invite_code(v_code);

  -- Recurso del contexto colectivo (canonical owner = el contexto) + USE al miembro
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_admin::text)::text, true);
  r_casa := (public.create_resource(v_ctx::uuid, 'house', 'R9I Casa'))->>'resource_id';
  perform public.grant_right(r_casa::uuid, a_m, 'USE');

  -- Recurso personal del miembro (canonical owner = su person actor)
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_m::text)::text, true);
  r_bici := (public.create_resource(a_m, 'vehicle', 'R9I Bici'))->>'resource_id';

  v_world := public.my_world();

  -- ═══ 1. El recurso del colectivo trae el contexto dueño ═══
  select r2 into v_item from jsonb_array_elements(v_world->'resources') r2
   where (r2->>'resource_id')::uuid = r_casa::uuid;
  if v_item is null then
    raise exception 'r9_i 1: my_world no devolvió el recurso del colectivo';
  end if;
  if (v_item->>'context_actor_id')::uuid is distinct from v_ctx::uuid then
    raise exception 'r9_i 1: context_actor_id esperado %, recibido %', v_ctx, v_item->>'context_actor_id';
  end if;
  if v_item->>'context_display_name' is distinct from 'R9I Mundo' then
    raise exception 'r9_i 1: context_display_name esperado "R9I Mundo", recibido %', v_item->>'context_display_name';
  end if;

  -- ═══ 2. El recurso personal trae el contexto personal (el person actor) ═══
  select r2 into v_item from jsonb_array_elements(v_world->'resources') r2
   where (r2->>'resource_id')::uuid = r_bici::uuid;
  if v_item is null then
    raise exception 'r9_i 2: my_world no devolvió el recurso personal';
  end if;
  if (v_item->>'context_actor_id')::uuid is distinct from a_m then
    raise exception 'r9_i 2: el recurso personal debe traer el person actor como contexto (esperado %, recibido %)',
      a_m, v_item->>'context_actor_id';
  end if;
  if v_item->>'context_display_name' is distinct from 'Memo R9I' then
    raise exception 'r9_i 2: context_display_name personal esperado "Memo R9I", recibido %', v_item->>'context_display_name';
  end if;

  -- ═══ 3. Shape previo intacto (reasons sigue presente y agrupado) ═══
  if not (v_item->'reasons' ? 'OWN') then
    raise exception 'r9_i 3: reasons del recurso personal perdió OWN: %', v_item->'reasons';
  end if;
  if (select count(*) from jsonb_array_elements(v_world->'resources') r2)
     <> (select count(distinct r2->>'resource_id') from jsonb_array_elements(v_world->'resources') r2) then
    raise exception 'r9_i 3: my_world duplica recursos tras el cambio';
  end if;

  -- Cleanup
  perform set_config('request.jwt.claims', null, true);
  perform public._r2_cleanup_context(v_ctx::uuid, array[a_admin, a_m], array[u_admin, u_m]);

  raise notice '_smoke_mvp2_r9_i_my_world_context passed (contexto dueño por recurso: colectivo + personal, shape intacto)';
end;
$$;

revoke all on function public._smoke_mvp2_r9_i_my_world_context() from public, anon, authenticated;

comment on function public._smoke_mvp2_r9_i_my_world_context() is
  'R.9.I: my_world() expone context_actor_id/context_display_name por recurso (canonical owner colectivo o contexto personal del caller).';
