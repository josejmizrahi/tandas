-- ============================================================================
-- F.NAV.0 — APP SHELL NAVIGATION BACKEND FOUNDATION
-- ============================================================================
-- Doctrina F.NAV (`Plans/Doctrine/FNAV_AppShellNavigation.md`):
--   El shell global gana tabs (Home / Contextos / Crear / Actividad / Yo).
--   Home muestra ATENCIÓN cross-context + Continuar (contextos recientes) +
--   acciones globales mínimas + actividad relevante.
--
-- Esta slice entrega los 5 RPCs + 1 tabla que el shell global necesita:
--
--   attention_inbox()                       — items que requieren acción del caller
--   mark_context_favorite(ctx, fav)         — toggle favorito por actor
--   mark_context_visited(ctx)               — registra visita (recency)
--   list_context_favorites()                — favoritos del caller
--   list_recent_contexts(limit)             — recientes del caller (ordered)
--
--   actor_context_preferences (table)       — un row por (actor, contexto) con
--                                              is_favorite + last_visited_at.
--
-- Doctrinal:
--   - Cada RPC es SECURITY DEFINER, GRANT EXECUTE a authenticated, service_role.
--   - mark_* exige is_context_member para evitar favoritar/visitar contextos ajenos.
--   - attention_inbox combina 4 fuentes (conflictos, votos, obligaciones,
--     invitaciones) ordenadas por occurred_at desc, máx 5 items.
--   - Cada item lleva cta_action_key compatible con F.2X ActionRouter.
-- ============================================================================

-- ────────────────────────────────────────────────────────────────────────────
-- 1. Tabla actor_context_preferences (favoritos + recency)
-- ────────────────────────────────────────────────────────────────────────────
create table public.actor_context_preferences (
  actor_id uuid not null references public.actors(id) on delete cascade,
  context_actor_id uuid not null references public.actors(id) on delete cascade,
  is_favorite boolean not null default false,
  favorited_at timestamptz,
  last_visited_at timestamptz,
  primary key (actor_id, context_actor_id)
);

create index idx_acp_actor_recent
  on public.actor_context_preferences (actor_id, last_visited_at desc nulls last);

create index idx_acp_actor_fav
  on public.actor_context_preferences (actor_id)
  where is_favorite;

comment on table public.actor_context_preferences is
  'F.NAV.0: preferencias del actor sobre un contexto (favorito + última visita). RLS: own-only read; writes vía RPCs SECDEF.';

alter table public.actor_context_preferences enable row level security;

-- RLS: el actor sólo ve sus propias preferencias.
create policy "acp own read" on public.actor_context_preferences
  for select using (actor_id = public.current_actor_id());

revoke all on table public.actor_context_preferences from public, anon;
grant select on table public.actor_context_preferences to authenticated;

-- ────────────────────────────────────────────────────────────────────────────
-- 2. mark_context_favorite(ctx, fav)
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.mark_context_favorite(
  p_context_actor_id uuid,
  p_is_favorite boolean default true
)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  if not public.is_context_member(p_context_actor_id) and v_caller <> p_context_actor_id then
    raise exception 'not a member of context %', p_context_actor_id using errcode = '42501';
  end if;

  insert into public.actor_context_preferences
    (actor_id, context_actor_id, is_favorite, favorited_at)
  values
    (v_caller, p_context_actor_id, p_is_favorite,
     case when p_is_favorite then now() else null end)
  on conflict (actor_id, context_actor_id) do update set
    is_favorite = excluded.is_favorite,
    favorited_at = case when excluded.is_favorite then now() else null end;

  return jsonb_build_object(
    'context_actor_id', p_context_actor_id,
    'is_favorite', p_is_favorite
  );
end; $$;

revoke all on function public.mark_context_favorite(uuid, boolean) from public, anon;
grant execute on function public.mark_context_favorite(uuid, boolean) to authenticated, service_role;
comment on function public.mark_context_favorite(uuid, boolean) is
  'F.NAV.0: toggle favorito del caller sobre un contexto donde es miembro.';

