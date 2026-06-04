-- ============================================================================
-- R.3A.5 — Seed Mizrahi (subscriptions + trust edges)
-- ============================================================================
-- Idempotente: ON CONFLICT DO NOTHING via los unique indexes activos. Si la
-- migration corre dos veces, los upserts se evitan por el unique partial index.
-- ============================================================================

do $$
declare
  v_jose       uuid;
  v_papa       uuid;  -- Jacobo Mizrahi
  v_pepe       uuid;  -- Pepe Shamosh
  v_alberto    uuid;  -- Alberto Shamosh
  v_david      uuid;  -- David Achar
  v_abuelo     uuid;  -- José Mizrahi (Abuelo)
  v_quimibond  uuid;
  v_nave_ctx   uuid;
  v_nave_trust uuid;
  v_palco      uuid;
begin
  select id into v_jose       from public.actors where display_name = 'José Mizrahi' limit 1;
  select id into v_papa       from public.actors where display_name = 'Jacobo Mizrahi' limit 1;
  select id into v_pepe       from public.actors where display_name = 'Pepe Shamosh' limit 1;
  select id into v_alberto    from public.actors where display_name = 'Alberto Shamosh' limit 1;
  select id into v_david      from public.actors where display_name = 'David Achar' limit 1;
  select id into v_abuelo     from public.actors where display_name = 'José Mizrahi (Abuelo)' limit 1;
  select id into v_quimibond  from public.actors where display_name = 'Quimibond' limit 1;
  select id into v_nave_ctx   from public.actors where display_name = 'Proyecto Nave Industrial Toluca' limit 1;
  select id into v_nave_trust from public.actors where display_name = 'Fideicomiso Nave Industrial' limit 1;
  select id into v_palco      from public.resources where display_name = 'Palco Estadio Azteca' limit 1;

  -- ── Subscriptions ─────────────────────────────────────────────────────────
  -- José sigue Proyecto Nave Industrial, Fideicomiso Nave Industrial y Palco Azteca
  if v_jose is not null and v_nave_ctx is not null then
    insert into public.subscriptions (subscriber_actor_id, target_type, target_actor_id, subscription_type, notes)
    values (v_jose, 'context', v_nave_ctx, 'stakeholder', 'Seed Mizrahi')
    on conflict do nothing;
  end if;
  if v_jose is not null and v_nave_trust is not null then
    insert into public.subscriptions (subscriber_actor_id, target_type, target_actor_id, subscription_type, notes)
    values (v_jose, 'context', v_nave_trust, 'stakeholder', 'Seed Mizrahi')
    on conflict do nothing;
  end if;
  if v_jose is not null and v_palco is not null then
    insert into public.subscriptions (subscriber_actor_id, target_type, target_resource_id, subscription_type, notes)
    values (v_jose, 'resource', v_palco, 'follow', 'Seed Mizrahi')
    on conflict do nothing;
  end if;

  -- Papá (Jacobo) sigue Quimibond
  if v_papa is not null and v_quimibond is not null then
    insert into public.subscriptions (subscriber_actor_id, target_type, target_actor_id, subscription_type, notes)
    values (v_papa, 'context', v_quimibond, 'stakeholder', 'Seed Mizrahi')
    on conflict do nothing;
  end if;

  -- Pepe sigue Proyecto Nave Industrial
  if v_pepe is not null and v_nave_ctx is not null then
    insert into public.subscriptions (subscriber_actor_id, target_type, target_actor_id, subscription_type, notes)
    values (v_pepe, 'context', v_nave_ctx, 'follow', 'Seed Mizrahi')
    on conflict do nothing;
  end if;

  -- ── Trust edges ───────────────────────────────────────────────────────────
  -- José -> Papá = 5 personal
  if v_jose is not null and v_papa is not null then
    insert into public.trust_edges (source_actor_id, target_actor_id, trust_level, trust_type, notes)
    values (v_jose, v_papa, 5, 'personal', 'Seed Mizrahi')
    on conflict do nothing;
  end if;

  -- Papá -> Abuelo = 5 personal
  if v_papa is not null and v_abuelo is not null then
    insert into public.trust_edges (source_actor_id, target_actor_id, trust_level, trust_type, notes)
    values (v_papa, v_abuelo, 5, 'personal', 'Seed Mizrahi')
    on conflict do nothing;
  end if;

  -- José -> Alberto = 4 professional
  if v_jose is not null and v_alberto is not null then
    insert into public.trust_edges (source_actor_id, target_actor_id, trust_level, trust_type, notes)
    values (v_jose, v_alberto, 4, 'professional', 'Seed Mizrahi')
    on conflict do nothing;
  end if;

  -- José -> David Achar = 3 advisory
  if v_jose is not null and v_david is not null then
    insert into public.trust_edges (source_actor_id, target_actor_id, trust_level, trust_type, notes)
    values (v_jose, v_david, 3, 'advisory', 'Seed Mizrahi')
    on conflict do nothing;
  end if;
end $$;
