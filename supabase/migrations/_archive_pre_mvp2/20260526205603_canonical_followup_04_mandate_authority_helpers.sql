-- Helper: valida que un mandate autoriza la acción específica.
-- Doctrina: doctrine_mandate_in_money_rpcs.md §validación.
--
-- p_required_scope: 'spend', 'settle', 'pay', 'charge', 'payout', 'contribute', 'represent'.
-- Mandate.scope (jsonb) puede declarar:
--   { "allowed_scopes": ["spend","pay"], "max_amount": 5000, "unit": "MXN", "resource_id": "..." }
-- O usar mandate.mandate_type como single-scope.

create or replace function public._assert_mandate_authorizes(
  p_mandate_id       uuid,
  p_group_id         uuid,
  p_actor_membership uuid,
  p_required_scope   text,
  p_amount           numeric default null,
  p_unit             text default null,
  p_resource_id      uuid default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_m public.group_mandates%rowtype;
begin
  if p_mandate_id is null then return; end if;

  select * into v_m from public.group_mandates where id = p_mandate_id;
  if v_m.id is null then
    raise exception 'mandate % not found', p_mandate_id;
  end if;
  if v_m.group_id <> p_group_id then
    raise exception 'mandate does not authorize this action: wrong group';
  end if;
  if v_m.status <> 'active' then
    raise exception 'mandate does not authorize this action: status=%', v_m.status;
  end if;
  if v_m.revoked_at is not null then
    raise exception 'mandate does not authorize this action: revoked';
  end if;
  if v_m.starts_at is not null and v_m.starts_at > now() then
    raise exception 'mandate does not authorize this action: not yet active';
  end if;
  if v_m.ends_at is not null and v_m.ends_at < now() then
    raise exception 'mandate does not authorize this action: expired at %', v_m.ends_at;
  end if;
  if v_m.representative_membership_id <> p_actor_membership then
    raise exception 'mandate does not authorize this action: caller is not the representative';
  end if;

  -- Scope cover: mandate_type debe ser el scope, o 'represent' (genérico),
  -- o estar listado en scope.allowed_scopes.
  if not (
    v_m.mandate_type = p_required_scope
    or v_m.mandate_type = 'represent'
    or (v_m.scope ? 'allowed_scopes' and v_m.scope->'allowed_scopes' ? p_required_scope)
  ) then
    raise exception 'mandate does not authorize this action: scope mismatch (need=%, holds=%)',
      p_required_scope, v_m.mandate_type;
  end if;

  if p_amount is not null and v_m.scope ? 'max_amount' then
    if p_amount > (v_m.scope->>'max_amount')::numeric then
      raise exception 'mandate does not authorize this action: amount % exceeds max %',
        p_amount, v_m.scope->>'max_amount';
    end if;
  end if;

  if p_unit is not null and v_m.scope ? 'unit' then
    if (v_m.scope->>'unit') <> p_unit then
      raise exception 'mandate does not authorize this action: unit % mismatch (mandate=%)',
        p_unit, v_m.scope->>'unit';
    end if;
  end if;

  if p_resource_id is not null and v_m.scope ? 'resource_id' then
    if (v_m.scope->>'resource_id')::uuid <> p_resource_id then
      raise exception 'mandate does not authorize this action: resource scope mismatch';
    end if;
  end if;
end;
$$;

revoke execute on function public._assert_mandate_authorizes(uuid, uuid, uuid, text, numeric, text, uuid) from anon, public;

comment on function public._assert_mandate_authorizes(uuid, uuid, uuid, text, numeric, text, uuid) is
  'Doctrine: doctrine_mandate_in_money_rpcs.md. Llamado por money RPCs al inicio cuando p_mandate_id is not null. Raise estandariza el prefix "mandate does not authorize this action" para que iOS pueda mapear a un error type único.';