-- ────────────────────────────────────────────────────────────────────────────
-- 3. mark_context_visited(ctx)
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.mark_context_visited(
  p_context_actor_id uuid
)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  -- clock_timestamp() (no now()) para distinguir visitas dentro de la misma
  -- transacción — útil para batch / smokes; en producción cada RPC corre en
  -- su propia tx así que no cambia el comportamiento.
  v_now timestamptz := clock_timestamp();
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  -- También aceptamos visitar el contexto personal (caller = ctx).
  if not public.is_context_member(p_context_actor_id) and v_caller <> p_context_actor_id then
    raise exception 'not a member of context %', p_context_actor_id using errcode = '42501';
  end if;

  insert into public.actor_context_preferences
    (actor_id, context_actor_id, last_visited_at)
  values
    (v_caller, p_context_actor_id, v_now)
  on conflict (actor_id, context_actor_id) do update set
    last_visited_at = v_now;

  return jsonb_build_object(
    'context_actor_id', p_context_actor_id,
    'last_visited_at', v_now
  );
end; $$;

revoke all on function public.mark_context_visited(uuid) from public, anon;
grant execute on function public.mark_context_visited(uuid) to authenticated, service_role;
comment on function public.mark_context_visited(uuid) is
  'F.NAV.0: registra que el caller visitó el contexto (usa clock_timestamp para distinguir visitas dentro de la misma tx).';

-- ────────────────────────────────────────────────────────────────────────────
-- 4. list_context_favorites()
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.list_context_favorites()
returns jsonb
language plpgsql stable security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'context_actor_id', a.id,
      'display_name', a.display_name,
      'actor_kind', a.actor_kind,
      'actor_subtype', a.actor_subtype,
      'favorited_at', p.favorited_at,
      'last_visited_at', p.last_visited_at
    ) order by p.favorited_at desc nulls last)
    from public.actor_context_preferences p
    join public.actors a on a.id = p.context_actor_id
    where p.actor_id = v_caller and p.is_favorite
  ), '[]'::jsonb);
end; $$;

revoke all on function public.list_context_favorites() from public, anon;
grant execute on function public.list_context_favorites() to authenticated, service_role;
comment on function public.list_context_favorites() is
  'F.NAV.0: lista los contextos favoritos del caller (más recientemente favoriteados primero).';

-- ────────────────────────────────────────────────────────────────────────────
-- 5. list_recent_contexts(limit)
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.list_recent_contexts(p_limit int default 5)
returns jsonb
language plpgsql stable security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  if p_limit is null or p_limit < 1 then p_limit := 5; end if;
  if p_limit > 50 then p_limit := 50; end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'context_actor_id', a.id,
      'display_name', a.display_name,
      'actor_kind', a.actor_kind,
      'actor_subtype', a.actor_subtype,
      'is_favorite', p.is_favorite,
      'last_visited_at', p.last_visited_at
    ) order by p.last_visited_at desc nulls last)
    from (
      select * from public.actor_context_preferences
      where actor_id = v_caller and last_visited_at is not null
      order by last_visited_at desc
      limit p_limit
    ) p
    join public.actors a on a.id = p.context_actor_id
  ), '[]'::jsonb);
end; $$;

revoke all on function public.list_recent_contexts(int) from public, anon;
grant execute on function public.list_recent_contexts(int) to authenticated, service_role;
comment on function public.list_recent_contexts(int) is
  'F.NAV.0: contextos visitados recientemente por el caller (default limit 5).';

