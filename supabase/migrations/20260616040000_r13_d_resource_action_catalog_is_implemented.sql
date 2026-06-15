-- R.13.D — Honesty Sweep backend: filtrar action_keys no implementadas
--
-- Founder lock 2026-06-16: "nada que no tenga que estar — tanto en el
-- frontend como en el backend". Ruta C2 firmada: conservar las rows del
-- `resource_action_catalog` como modelado conceptual de Ruul, pero NUNCA
-- surface action_keys sin RPC backend / handler iOS al descriptor del UI.
--
-- Approach:
--   1. ADD COLUMN `is_implemented` boolean a `resource_action_catalog`.
--   2. Backfill TRUE para action_keys con entry en `resource_action_dispatch`
--      (16 keys con RPC backend).
--   3. Backfill TRUE manual para `archive_document` (iOS lo maneja via RPC
--      directo `archive_document`, no via execute_resource_action).
--   4. CREATE OR REPLACE `list_resource_actions` con filter
--      `WHERE coalesce(rac.is_implemented, false) = true`.
--
-- iOS adicional (R.13.B previo): `ActionRouter.knownActionKeys` whitelist
-- filtra defensivo en detail views. Doble gating coherente.
--
-- Reversible: el catalog conserva las rows; flip `is_implemented=true`
-- cuando una RPC nueva ship (sin re-insertar).

-- ─────────────────────────────────────────────────────────────────────────
-- 1. Column
-- ─────────────────────────────────────────────────────────────────────────

alter table public.resource_action_catalog
  add column if not exists is_implemented boolean not null default false;

comment on column public.resource_action_catalog.is_implemented is
  'R.13.D 2026-06-16: TRUE si action_key tiene path real (dispatch RPC O handler iOS local). `list_resource_actions` filtra por este flag para nunca surface al UI un action sin destino.';

-- ─────────────────────────────────────────────────────────────────────────
-- 2. Backfill from resource_action_dispatch
-- ─────────────────────────────────────────────────────────────────────────

update public.resource_action_catalog rac
   set is_implemented = true
 where exists (
   select 1
     from public.resource_action_dispatch rad
    where rad.action_key = rac.action_key
 );

-- ─────────────────────────────────────────────────────────────────────────
-- 3. Backfill handlers iOS-local (sin dispatch RPC backend)
-- ─────────────────────────────────────────────────────────────────────────

-- `archive_document`: iOS llama RPC `archive_document` directo desde
-- DocumentsStore (no via execute_resource_action). El dispatch entry no
-- es requerido; solo necesitamos marcar la row del catalog para que
-- list_resource_actions la surface.
update public.resource_action_catalog
   set is_implemented = true
 where action_key = 'archive_document';

-- ─────────────────────────────────────────────────────────────────────────
-- 4. Filter en list_resource_actions
-- ─────────────────────────────────────────────────────────────────────────

create or replace function public.list_resource_actions(p_resource_id uuid)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public', 'auth'
as $function$
declare
  v_actor uuid;
  v_owner uuid;
  v_available jsonb;
  v_actions jsonb;
begin
  if auth.uid() is null then raise exception 'unauthenticated' using errcode='42501'; end if;
  v_actor := public.current_actor_id();
  if v_actor is null then raise exception 'missing person actor' using errcode='42501'; end if;

  select canonical_owner_actor_id into v_owner from public.resources where id = p_resource_id;
  if v_owner is null then raise exception 'resource not found' using errcode='P0002'; end if;
  if not (v_actor = v_owner or public.is_context_member(v_owner)) then
    raise exception 'not a member of resource context' using errcode='42501';
  end if;

  v_available := public.resource_available_actions(p_resource_id, v_actor);

  -- R.13.D 2026-06-16 — coalesce(rac.is_implemented, false) filtra:
  --   - rows sin entry en resource_action_catalog (mode=null) → false
  --   - rows con is_implemented=false (modeladas pero sin path real) → false
  -- iOS nunca recibe action_keys que el catalog declara no implementadas.
  select coalesce(jsonb_agg(jsonb_build_object(
           'action_key', a->>'action_key',
           'label', a->>'label',
           'section', a->>'section',
           'enabled', (a->>'enabled')::boolean,
           'reason', a->>'reason',
           'required_rights', a->'required_rights',
           'required_capability', rac.required_capability,
           'mode', rac.execution_mode,
           'decision_template_key', rac.decision_template_key,
           'form_schema_present', exists(
             select 1 from public.resource_action_forms raf
              where raf.action_key = a->>'action_key'
                and raf.form_schema <> '{}'::jsonb
                and (raf.form_schema->'fields' is null or raf.form_schema->'fields' <> '[]'::jsonb)
           ),
           'dangerous', coalesce(raf.dangerous, rac.dangerous, false),
           'confirmation_required', coalesce(raf.confirmation_required, rac.confirmation_required, false)
         ) order by (a->>'section'), (a->>'action_key')), '[]'::jsonb)
    into v_actions
    from jsonb_array_elements(v_available) a
    left join public.resource_action_catalog rac on rac.action_key = a->>'action_key'
    left join public.resource_action_forms raf on raf.action_key = a->>'action_key'
   where coalesce(rac.is_implemented, false) = true;

  return v_actions;
end;
$function$;

revoke execute on function public.list_resource_actions(uuid) from public, anon;
grant execute on function public.list_resource_actions(uuid) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────
-- 5. Smoke
-- ─────────────────────────────────────────────────────────────────────────

do $smoke$
declare
  v_total integer;
  v_impl integer;
  v_dispatch integer;
begin
  select count(*) into v_total from public.resource_action_catalog;
  select count(*) into v_impl from public.resource_action_catalog where is_implemented = true;
  select count(*) into v_dispatch from public.resource_action_dispatch;

  -- Implementados = rows con dispatch (16) + archive_document manual (1) = 17.
  if v_impl < v_dispatch then
    raise exception 'R.13.D smoke fail: is_implemented (%) < dispatch entries (%)', v_impl, v_dispatch;
  end if;

  -- Mayoría debe ser no-implementada (modelado conceptual).
  if v_impl >= v_total then
    raise exception 'R.13.D smoke fail: todas las rows marcadas implementadas (%); el flag pierde su propósito', v_impl;
  end if;

  raise notice 'R.13.D smoke OK: % implementadas de % rows totales del catalog (% en dispatch)', v_impl, v_total, v_dispatch;
end;
$smoke$;
