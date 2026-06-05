-- ============================================================================
-- R.5A.B.1 — RESOURCES gains resource_class_key + resource_subtype_key
-- ============================================================================
-- Additive: cols nullables + FKs a los catalogos de B.0. Backfill desde
-- resource_type usando mapping founder (Plan R5A_DetailArchitecture sec 4.2).
-- BEFORE INSERT/UPDATE trigger auto-deriva class/subtype cuando NULL para
-- mantener filas nuevas pobladas sin tocar create_resource. NOT NULL diferido
-- a B.6 una vez validado.
--
-- Cero impacto runtime: cols invisibles a RPCs vivos (resource_detail,
-- list_context_resources, resource_can, resource_available_actions).
-- iOS untouched.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. ALTER resources: agregar columnas nullables
-- ----------------------------------------------------------------------------
alter table public.resources add column resource_class_key text;
alter table public.resources add column resource_subtype_key text;

alter table public.resources
  add constraint resources_resource_class_key_fkey
  foreign key (resource_class_key) references public.resource_classes(class_key)
  on update cascade on delete restrict;

alter table public.resources
  add constraint resources_resource_subtype_key_fkey
  foreign key (resource_subtype_key) references public.resource_subtypes(subtype_key)
  on update cascade on delete restrict;

comment on column public.resources.resource_class_key is
  'R.5A.B.1: FK a resource_classes. Nullable hasta B.6 (NOT NULL). Backfill desde resource_type.';
comment on column public.resources.resource_subtype_key is
  'R.5A.B.1: FK a resource_subtypes. Nullable hasta B.6 (NOT NULL). Backfill desde resource_type.';

create index idx_resources_resource_class_key   on public.resources(resource_class_key);
create index idx_resources_resource_subtype_key on public.resources(resource_subtype_key);

-- ----------------------------------------------------------------------------
-- 2. Mapping functions (puras, deterministicas, idempotentes)
--    Single source of truth para el mapping legacy resource_type -> (class, subtype).
-- ----------------------------------------------------------------------------
create or replace function public._r5a_b1_class_for(p_resource_type text)
returns text language sql immutable as $$
  select case p_resource_type
    when 'house'            then 'real_estate'
    when 'property'         then 'real_estate'
    when 'vehicle'          then 'vehicle'
    when 'bank_account'     then 'financial'
    when 'cash_pool'        then 'financial'
    when 'security'         then 'financial'
    when 'contract'         then 'document'
    when 'document'         then 'document'
    when 'equipment'        then 'equipment'
    when 'digital_asset'    then 'digital_asset'
    when 'trust_asset'      then 'financial'
    when 'trip_booking'     then 'trip'
    when 'game'             then 'event'
    when 'membership_asset' then 'membership'
    when 'reservation'      then 'space'
    when 'other'            then 'generic'
    else                         'generic'
  end;
$$;

create or replace function public._r5a_b1_subtype_for(p_resource_type text)
returns text language sql immutable as $$
  select case p_resource_type
    when 'house'            then 'primary_residence'
    when 'property'         then 'land'
    when 'vehicle'          then 'car'
    when 'bank_account'     then 'bank_account'
    when 'cash_pool'        then 'money_pool'
    when 'security'         then 'investment_account'
    when 'contract'         then 'contract'
    when 'document'         then 'certificate'
    when 'equipment'        then 'generic_equipment'
    when 'digital_asset'    then 'generic_digital_asset'
    when 'trust_asset'      then 'trust_fund'
    when 'trip_booking'     then 'group_trip'
    when 'game'             then 'recurring_event'
    when 'membership_asset' then 'generic_membership'
    when 'reservation'      then 'generic_space'
    when 'other'            then 'generic_resource'
    else                         'generic_resource'
  end;
$$;

comment on function public._r5a_b1_class_for(text) is
  'R.5A.B.1: deriva resource_class_key desde resource_type legacy. Single source of truth.';
comment on function public._r5a_b1_subtype_for(text) is
  'R.5A.B.1: deriva resource_subtype_key desde resource_type legacy. Single source of truth.';

-- ----------------------------------------------------------------------------
-- 3. Trigger: BEFORE INSERT OR UPDATE OF resource_type — auto-deriva si NULL
--    No cambia comportamiento de callers: si pasan class/subtype explicito,
--    se respeta. Si pasan solo resource_type, se llenan los nuevos cols.
-- ----------------------------------------------------------------------------
create or replace function public._r5a_b1_resources_derive_class_subtype()
returns trigger language plpgsql as $$
begin
  if NEW.resource_type is not null then
    if NEW.resource_class_key is null then
      NEW.resource_class_key := public._r5a_b1_class_for(NEW.resource_type);
    end if;
    if NEW.resource_subtype_key is null then
      NEW.resource_subtype_key := public._r5a_b1_subtype_for(NEW.resource_type);
    end if;
  end if;
  return NEW;
end;
$$;

create trigger trg_resources_derive_class_subtype
  before insert or update of resource_type on public.resources
  for each row execute function public._r5a_b1_resources_derive_class_subtype();

-- ----------------------------------------------------------------------------
-- 4. Backfill: rows existentes (idempotente — solo toca filas NULL)
-- ----------------------------------------------------------------------------
update public.resources
   set resource_class_key   = public._r5a_b1_class_for(resource_type),
       resource_subtype_key = public._r5a_b1_subtype_for(resource_type)
 where resource_class_key is null
    or resource_subtype_key is null;
