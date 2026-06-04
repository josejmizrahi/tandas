-- Hotfix: CREATE OR REPLACE FUNCTION con firma distinta creó un overload nuevo
-- en lugar de reemplazar. Tirar la firma vieja 7-arg para que PostgREST resuelva
-- siempre la nueva 8-arg con p_source_event_id.
drop function if exists public.request_resource_reservation(
  uuid, uuid, timestamptz, timestamptz, uuid, jsonb, text
);