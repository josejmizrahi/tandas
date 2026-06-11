-- ============================================================================
-- R.9.J — HYGIENE: pin search_path en helpers/triggers flaggeados (2026-06-11)
-- ============================================================================
-- El security advisor de Supabase flaggea 30 funciones con
-- `function_search_path_mutable` (helpers SQL + trigger functions sin
-- search_path fijo). Un search_path mutable permite que un rol con un
-- search_path malicioso secuestre la resolución de objetos no calificados.
--
-- Este migration NO toca cuerpos: solo `alter function ... set search_path`.
--
-- Pin elegido por función (auditoría de cuerpos 2026-06-11):
--   · TODAS → `search_path = public`.
--     Cada referencia cross-objeto en los 30 cuerpos está calificada con
--     `public.` (tablas, helpers); los builtins (jsonb_*, encode, now,
--     clock_timestamp, format, lower, coalesce) resuelven vía pg_catalog,
--     que SIEMPRE va implícito al frente del search_path.
--   · _r6_compute_idempotency_key llama `extensions.digest(...)` CALIFICADO
--     (verificado en 20260608105005) → no necesita `extensions` en el pin.
--   · Ninguna referencia unqualified a `auth.*` ni `extensions.*` → ninguna
--     función necesita pin más amplio que `public`.
--   · Exclusiones: NINGUNA. Ninguna de las 30 depende de resolución dinámica
--     por search_path (los triggers _activity_events_append_only,
--     _actors_set_is_context, _actor_relationships_no_contains_cycle,
--     _r5a_b1_resources_derive_class_subtype, _r6_rules_validate_trigger,
--     touch_updated_at, _notifications_touch_read_at,
--     _governance_action_catalog_touch_updated_at,
--     _resource_conflicts_touch_updated_at solo usan NEW/OLD + builtins
--     + helpers public.* calificados).
--
-- Drift live vs disco (precedente R.9.G): 8 de los 30 nombres existen SOLO en
-- la BD viva (creados vía MCP, nunca aterrizaron en disco):
--   _r5b_legacy_context_actor, _r5b_map_legacy_conflict_type,
--   _r5b_map_legacy_status, _r5b_strip_conflicts_section_if_clean,
--   _r5b_strip_conflicts_widget_if_clean, _r5b_template_for_conflict_type,
--   _resource_conflicts_touch_updated_at, _resource_type_for_subtype.
-- Sus cuerpos fueron auditados EN LIVE (pg_proc.prosrc, 2026-06-11): solo
-- referencias public.* calificadas y builtins → pin `public` también.
-- Por eso el DO block itera pg_proc y SALTA (raise notice) los nombres
-- ausentes: replay limpio (sin las 8) y live (con las 8) pasan igual.
-- Itera TODOS los overloads por nombre via pg_get_function_identity_arguments
-- (hoy cada nombre tiene exactamente 1 overload en live, pero el patrón es
-- robusto si replay/live difieren).
-- ============================================================================

do $$
declare
  v_names constant text[] := array[
    '_aa',
    '_aa_apply_governance_mode',
    '_activity_events_append_only',
    '_actor_relationships_no_contains_cycle',
    '_actors_set_is_context',
    '_eval_condition',
    '_governance_action_catalog_touch_updated_at',
    '_governance_action_policy_key',
    '_governance_action_resolve',
    '_ledger_entry_type_for',
    '_notifications_touch_read_at',
    '_r5a_b1_class_for',
    '_r5a_b1_resources_derive_class_subtype',
    '_r5a_b1_subtype_for',
    '_r5b_legacy_context_actor',
    '_r5b_map_legacy_conflict_type',
    '_r5b_map_legacy_status',
    '_r5b_strip_conflicts_section_if_clean',
    '_r5b_strip_conflicts_widget_if_clean',
    '_r5b_template_for_conflict_type',
    '_r6_compute_idempotency_key',
    '_r6_rules_validate_trigger',
    '_r6_validate_condition_tree',
    '_r6_validate_consequence',
    '_r6_validate_consequences',
    '_resource_conflicts_touch_updated_at',
    '_resource_type_for_subtype',
    '_rule_target_matches',
    'system_actor_id',
    'touch_updated_at'
  ];
  v_name    text;
  v_fn      record;
  v_pinned  integer := 0;
  v_missing text[]  := '{}';
