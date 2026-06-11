-- ============================================================================
-- AUDIT.20 — Smoke r2j: aceptar la forma fastpath de la policy (2026-06-11)
-- ============================================================================
-- audit_19 reescribió activity_select al patrón initplan/hashed
-- (`my_context_ids()` en vez de `is_context_member()` literal). La aserción
-- ESTRUCTURAL del smoke r2j (que protege contra una regresión a "select true")
-- buscaba el literal 'is_context_member' → falso negativo. Se re-declara el
-- smoke (precedente r9_g: smokes se alinean al backend vigente) aceptando
-- cualquiera de las dos formas; las aserciones CONDUCTUALES (matriz de
-- visibilidad por actor×contexto, anon bloqueado, no-escritura) no cambian.
-- ============================================================================

create or replace function public._smoke_r2j_activity_context_isolation()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_world jsonb;
  v_visible boolean;
  r record;
begin
  v_world := public._r2j_make_world();

  -- matriz de visibilidad esperada (actor × contexto → puede ver como MIEMBRO)
  for r in
    select * from (values
      ('u_jose',  'cena',    true), ('u_jose',  'viaje',   true), ('u_jose',  'familia', true), ('u_jose',  'negocio', true),
      ('u_daniel','cena',    true), ('u_daniel','familia', true), ('u_daniel','viaje',   false), ('u_daniel','negocio', false),
      ('u_isaac', 'cena',    true), ('u_isaac', 'viaje',   true), ('u_isaac', 'familia', true), ('u_isaac', 'negocio', false),
      ('u_abuelo','familia', true), ('u_abuelo','cena',    false), ('u_abuelo','viaje',  false), ('u_abuelo','negocio', false),
      ('u_outsider','viaje', false), ('u_outsider','familia', false), ('u_outsider','negocio', false)
    ) t(who, ctx, expected)
  loop
    perform set_config('request.jwt.claims',
      jsonb_build_object('sub', (v_world->>r.who))::text, true);

    v_visible := public.is_context_member((v_world->>r.ctx)::uuid);

    if v_visible is distinct from r.expected then
      raise exception 'R2J ISOLATION FAIL: % membresía sobre % = % (esperaba %)', r.who, r.ctx, v_visible, r.expected;
    end if;

    if r.expected then
      if not exists (
        select 1 from public.activity_events ae
        where ae.context_actor_id = (v_world->>r.ctx)::uuid
          and (ae.actor_id = public.current_actor_id()
               or public.is_context_member(ae.context_actor_id))
        limit 1
      ) then
        raise exception 'R2J ISOLATION FAIL: % no ve activity de % siendo miembro', r.who, r.ctx;
      end if;
    else
      if exists (
        select 1 from public.activity_events ae
        where ae.context_actor_id = (v_world->>r.ctx)::uuid
          and ae.actor_id <> public.current_actor_id()
          and public.is_context_member(ae.context_actor_id)
          and (ae.obligation_id is null or not exists (
            select 1 from public.obligations o where o.id = ae.obligation_id
              and public.current_actor_id() in (o.debtor_actor_id, o.creditor_actor_id)))
        limit 1
      ) then
        raise exception 'R2J ISOLATION FAIL: % ve activity ajena de % sin ser miembro', r.who, r.ctx;
      end if;
    end if;
  end loop;

  -- la policy RLS existe y es rights-aware — acepta la forma legacy
  -- (is_context_member) o la fastpath de AUDIT.19 (my_context_ids); en ambos
  -- casos exige las ramas de obligations y resource_rights (no "select true")
  if not exists (
    select 1 from pg_policy
    where polrelid = 'public.activity_events'::regclass and polname = 'activity_select'
      and (pg_get_expr(polqual, polrelid) ilike '%is_context_member%'
           or pg_get_expr(polqual, polrelid) ilike '%my_context_ids%')
      and pg_get_expr(polqual, polrelid) ilike '%obligation%'
      and pg_get_expr(polqual, polrelid) ilike '%resource_rights%'
  ) then
    raise exception 'R2J ISOLATION FAIL: la policy RLS no es la v2 rights-aware';
  end if;

  if has_table_privilege('anon', 'public.activity_events', 'SELECT') then
    raise exception 'R2J ISOLATION FAIL: anon tiene SELECT en activity_events';
  end if;
  if has_table_privilege('authenticated', 'public.activity_events', 'INSERT')
     or has_table_privilege('authenticated', 'public.activity_events', 'UPDATE')
     or has_table_privilege('authenticated', 'public.activity_events', 'DELETE') then
    raise exception 'R2J ISOLATION FAIL: authenticated puede escribir activity_events directamente';
  end if;

  perform public._r2j_cleanup_world(v_world);
  raise notice 'R.2J ACTIVITY CONTEXT ISOLATION: PASS (matriz de visibilidad + RLS v2 + anon bloqueado)';
end; $$;

revoke all on function public._smoke_r2j_activity_context_isolation() from public, anon, authenticated;
