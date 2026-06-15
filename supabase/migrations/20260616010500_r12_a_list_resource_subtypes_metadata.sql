-- R.12.A.fix — list_resource_subtypes() debe retornar metadata.fields para
-- que el iOS form engine pueda leer el schema. Antes solo retornaba
-- subtype_key/class_key/display_name/description.
create or replace function public.list_resource_subtypes(p_class_key text default null)
returns setof jsonb
language sql security definer set search_path = public, auth
as $$
  select jsonb_build_object(
    'subtype_key',  rs.subtype_key,
    'class_key',    rs.class_key,
    'display_name', rs.display_name,
    'description',  rs.description,
    'metadata',     rs.metadata
  )
  from public.resource_subtypes rs
  where (p_class_key is null or rs.class_key = p_class_key)
    and rs.is_creatable
  order by rs.display_name;
$$;

comment on function public.list_resource_subtypes(text) is
  'R.12.A: ahora incluye metadata (cuyo .fields contiene el FormFieldSpec[] que el iOS form engine consume). subtype_key/class_key/display_name/description sin cambio.';
