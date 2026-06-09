-- R.6.D — DSL closed-grammar validator para rules.
--
-- Doctrina (R6_RuleEngineArchitecture §3):
--   * Conditions: closed grammar — operadores + variables tipadas + and/or.
--   * Consequences: closed grammar — type whitelist + per-type required fields.
--   * Backend rechaza al PUBLISH time, no a evaluation time.
--
-- Conservador: el validator soporta sólo lo que `_eval_condition` realmente
-- ejecuta hoy (operadores =/!=/>/>=/</<= + and/or). Type whitelist matches
-- los sinks shipped (R.6.A emit_attention + MVP1 fine/create_obligation).
--
-- Implementación: BEFORE INSERT/UPDATE trigger en `rules` → captura todos los
-- paths (create_rule, update_rule, raw INSERT). Más limpio que rewrap los RPCs
-- (que requeriría DROP+CREATE perdiendo grants).

------------------------------------------------------------------------
-- Validator: condition_tree
------------------------------------------------------------------------
create or replace function public._r6_validate_condition_tree(p_condition jsonb)
returns text -- NULL si valida, mensaje de error si no
language plpgsql
immutable
as $$
declare
  v_op text;
  v_sub jsonb;
  v_err text;
  v_field text;
begin
  if p_condition is null or p_condition = 'null'::jsonb or p_condition = '{}'::jsonb then
    return null;
  end if;
  v_op := lower(p_condition->>'op');
  if v_op is null then return 'condition_tree missing "op" field'; end if;
  if v_op in ('and', 'or') then
    if jsonb_typeof(p_condition->'conditions') <> 'array' then
      return format('condition_tree.op=%s requires "conditions" array', v_op);
    end if;
    for v_sub in select * from jsonb_array_elements(p_condition->'conditions') loop
      v_err := public._r6_validate_condition_tree(v_sub);
      if v_err is not null then return v_err; end if;
    end loop;
    return null;
  end if;
  if v_op not in ('=', '!=', '>', '>=', '<', '<=') then
    return format('condition_tree.op=%s not in allowed operators (=, !=, >, >=, <, <=, and, or)', v_op);
  end if;
  v_field := p_condition->>'field';
  if v_field is null or v_field = '' then
    return format('condition_tree.op=%s requires non-empty "field"', v_op);
  end if;
  if not (p_condition ? 'value') then
    return format('condition_tree.op=%s requires "value" key', v_op);
  end if;
  return null;
end;
$$;

------------------------------------------------------------------------
-- Validator: consequence individual
------------------------------------------------------------------------
create or replace function public._r6_validate_consequence(p_consequence jsonb)
returns text
language plpgsql
immutable
as $$
declare v_type text;
begin
  if p_consequence is null or jsonb_typeof(p_consequence) <> 'object' then
    return 'consequence must be a jsonb object';
  end if;
  v_type := p_consequence->>'type';
  if v_type is null or v_type = '' then return 'consequence missing "type" field'; end if;
  if v_type not in ('fine', 'create_obligation', 'emit_attention') then
    return format('consequence.type=%s not in allowed types (fine, create_obligation, emit_attention)', v_type);
  end if;
  if v_type in ('fine', 'create_obligation') then
    if not (p_consequence ? 'amount' or p_consequence ? 'title') then
      return format('consequence.type=%s requires "amount" or "title"', v_type);
    end if;
    if p_consequence ? 'amount' and jsonb_typeof(p_consequence->'amount') not in ('number', 'string') then
      return format('consequence.type=%s "amount" must be number or numeric string', v_type);
    end if;
  end if;
  if v_type = 'emit_attention' then
    if coalesce(p_consequence->>'title', '') = '' then
      return 'consequence.type=emit_attention requires non-empty "title"';
    end if;
    if coalesce(p_consequence->>'cta_action_key', '') = '' then
      return 'consequence.type=emit_attention requires "cta_action_key"';
    end if;
    if coalesce(p_consequence->>'cta_scope_kind', '') = '' then
      return 'consequence.type=emit_attention requires "cta_scope_kind"';
    end if;
    if p_consequence ? 'priority' and (p_consequence->>'priority') not in ('critical','high','normal','low') then
      return format('consequence.type=emit_attention "priority"=%s not in (critical, high, normal, low)',
        p_consequence->>'priority');
    end if;
  end if;
  return null;
end;
$$;

------------------------------------------------------------------------
-- Validator: array de consequences completo
------------------------------------------------------------------------
create or replace function public._r6_validate_consequences(p_consequences jsonb)
returns text
language plpgsql
immutable
as $$
declare v_c jsonb; v_err text; v_idx int := 0;
begin
  if p_consequences is null or p_consequences = '[]'::jsonb then return null; end if;
  if jsonb_typeof(p_consequences) <> 'array' then return 'consequences must be a jsonb array'; end if;
  for v_c in select * from jsonb_array_elements(p_consequences) loop
    v_err := public._r6_validate_consequence(v_c);
    if v_err is not null then return format('consequences[%s]: %s', v_idx, v_err); end if;
    v_idx := v_idx + 1;
  end loop;
  return null;
end;
$$;

------------------------------------------------------------------------
-- Trigger BEFORE INSERT/UPDATE on rules — captura todos los paths.
------------------------------------------------------------------------

create or replace function public._r6_rules_validate_trigger()
returns trigger
language plpgsql
as $$
declare v_err text;
begin
  v_err := public._r6_validate_condition_tree(NEW.condition_tree);
  if v_err is not null then
    raise exception 'rule validation failed: %', v_err using errcode = '22023';
  end if;
  v_err := public._r6_validate_consequences(NEW.consequences);
  if v_err is not null then
    raise exception 'rule validation failed: %', v_err using errcode = '22023';
  end if;
  return NEW;
end;
$$;

drop trigger if exists trg_r6_rules_validate on public.rules;
create trigger trg_r6_rules_validate
  before insert or update of condition_tree, consequences
  on public.rules
  for each row execute function public._r6_rules_validate_trigger();
