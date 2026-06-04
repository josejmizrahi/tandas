-- F.RESOURCE.3 — registrar 'update_resource' en el catálogo canónico para
-- que resource_available_actions lo exponga a OWN/MANAGE como acción canónica.
-- Founder doctrine 2026-06-04: "editar Resource (no settings, sino los campos del recurso)".
--
-- El RPC update_resource ya existe (F.1A polish). Esta mig sólo lo expone
-- en el contrato canónico de F.2X intent-first.

insert into public.resource_action_catalog
  (action_key, display_name, ui_section, required_capability, required_rights, sort_order)
values
  ('update_resource', 'Editar', 'rights', null, array['OWN','MANAGE'], 5)
on conflict (action_key) do update
  set display_name = excluded.display_name,
      ui_section = excluded.ui_section,
      required_capability = excluded.required_capability,
      required_rights = excluded.required_rights,
      sort_order = excluded.sort_order;

do $$
declare
  v_count int;
begin
  select count(*) into v_count from public.resource_action_catalog where action_key = 'update_resource';
  if v_count <> 1 then raise exception 'F.RESOURCE.3 DoD: update_resource no quedó en el catálogo'; end if;
  raise notice 'F.RESOURCE.3 DoD: update_resource registrado en resource_action_catalog';
end $$;