-- ────────────────────────────────────────────────────────────────────────────
-- 6. attention_inbox() — cross-context atención
-- ────────────────────────────────────────────────────────────────────────────
-- Combina 4 fuentes:
--   a) reservation_conflicts (open) donde el caller es party de alguna reserva
--   b) decisions (open) donde el caller puede votar y NO ha votado
--   c) obligations (open) donde el caller es debtor (money → pay, action → mark_completed)
--   d) actor_memberships (status=invited) donde el caller es member_actor_id
-- Sort por occurred_at desc, máx 5 items.
-- Cada item lleva cta_action_key compatible con ActionRouter (F.2X).
create or replace function public.attention_inbox()
returns jsonb
language plpgsql stable security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_items jsonb := '[]'::jsonb;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;

  -- (a) Reservation conflicts open donde el caller es party
  v_items := v_items || coalesce((
    select jsonb_agg(jsonb_build_object(
      'kind', 'reservation_conflict',
      'subject_id', c.id,
      'context_actor_id', r.context_actor_id,
      'context_display_name', (select display_name from public.actors where id = r.context_actor_id),
      'title', 'Conflicto de reservación',
      'reason', 'Hay reservaciones que se solapan en un recurso donde participas',
      'cta_action_key', 'resolve_conflict',
      'cta_scope_kind', 'reservation',
      'cta_scope_id', r.id,
      'occurred_at', c.created_at
    ))
    from public.reservation_conflicts c
    join public.resource_reservations r
      on r.id = c.reservation_a_id or r.id = c.reservation_b_id
    where c.resolution_status = 'open'
      and (r.requested_by_actor_id = v_caller or r.reserved_for_actor_id = v_caller)
  ), '[]'::jsonb);

  -- (b) Open decisions: puede votar AND no ha votado todavía
  v_items := v_items || coalesce((
    select jsonb_agg(jsonb_build_object(
      'kind', 'decision_vote',
      'subject_id', d.id,
      'context_actor_id', d.context_actor_id,
      'context_display_name', (select display_name from public.actors where id = d.context_actor_id),
      'title', d.title,
      'reason', 'Decisión abierta donde puedes votar',
      'cta_action_key', 'vote',
      'cta_scope_kind', 'decision',
      'cta_scope_id', d.id,
      'occurred_at', d.created_at
    ))
    from public.decisions d
    where d.status = 'open'
      and public.has_actor_authority(d.context_actor_id, v_caller, 'decisions.vote')
      and not exists (
        select 1 from public.decision_votes dv
        where dv.decision_id = d.id and dv.voter_actor_id = v_caller
      )
  ), '[]'::jsonb);

  -- (c) Open obligations donde el caller es debtor
  v_items := v_items || coalesce((
    select jsonb_agg(jsonb_build_object(
      'kind', case when o.obligation_kind = 'money' then 'obligation_pay' else 'obligation_complete' end,
      'subject_id', o.id,
      'context_actor_id', o.context_actor_id,
      'context_display_name', (select display_name from public.actors where id = o.context_actor_id),
      'title', coalesce(o.title, 'Compromiso pendiente'),
      'reason', case when o.obligation_kind = 'money' then 'Tienes un pago pendiente'
                     else 'Tienes un compromiso pendiente' end,
      'cta_action_key', case when o.obligation_kind = 'money' then 'pay' else 'mark_completed' end,
      'cta_scope_kind', 'obligation',
      'cta_scope_id', o.id,
      'occurred_at', o.created_at
    ))
    from public.obligations o
    where o.status = 'open' and o.debtor_actor_id = v_caller
  ), '[]'::jsonb);

  -- (d) Pending invitations: actor_memberships invited
  v_items := v_items || coalesce((
    select jsonb_agg(jsonb_build_object(
      'kind', 'invitation',
      'subject_id', m.id,
      'context_actor_id', m.context_actor_id,
      'context_display_name', (select display_name from public.actors where id = m.context_actor_id),
      'title', 'Invitación pendiente',
      'reason', 'Te invitaron a un contexto',
      'cta_action_key', 'accept_invitation',
      'cta_scope_kind', 'context',
      'cta_scope_id', m.context_actor_id,
      'occurred_at', m.created_at
    ))
    from public.actor_memberships m
    where m.member_actor_id = v_caller and m.membership_status = 'invited'
  ), '[]'::jsonb);

  -- Sort + limit 5
  return coalesce((
    select jsonb_agg(item)
    from (
      select item
      from jsonb_array_elements(v_items) item
      order by (item->>'occurred_at')::timestamptz desc nulls last
      limit 5
    ) sorted
  ), '[]'::jsonb);
end; $$;

revoke all on function public.attention_inbox() from public, anon;
grant execute on function public.attention_inbox() to authenticated, service_role;
comment on function public.attention_inbox() is
  'F.NAV.0: items que requieren la atención del caller (conflictos/votos/pagos/invitaciones). Sort desc, max 5.';

-- ────────────────────────────────────────────────────────────────────────────
-- 7. Smoke — _smoke_f_nav_0_attention_and_preferences
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public._smoke_f_nav_0_attention_and_preferences()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  u_jose uuid; a_jose uuid;
  u_david uuid; a_david uuid;
  v_ctx_a uuid; v_ctx_b uuid;
  v_decision uuid;
  v_obligation uuid;
  v_favs jsonb; v_recents jsonb; v_inbox jsonb;
  v_caught boolean;
  v_item jsonb;
