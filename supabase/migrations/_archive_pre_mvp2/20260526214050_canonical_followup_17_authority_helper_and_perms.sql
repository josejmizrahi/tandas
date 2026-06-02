-- P1+P2 (foundation): _resolve_authority_path helper.
--
-- Precedencia explícita por doctrina founder:
--   1. Si p_mandate_id is not null → 'mandate' (valida scope, persiste mandate_id).
--   2. Else si p_is_self_party → 'self_party' (sin permission check).
--   3. Else → 'direct_permission' (assert_permission del key).
--
-- No se llama assert_permission al inicio de la RPC. Se delega al helper,
-- que solo lo invoca cuando el path resuelto es direct_permission.

create or replace function public._resolve_authority_path(
  p_group_id          uuid,
  p_actor_membership  uuid,
  p_is_self_party     boolean,
  p_mandate_id        uuid,
  p_permission        text,
  p_mandate_scope     text default 'represent',
  p_amount            numeric default null,
  p_unit              text default null,
  p_resource_id       uuid default null
)
returns text
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_mandate_id is not null then
    perform public._assert_mandate_authorizes(
      p_mandate_id, p_group_id, p_actor_membership,
      p_mandate_scope, p_amount, p_unit, p_resource_id
    );
    return 'mandate';
  end if;

  if p_is_self_party then
    return 'self_party';
  end if;

  perform public.assert_permission(p_group_id, p_permission);
  return 'direct_permission';
end;
$$;

revoke execute on function public._resolve_authority_path(uuid, uuid, boolean, uuid, text, text, numeric, text, uuid) from anon, public;

-- P4+P5: nuevos permisos en catálogo
insert into public.permissions (key, description, category) values
  ('contribution.verify',       'Verificar / rechazar contribuciones',  'money'),
  ('money.transaction.reverse', 'Revertir transacciones de otro miembro', 'money')
on conflict (key) do nothing;

-- P7: permiso elevado para registrar gasto en nombre de otro.
-- expense.record sigue existiendo, pero el direct_permission path para
-- p_paid_by != actor exige el elevado.
insert into public.permissions (key, description, category) values
  ('expense.record_for_others', 'Registrar gasto en nombre de otro miembro', 'money')
on conflict (key) do nothing;

-- Conceder los nuevos permisos al founder role en grupos existentes.
insert into public.group_role_permissions (role_id, permission_key)
select gr.id, p.key
  from public.group_roles gr
  cross join (values ('contribution.verify'),('money.transaction.reverse'),('expense.record_for_others')) as p(key)
 where gr.key = 'founder'
on conflict do nothing;

comment on function public._resolve_authority_path(uuid, uuid, boolean, uuid, text, text, numeric, text, uuid) is
  'Doctrine: doctrine_mandate_in_money_rpcs.md §precedencia. Mandate explícito gana; self_party bypassea permission check; direct_permission exige assert_permission.';