begin
  foreach v_name in array v_names loop
    if not exists (
      select 1
        from pg_proc p
        join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public'
         and p.proname = v_name
    ) then
      v_missing := v_missing || v_name;
      raise notice 'r9_j: public.% no existe en este entorno — skip', v_name;
      continue;
    end if;

    for v_fn in
      select p.oid,
             pg_get_function_identity_arguments(p.oid) as args
        from pg_proc p
        join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public'
         and p.proname = v_name
       order by p.oid
    loop
      execute format('alter function public.%I(%s) set search_path = public',
                     v_name, v_fn.args);
      v_pinned := v_pinned + 1;
    end loop;
  end loop;

  raise notice 'r9_j: % funciones pinned (search_path = public), % ausentes: %',
    v_pinned, coalesce(array_length(v_missing, 1), 0), v_missing;
end $$;

-- ────────────────────────────────────────────────────────────────────────────
-- Smoke: cada uno de los 30 nombres PRESENTE en pg_proc tiene search_path
-- pinned en proconfig. Los cuerpos en sí ya los ejercita la suite existente
-- (touch_updated_at dispara en cada update; _eval_condition en cada rule
-- eval; etc.) — este smoke solo asegura que la higiene no regrese.
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public._smoke_mvp2_r9_j_search_path_pinned()
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_names constant text[] := array[
    '_aa',
    '_aa_apply_governance_mode',
    '_activity_events_append_only',
    '_actor_relationships_no_contains_cycle',
    '_actors_set_is_context',
    '_eval_condition',
    '_governance_action_catalog_touch_updated_at',
    '_governance_action_policy_key',
    '_governance_action_resolve',
    '_ledger_entry_type_for',
    '_notifications_touch_read_at',
    '_r5a_b1_class_for',
    '_r5a_b1_resources_derive_class_subtype',
    '_r5a_b1_subtype_for',
    '_r5b_legacy_context_actor',
    '_r5b_map_legacy_conflict_type',
    '_r5b_map_legacy_status',
    '_r5b_strip_conflicts_section_if_clean',
    '_r5b_strip_conflicts_widget_if_clean',
    '_r5b_template_for_conflict_type',
    '_r6_compute_idempotency_key',
    '_r6_rules_validate_trigger',
    '_r6_validate_condition_tree',
    '_r6_validate_consequence',
    '_r6_validate_consequences',
    '_resource_conflicts_touch_updated_at',
    '_resource_type_for_subtype',
    '_rule_target_matches',
    'system_actor_id',
    'touch_updated_at'
  ];
  v_name    text;
  v_fn      record;
  v_checked integer := 0;
begin
  foreach v_name in array v_names loop
    for v_fn in
      select p.proconfig,
             pg_get_function_identity_arguments(p.oid) as args
        from pg_proc p
        join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public'
         and p.proname = v_name
    loop
      if v_fn.proconfig is null or not exists (
        select 1 from unnest(v_fn.proconfig) cfg
        where cfg like 'search_path=%'
      ) then
        raise exception 'r9_j: public.%(%) sin search_path pinned (proconfig = %)',
          v_name, v_fn.args, v_fn.proconfig;
      end if;
      v_checked := v_checked + 1;
    end loop;
  end loop;

  -- Si NINGUNA existe algo está muy roto (touch_updated_at vive desde mvp2_000)
  if v_checked = 0 then
    raise exception 'r9_j: ninguna de las 30 funciones existe — smoke vacuo';
  end if;

  raise notice '_smoke_mvp2_r9_j_search_path_pinned passed (% funciones con search_path pinned)',
    v_checked;
end;
$$;

revoke all on function public._smoke_mvp2_r9_j_search_path_pinned() from public, anon, authenticated;

comment on function public._smoke_mvp2_r9_j_search_path_pinned() is
  'R.9.J: asegura que las 30 funciones flaggeadas por function_search_path_mutable conserven search_path pinned (proconfig). Tolera los 8 nombres live-only ausentes en replay.';
