-- ============================================================================
-- AUDIT.15 — Baseline assert 7: exentar fixtures de prueba (2026-06-11)
-- ============================================================================
-- La segunda pasada de la suite completa en live reveló que el smoke de
-- r2s_4 emite deliberadamente 'custom.r2s_demo' y 'totally.bogus_type' como
-- fixtures negativos (prueban que _emit_activity marque payload.uncatalogued)
-- y, como activity_events es append-only, persisten. En CI no se nota (replay
-- fresco + orden alfabético: el baseline corre antes que r2s), pero el
-- baseline debe ser re-ejecutable también en live.
-- Refinamiento del assert 7: se exenta 'custom.%' (permitido por diseño en
-- _emit_activity) y el fixture 'totally.bogus_type' (documentado aquí).
-- El resto del baseline no cambia (se re-declara completo).
-- ============================================================================

create or replace function public._smoke_mvp2_audit_baseline()
returns void
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_count int;
  v_list  text;
  v_idx   text;
begin
  -- 1. Toda tabla base de public tiene RLS habilitado
  select count(*), string_agg(c.relname, ', ')
    into v_count, v_list
  from pg_class c
  where c.relnamespace = 'public'::regnamespace
    and c.relkind = 'r'
    and not c.relrowsecurity;
  if v_count > 0 then
    raise exception 'audit_baseline 1: tablas sin RLS: %', v_list;
  end if;

  -- 2. Toda tabla base tiene al menos una policy
  select count(*), string_agg(c.relname, ', ')
    into v_count, v_list
  from pg_class c
  where c.relnamespace = 'public'::regnamespace
    and c.relkind = 'r'
    and not exists (
      select 1 from pg_policies p
      where p.schemaname = 'public' and p.tablename = c.relname
    );
  if v_count > 0 then
    raise exception 'audit_baseline 2: tablas sin policies: %', v_list;
  end if;

  -- 3. anon: cero grants de tabla en public
  select count(*) into v_count
  from information_schema.role_table_grants
  where grantee = 'anon' and table_schema = 'public';
  if v_count > 0 then
    raise exception 'audit_baseline 3: anon tiene % grants de tabla en public', v_count;
  end if;

  -- 4. anon: cero EXECUTE en funciones app (se excluyen objetos de extensión)
  select count(*), string_agg(p.proname, ', ')
    into v_count, v_list
  from pg_proc p
  where p.pronamespace = 'public'::regnamespace
    and p.prokind in ('f', 'p')
    and not exists (
      select 1 from pg_depend d
      where d.objid = p.oid
        and d.refclassid = 'pg_extension'::regclass
        and d.deptype = 'e'
    )
    and has_function_privilege('anon', p.oid, 'EXECUTE');
  if v_count > 0 then
    raise exception 'audit_baseline 4: funciones app ejecutables por anon: %', v_list;
  end if;

  -- 5. Toda función app tiene search_path pineado
  select count(*), string_agg(p.proname, ', ')
    into v_count, v_list
  from pg_proc p
  where p.pronamespace = 'public'::regnamespace
    and p.prokind in ('f', 'p')
    and not exists (
      select 1 from pg_depend d
      where d.objid = p.oid
        and d.refclassid = 'pg_extension'::regclass
        and d.deptype = 'e'
    )
    and (p.proconfig is null or not exists (
      select 1 from unnest(p.proconfig) c where c like 'search_path=%'
    ));
  if v_count > 0 then
    raise exception 'audit_baseline 5: funciones con search_path mutable: %', v_list;
  end if;

  -- 6. Toda tabla con updated_at tiene touch trigger BEFORE UPDATE
  select count(*), string_agg(t.table_name, ', ')
    into v_count, v_list
  from (
    select distinct col.table_name
    from information_schema.columns col
    join pg_class c
      on c.relname = col.table_name
     and c.relnamespace = 'public'::regnamespace
     and c.relkind = 'r'
    where col.table_schema = 'public' and col.column_name = 'updated_at'
  ) t
  where not exists (
    select 1 from information_schema.triggers tr
    where tr.trigger_schema = 'public'
      and tr.event_object_table = t.table_name
      and tr.event_manipulation = 'UPDATE'
      and tr.action_timing = 'BEFORE'
  );
  if v_count > 0 then
    raise exception 'audit_baseline 6: tablas con updated_at sin touch trigger: %', v_list;
  end if;

  -- 7. Todo event_type emitido existe en el catálogo.
  --    Exentos: 'custom.%' (permitido por diseño en _emit_activity) y
  --    'totally.bogus_type' (fixture negativo del smoke r2s_4, append-only).
  select count(distinct ae.event_type), string_agg(distinct ae.event_type, ', ')
    into v_count, v_list
  from public.activity_events ae
  where ae.event_type not like 'custom.%'
    and ae.event_type <> 'totally.bogus_type'
    and not exists (
      select 1 from public.activity_event_catalog c
      where c.event_type = ae.event_type
    );
  if v_count > 0 then
    raise exception 'audit_baseline 7: actividad emitida sin catalogar: %', v_list;
  end if;

  -- 8. Índices de hot path presentes (spot check de audit_2)
  foreach v_idx in array array[
    'idx_activity_resource',
    'idx_splits_actor',
    'idx_obligations_due',
    'idx_settlement_items_from',
    'idx_decision_votes_voter',
    'idx_subscriptions_target_resource'
  ]
  loop
    if not exists (
      select 1 from pg_indexes
      where schemaname = 'public' and indexname = v_idx
    ) then
      raise exception 'audit_baseline 8: falta índice de hot path %', v_idx;
    end if;
  end loop;

  raise notice '_smoke_mvp2_audit_baseline: green';
end;
$$;

revoke all on function public._smoke_mvp2_audit_baseline() from public, anon, authenticated;

comment on function public._smoke_mvp2_audit_baseline() is
  'AUDIT.5/15: invariantes estructurales (RLS total, anon=0, search_path pineado, touch triggers, actividad catalogada salvo fixtures custom.%/totally.bogus_type, índices hot). Ver Plans/Active/SupabaseTargetArchitecture.md §10.';