begin
  select auth_id, actor_id into u_jose, a_jose from public._r2_make_person('José F.NAV', '+5210000270');
  select auth_id, actor_id into u_david, a_david from public._r2_make_person('David F.NAV', '+5210000271');

  -- Crear 2 contextos (jose es founder)
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_ctx_a := (public.create_context('Familia FNAV-A', 'collective', 'family'))->>'context_actor_id';
  v_ctx_b := (public.create_context('Proyecto FNAV-B', 'collective', 'project'))->>'context_actor_id';

  -- ═══ 1. mark_context_favorite + list_context_favorites ═══
  perform public.mark_context_favorite(v_ctx_a::uuid, true);
  perform public.mark_context_favorite(v_ctx_b::uuid, true);
  v_favs := public.list_context_favorites();
  if jsonb_array_length(v_favs) <> 2 then
    raise exception 'F.NAV.0 FAIL 1: list_context_favorites debería tener 2 entries, tiene %', jsonb_array_length(v_favs);
  end if;

  -- Toggle off uno
  perform public.mark_context_favorite(v_ctx_b::uuid, false);
  v_favs := public.list_context_favorites();
  if jsonb_array_length(v_favs) <> 1 then
    raise exception 'F.NAV.0 FAIL 1: tras toggle off, debería quedar 1 favorito, hay %', jsonb_array_length(v_favs);
  end if;

  -- ═══ 2. mark_context_visited + list_recent_contexts ═══
  perform public.mark_context_visited(v_ctx_a::uuid);
  -- Pequeña pausa lógica: el orden lo da last_visited_at
  perform pg_sleep(0.01);
  perform public.mark_context_visited(v_ctx_b::uuid);
  v_recents := public.list_recent_contexts(5);
  if jsonb_array_length(v_recents) <> 2 then
    raise exception 'F.NAV.0 FAIL 2: list_recent_contexts debería tener 2, tiene %', jsonb_array_length(v_recents);
  end if;
  -- El más reciente es ctx_b (lo visité último)
  if (v_recents->0->>'context_actor_id')::uuid <> v_ctx_b::uuid then
    raise exception 'F.NAV.0 FAIL 2: orden recency incorrecto — primero debería ser ctx_b';
  end if;

  -- ═══ 3. Member-only: david no puede favoritar ctx_a sin ser miembro ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  v_caught := false;
  begin
    perform public.mark_context_favorite(v_ctx_a::uuid, true);
  exception when insufficient_privilege then v_caught := true;
  end;
  if not v_caught then
    raise exception 'F.NAV.0 FAIL 3: david favoriteó un contexto donde NO es miembro';
  end if;

  -- ═══ 4. attention_inbox: invitación pendiente ═══
  -- Jose invita a David a ctx_a
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  perform public.invite_member(v_ctx_a::uuid, a_david);

  -- David ve la invitación en su inbox
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  v_inbox := public.attention_inbox();
  if not exists (
    select 1 from jsonb_array_elements(v_inbox) item
    where item->>'kind' = 'invitation' and item->>'cta_action_key' = 'accept_invitation'
  ) then
    raise exception 'F.NAV.0 FAIL 4: invitación no aparece en attention_inbox de david';
  end if;

  -- David acepta
  perform public.accept_invitation(v_ctx_a::uuid);

  -- ═══ 5. attention_inbox: decisión abierta donde david puede votar ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_decision := (public.create_decision(v_ctx_a::uuid, 'generic', '¿Pintamos la sala?'))->>'decision_id';

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  v_inbox := public.attention_inbox();
  if not exists (
    select 1 from jsonb_array_elements(v_inbox) item
    where item->>'kind' = 'decision_vote' and (item->>'subject_id')::uuid = v_decision::uuid
  ) then
    raise exception 'F.NAV.0 FAIL 5: decisión no aparece en attention_inbox de david';
  end if;

  -- David vota → debería desaparecer del inbox (ya votó)
  perform public.vote_decision(v_decision::uuid, 'approve');
  v_inbox := public.attention_inbox();
  if exists (
    select 1 from jsonb_array_elements(v_inbox) item
    where item->>'kind' = 'decision_vote' and (item->>'subject_id')::uuid = v_decision::uuid
  ) then
    raise exception 'F.NAV.0 FAIL 5: decisión sigue en inbox después de votar';
  end if;

  -- ═══ 6. attention_inbox: obligación pendiente como debtor ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  -- Jose registra un gasto que crea obligación para David
  v_obligation := (public.create_action_obligation(v_ctx_a::uuid, a_david, 'Llevar vino', 'action'))->>'obligation_id';

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  v_inbox := public.attention_inbox();
  if not exists (
    select 1 from jsonb_array_elements(v_inbox) item
    where item->>'kind' = 'obligation_complete' and (item->>'subject_id')::uuid = v_obligation::uuid
  ) then
    raise exception 'F.NAV.0 FAIL 6: obligación de acción no aparece en attention_inbox de david';
  end if;

  -- ═══ 7. attention_inbox limit ═══
  if jsonb_array_length(v_inbox) > 5 then
    raise exception 'F.NAV.0 FAIL 7: attention_inbox excede el límite de 5 items';
  end if;

  -- ═══ 8. Forma canónica de cada item ═══
  v_item := v_inbox->0;
  if v_item is null then
    raise exception 'F.NAV.0 FAIL 8: attention_inbox vacío';
  end if;
  if not (v_item ? 'kind' and v_item ? 'subject_id' and v_item ? 'context_actor_id'
          and v_item ? 'context_display_name' and v_item ? 'title' and v_item ? 'reason'
          and v_item ? 'cta_action_key' and v_item ? 'cta_scope_kind' and v_item ? 'cta_scope_id'
          and v_item ? 'occurred_at') then
    raise exception 'F.NAV.0 FAIL 8: item de attention_inbox sin shape canónico';
  end if;

  -- Cleanup: ctx_b primero (sin actores) porque referencia a a_jose como creator;
  -- luego ctx_a con ambos actores.
  perform set_config('request.jwt.claims', null, true);
  perform public._r2_cleanup_context(v_ctx_b::uuid, array[]::uuid[], array[]::uuid[]);
  perform public._r2_cleanup_context(v_ctx_a::uuid, array[a_jose, a_david], array[u_jose, u_david]);

  raise notice 'F.NAV.0 ATTENTION INBOX + CONTEXT PREFERENCES: PASS (favorites + recents + attention + member-only + canonical shape)';
