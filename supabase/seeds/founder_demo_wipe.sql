-- =============================================================================
-- RUUL — WIPE DEL DEMO DEL FOUNDER
-- =============================================================================
-- Borra TODO lo creado por founder_demo_seed.sql:
--   · Los 5 contextos demo y todo su contenido (eventos, reglas, obligations,
--     gastos, reservaciones, decisiones, settlement, invites, roles)
--   · Los 5 actores demo y sus auth.users (@demo.ruul.test)
--   · La activity de esos contextos
--
-- NO toca: el actor real de José, ni sus contextos propios (p.ej. "Bros"),
-- ni el recurso "Palco".
-- =============================================================================

do $$
declare
  a_jose uuid;
  v_demo_actors uuid[];
  v_demo_auths uuid[];
  v_ctx uuid;
  v_ctxs uuid[] := array[]::uuid[];
  v_name text;
begin
  select pp.actor_id into a_jose
    from public.person_profiles pp
    join auth.users u on u.id = pp.auth_user_id
   where u.email = 'jmizrahit@gmail.com';

  -- Actores y auth users demo (marcados por el email @demo.ruul.test)
  select coalesce(array_agg(pp.actor_id), array[]::uuid[]),
         coalesce(array_agg(u.id), array[]::uuid[])
    into v_demo_actors, v_demo_auths
    from auth.users u
    join public.person_profiles pp on pp.auth_user_id = u.id
   where u.email like '%@demo.ruul.test';

  -- Contextos demo: los 5 por nombre, solo si algún actor demo es miembro
  -- (así nunca tocamos un contexto real que se llame igual)
  for v_name in
    select unnest(array['Cena Semanal', 'Familia Mizrahi', 'Viaje Japón 2026', 'Negocio Valle', 'Trust Familiar Mizrahi'])
  loop
    select a.id into v_ctx
      from public.actors a
     where a.display_name = v_name
       and a.actor_kind in ('collective', 'legal_entity')
       and exists (select 1 from public.actor_memberships m
                    where m.context_actor_id = a.id and m.member_actor_id = any(v_demo_actors))
     limit 1;
    if v_ctx is not null then
      v_ctxs := v_ctxs || v_ctx;
    end if;
  end loop;

  -- Activity de los contextos demo y de los actores demo
  delete from public.activity_events
   where context_actor_id = any(v_ctxs) or actor_id = any(v_demo_actors);

  -- Contextos (con todo su contenido) — sin tocar actores todavía
  foreach v_ctx in array v_ctxs loop
    perform public._r2_cleanup_context(v_ctx, array[]::uuid[], array[]::uuid[]);
  end loop;

  -- Recursos personales de actores demo (Casa Valle del Abuelo) + memberships sueltas
  delete from public.reservation_conflicts where resource_id in
    (select id from public.resources where canonical_owner_actor_id = any(v_demo_actors));
  delete from public.resource_reservations where resource_id in
    (select id from public.resources where canonical_owner_actor_id = any(v_demo_actors));
  delete from public.resource_rights where resource_id in
    (select id from public.resources where canonical_owner_actor_id = any(v_demo_actors));
  delete from public.resource_rights where holder_actor_id = any(v_demo_actors);
  delete from public.resources where canonical_owner_actor_id = any(v_demo_actors);
  delete from public.actor_memberships where member_actor_id = any(v_demo_actors);

  -- Actores demo + auth users demo
  delete from public.person_profiles where actor_id = any(v_demo_actors);
  delete from public.actors where id = any(v_demo_actors);
  delete from auth.users where id = any(v_demo_auths);

  raise notice 'WIPE FOUNDER DEMO: OK — % contextos y % actores demo eliminados. El actor de José (%) quedó intacto.',
    coalesce(array_length(v_ctxs, 1), 0), coalesce(array_length(v_demo_actors, 1), 0), a_jose;
end; $$;
