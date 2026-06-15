-- R.12.F — Schema declarativo para event subtypes (mismo pattern que R.12.A
-- aplicado a class_key='event'). Los 4 event subtypes ya existen en
-- resource_subtypes pero con metadata={} — esta mig pobla los fields canónicos
-- que CreateEventView/EditEventView van a renderear via DynamicForm.
--
-- Doctrina: calendar_events.metadata jsonb es libre y persistirá los values.
-- No hay nuevo schema de tabla — reusamos el catálogo resource_subtypes
-- (class_key='event' ya seedeado) como single source.

update public.resource_subtypes set metadata = jsonb_build_object('fields', jsonb_build_array(
  jsonb_build_object('key','dress_code','label','Código de vestir','type','text','placeholder','Casual / Formal'),
  jsonb_build_object('key','byob','label','Trae tu bebida','type','boolean'),
  jsonb_build_object('key','menu_summary','label','Menú','type','multiline','placeholder','Qué se va a comer'),
  jsonb_build_object('key','kid_friendly','label','Apto para niños','type','boolean'),
  jsonb_build_object('key','capacity','label','Capacidad','type','number','placeholder','12')
)) where subtype_key = 'dinner';

update public.resource_subtypes set metadata = jsonb_build_object('fields', jsonb_build_array(
  jsonb_build_object('key','agenda','label','Agenda','type','multiline','placeholder','Temas a tratar'),
  jsonb_build_object('key','expected_duration_minutes','label','Duración (min)','type','number','placeholder','60'),
  jsonb_build_object('key','meeting_link','label','Link de videollamada','type','file_url','placeholder','https://meet…'),
  jsonb_build_object('key','requires_preparation','label','Requiere preparación','type','boolean')
)) where subtype_key = 'meeting';

update public.resource_subtypes set metadata = jsonb_build_object('fields', jsonb_build_array(
  jsonb_build_object('key','organizer','label','Organizador','type','text','required',true),
  jsonb_build_object('key','expected_attendance','label','Asistencia esperada','type','number','placeholder','100'),
  jsonb_build_object('key','ticket_url','label','Boletos','type','file_url','placeholder','https://…'),
  jsonb_build_object('key','price_per_person','label','Precio por persona','type','currency'),
  jsonb_build_object('key','currency','label','Moneda','type','picker','options', jsonb_build_array('MXN','USD','EUR')),
  jsonb_build_object('key','is_public','label','Abierto al público','type','boolean')
)) where subtype_key = 'community_event';

update public.resource_subtypes set metadata = jsonb_build_object('fields', jsonb_build_array(
  jsonb_build_object('key','pattern_summary','label','Resumen del patrón','type','text','placeholder','Cada jueves a las 8pm'),
  jsonb_build_object('key','rotates_host','label','Rota anfitrión','type','boolean'),
  jsonb_build_object('key','expected_duration_minutes','label','Duración típica (min)','type','number')
)) where subtype_key = 'recurring_event';

-- Smoke
create or replace function public._smoke_mvp2_r12_f_event_subtype_field_schemas()
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_count int;
begin
  select count(*) into v_count from public.resource_subtypes
    where class_key = 'event' and metadata ? 'fields';
  if v_count < 4 then
    raise exception 'r12_f smoke: esperaba al menos 4 event subtypes con field schema, got %', v_count;
  end if;
  raise notice 'r12_f smoke OK: % event subtypes con field schema', v_count;
end; $$;

revoke all on function public._smoke_mvp2_r12_f_event_subtype_field_schemas() from public, anon, authenticated;
