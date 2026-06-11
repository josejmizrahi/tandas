-- ============================================================================
-- AUDIT.14 — Taxonomía vs primitivas: flag is_creatable + guard (2026-06-11)
-- ============================================================================
-- Fase 2 ítem 5 del SupabaseCleanupMigrationPlan (hallazgo §5 del
-- SupabaseArchitectureAudit): los subtipos de clase `obligation`
-- (iou/fine/loan/contribution/dues) y `event` (dinner/meeting/
-- community_event/recurring_event) permitían crear desde el picker "recursos"
-- paralelos a las primitivas obligations/calendar_events. Nunca debe existir
-- un recurso-iou con dinero real.
--
-- Diseño (opción 1 de la auditoría — reversible flipeando el flag):
--   §1 Shim de drift (precedente r9_g): list_resource_classes /
--      list_resource_subtypes existían solo en live (era subtype_picker);
--      aterrizan en disco con la definición de producción.
--   §2 `resource_subtypes.is_creatable` default true; false para las clases
--      obligation y event (9 subtipos). La taxonomía NO se borra: sigue
--      sirviendo para mapeos legacy y UI de lectura.
--   §3 El picker (`list_resource_subtypes`) solo lista subtipos creables.
--   §4 Guard duro SOLO para clase obligation, en el trigger de derivación
--      (cubre todo camino de inserción). La clase event NO se bloquea a nivel
--      trigger: el mapping legacy `resource_type 'game' → recurring_event`
--      (r5a_b1) es legítimo y debe seguir operando; event solo se oculta del
--      picker.
--   §5 Smoke con ejecución inline.
-- iOS no cambia: consume list_resource_subtypes y simplemente ve menos opciones.
-- Rollback: update is_creatable=true + redefinir §3/§4 sin filtro/guard.
-- ============================================================================

-- §1. Shim de drift: picker RPCs en disco (no-op en live salvo el filtro §3)
create or replace function public.list_resource_classes()
returns setof jsonb
language sql
security definer
set search_path = public, auth
as $$
  select jsonb_build_object(
    'class_key',    class_key,
    'display_name', display_name,
    'description',  description,
    'icon',         icon
  )
  from public.resource_classes
  order by display_name;
$$;

revoke all on function public.list_resource_classes() from public, anon;
grant execute on function public.list_resource_classes() to authenticated, service_role;

-- §2. Flag is_creatable
alter table public.resource_subtypes
  add column if not exists is_creatable boolean not null default true;

update public.resource_subtypes
   set is_creatable = false
 where class_key in ('obligation', 'event');

comment on column public.resource_subtypes.is_creatable is
  'AUDIT.14: false = el subtipo existe como taxonomía (mapeos legacy, lectura) pero el picker no lo ofrece; para clase obligation además hay guard duro en el trigger de derivación.';

-- §3. El picker solo ofrece subtipos creables
create or replace function public.list_resource_subtypes(p_class_key text default null)
returns setof jsonb
language sql
security definer
set search_path = public, auth
as $$
  select jsonb_build_object(
    'subtype_key',  rs.subtype_key,
    'class_key',    rs.class_key,
    'display_name', rs.display_name,
    'description',  rs.description
  )
  from public.resource_subtypes rs
  where (p_class_key is null or rs.class_key = p_class_key)
    and rs.is_creatable
  order by rs.display_name;
$$;

revoke all on function public.list_resource_subtypes(text) from public, anon;
grant execute on function public.list_resource_subtypes(text) to authenticated, service_role;

-- §4. Guard duro: ningún recurso de clase obligation, por ningún camino
create or replace function public._r5a_b1_resources_derive_class_subtype()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_sub public.resource_subtypes%rowtype;
begin
  if NEW.resource_type is not null then
    if NEW.resource_class_key is null then
      NEW.resource_class_key := public._r5a_b1_class_for(NEW.resource_type);
    end if;
    if NEW.resource_subtype_key is null then
      NEW.resource_subtype_key := public._r5a_b1_subtype_for(NEW.resource_type);
    end if;
  end if;

  -- AUDIT.14: las obligaciones son primitiva (tabla obligations), no recursos.
  if NEW.resource_subtype_key is not null then
    select * into v_sub from public.resource_subtypes
     where subtype_key = NEW.resource_subtype_key;
    if found and v_sub.class_key = 'obligation' and not v_sub.is_creatable then
      raise exception 'subtype % is an obligation primitive, not a creatable resource; use record_fine/record_expense/create_action_obligation', NEW.resource_subtype_key
        using errcode = '22023';
    end if;
  end if;

  return NEW;
end;
$$;

-- §5. Smoke
create or replace function public._smoke_mvp2_audit_subtype_creatable()
returns void
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  u_a uuid; a_a uuid;
  v_ctx uuid;
  v_res uuid;
  v_caught boolean;
begin
  -- 1. El picker excluye obligation/event y conserva el resto
  if exists (select 1 from public.list_resource_subtypes() s
              where s->>'subtype_key' in ('iou', 'fine', 'dinner', 'recurring_event')) then
    raise exception 'subtype smoke 1: el picker sigue ofreciendo subtipos de obligation/event';
  end if;
  if not exists (select 1 from public.list_resource_subtypes() s
                  where s->>'subtype_key' = 'car') then
    raise exception 'subtype smoke 1b: el picker dejó de ofrecer subtipos legítimos';
  end if;

  -- Mundo mínimo
  select auth_id, actor_id into u_a, a_a from public._r2_make_person('Ana Subtypes', '+5210000995');
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_a::text)::text, true);
  v_ctx := (public.create_context('Subtype Guard Smoke', 'collective', 'friend_group'))->>'context_actor_id';

  -- 2. Camino feliz intacto (vehicle/car)
  v_res := (public.create_resource(v_ctx::uuid, 'vehicle', 'Coche Smoke',
              p_subtype_key => 'car'))->>'resource_id';
  if v_res is null then
    raise exception 'subtype smoke 2: create_resource vehicle/car dejó de funcionar';
  end if;

  -- 3. Guard universal: ni un INSERT directo puede crear un recurso-obligación
  v_caught := false;
  begin
    insert into public.resources (resource_type, display_name, created_by_actor_id, resource_subtype_key)
    values ('other', 'IOU pirata', a_a, 'iou');
  exception when others then
    v_caught := true;
  end;
  if not v_caught then
    raise exception 'subtype smoke 3: se pudo crear un recurso con subtipo iou';
  end if;

  -- 4. El mapping legacy game→recurring_event (clase event) sigue operando
  v_res := (public.create_resource(v_ctx::uuid, 'game', 'Dominó Smoke'))->>'resource_id';
  if not exists (select 1 from public.resources
                  where id = v_res and resource_class_key = 'event'
                    and resource_subtype_key = 'recurring_event') then
    raise exception 'subtype smoke 4: el mapping legacy game→recurring_event se rompió';
  end if;

  perform public._r2_cleanup_context(v_ctx::uuid, array[a_a], array[u_a]);
  raise notice '_smoke_mvp2_audit_subtype_creatable: green';
end;
$$;

revoke all on function public._smoke_mvp2_audit_subtype_creatable() from public, anon, authenticated;

comment on function public._smoke_mvp2_audit_subtype_creatable() is
  'AUDIT.14: picker sin subtipos obligation/event, guard duro anti recurso-obligación (incluso INSERT directo), camino feliz y mapping legacy game→recurring_event intactos.';

do $$ begin perform public._smoke_mvp2_audit_subtype_creatable(); end $$;