end; $$;

revoke all on function public._smoke_f_nav_0_attention_and_preferences() from public, anon, authenticated;

create or replace function public._smoke_mvp2_f_nav_0_attention_and_preferences()
returns void language plpgsql security definer set search_path = public
as $$ begin perform public._smoke_f_nav_0_attention_and_preferences(); end; $$;
revoke all on function public._smoke_mvp2_f_nav_0_attention_and_preferences() from public, anon, authenticated;
comment on function public._smoke_mvp2_f_nav_0_attention_and_preferences() is
  'Wrapper CI del smoke F.NAV.0 — attention inbox + context preferences.';

-- ────────────────────────────────────────────────────────────────────────────
-- 8. DoD inline
-- ────────────────────────────────────────────────────────────────────────────
do $$
begin
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                 where n.nspname = 'public' and p.proname = 'attention_inbox') then
    raise exception 'F.NAV.0 DoD: falta attention_inbox()';
  end if;
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                 where n.nspname = 'public' and p.proname = 'mark_context_favorite') then
    raise exception 'F.NAV.0 DoD: falta mark_context_favorite()';
  end if;
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                 where n.nspname = 'public' and p.proname = 'mark_context_visited') then
    raise exception 'F.NAV.0 DoD: falta mark_context_visited()';
  end if;
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                 where n.nspname = 'public' and p.proname = 'list_context_favorites') then
    raise exception 'F.NAV.0 DoD: falta list_context_favorites()';
  end if;
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                 where n.nspname = 'public' and p.proname = 'list_recent_contexts') then
    raise exception 'F.NAV.0 DoD: falta list_recent_contexts()';
  end if;
  if not exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
                 where n.nspname = 'public' and c.relname = 'actor_context_preferences') then
    raise exception 'F.NAV.0 DoD: falta tabla actor_context_preferences';
  end if;
  raise notice 'F.NAV.0 DoD OK: 5 RPCs + tabla actor_context_preferences';
end $$;
