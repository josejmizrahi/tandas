-- ============================================================================
-- R.5A.B.H — Hardening post founder backend review (2026-06-05)
-- ============================================================================
-- Founder aprobó backend con 7 ajustes. Audit:
--   1. UNIQUE(resource_id, capability_key) on resource_capability_overrides   YA EXISTIA
--   2. CHECK no-self en resource_relations                                     YA EXISTIA
--   3. UNIQUE(parent, child, type) en resource_relations                       YA EXISTIA
--   4. default_enabled boolean default true en resource_subtype_capabilities   APLICA AQUI
--   5. confirmation_required + dangerous NOT NULL DEFAULT false en forms        APLICA AQUI
--   6. FK required_permission -> permission_catalog                             APLICA AQUI
--   7. Arrays text[] con default '{}'::text[]                                  YA CUMPLEN
--
-- DECISION item 5: founder elige NOT NULL DEFAULT false; el override pattern
-- "form NULL = inherit catalog" queda derogado. F.0 ya lee
-- coalesce(form, catalog, false) -- sigue funcionando con valores explicitos.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Item 4: default_enabled en resource_subtype_capabilities
-- ----------------------------------------------------------------------------
alter table public.resource_subtype_capabilities
  add column default_enabled boolean not null default true;

comment on column public.resource_subtype_capabilities.default_enabled is
  'R.5A.B.H: si false, este subtype declara la capability pero NO la activa por default. effective_resource_capabilities ignora rows con default_enabled=false (a menos que un override per-instance la encienda).';

-- ----------------------------------------------------------------------------
-- Item 5: NOT NULL DEFAULT false en resource_action_forms.{confirmation_required, dangerous}
-- ----------------------------------------------------------------------------
update public.resource_action_forms set confirmation_required = false where confirmation_required is null;
update public.resource_action_forms set dangerous = false where dangerous is null;

alter table public.resource_action_forms
  alter column confirmation_required set default false,
  alter column confirmation_required set not null,
  alter column dangerous set default false,
  alter column dangerous set not null;

comment on column public.resource_action_forms.confirmation_required is
  'R.5A.B.H: NOT NULL. Founder derogo el pattern "NULL=inherit catalog". Si el caller quiere inherit catalog, debe leer del catalog directamente.';
comment on column public.resource_action_forms.dangerous is
  'R.5A.B.H: NOT NULL. Founder derogo el pattern "NULL=inherit catalog".';

-- ----------------------------------------------------------------------------
-- Item 6: FK required_permission -> permission_catalog en context_subtype_sections + _widgets
-- ----------------------------------------------------------------------------
do $$
declare
  v_orphans int;
begin
  select count(*) into v_orphans
    from public.context_subtype_sections cs
    where cs.required_permission is not null
      and not exists (select 1 from public.permission_catalog pc where pc.permission_key = cs.required_permission);
  if v_orphans > 0 then
    raise exception 'r5a.bh: % rows en context_subtype_sections con required_permission huerfano', v_orphans;
  end if;

  select count(*) into v_orphans
    from public.context_subtype_widgets cw
    where cw.required_permission is not null
      and not exists (select 1 from public.permission_catalog pc where pc.permission_key = cw.required_permission);
  if v_orphans > 0 then
    raise exception 'r5a.bh: % rows en context_subtype_widgets con required_permission huerfano', v_orphans;
  end if;
end $$;

alter table public.context_subtype_sections
  add constraint context_subtype_sections_required_permission_fkey
    foreign key (required_permission) references public.permission_catalog(permission_key)
    on update cascade on delete restrict;

alter table public.context_subtype_widgets
  add constraint context_subtype_widgets_required_permission_fkey
    foreign key (required_permission) references public.permission_catalog(permission_key)
    on update cascade on delete restrict;
