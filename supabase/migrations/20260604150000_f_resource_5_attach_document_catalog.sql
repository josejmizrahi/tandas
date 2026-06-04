-- F.RESOURCE.5 — registrar attach_document en resource_action_catalog para
-- que resource_available_actions lo emita canónicamente. iOS hoy lo suple
-- con un fallback canAttachDocuments(rights) — F.2X violation. Esta mig
-- cierra el gap doctrinal: el catálogo es la fuente de verdad.

insert into public.resource_action_catalog
  (action_key, display_name, ui_section, required_capability, required_rights, sort_order)
values
  ('attach_document', 'Adjuntar documento', 'documents', null, array['OWN','MANAGE','USE'], 52)
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
  select count(*) into v_count from public.resource_action_catalog where action_key = 'attach_document';
  if v_count <> 1 then raise exception 'F.RESOURCE.5 DoD: attach_document no quedó en el catálogo'; end if;
  raise notice 'F.RESOURCE.5 DoD: attach_document registrado en resource_action_catalog';
end $$;
