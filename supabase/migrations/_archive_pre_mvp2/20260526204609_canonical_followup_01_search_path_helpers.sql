-- Fix 7 helpers para que tengan search_path inmutable. Cierra el lint
-- function_search_path_mutable. Comportamiento no cambia.

create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = public
as $$
begin new.updated_at = now(); return new; end;
$$;

create or replace function public.atom_no_mutation_guard()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_whitelist text[];
  v_col text;
begin
  if TG_ARGV[0] is not null then
    v_whitelist := string_to_array(TG_ARGV[0], ',');
  else
    v_whitelist := ARRAY[]::text[];
  end if;
  foreach v_col in array (
    select array_agg(column_name::text)
    from information_schema.columns
    where table_schema = TG_TABLE_SCHEMA and table_name = TG_TABLE_NAME
  )
  loop
    if v_col = any(v_whitelist) then continue; end if;
    if to_jsonb(new) -> v_col is distinct from to_jsonb(old) -> v_col then
      raise exception 'atom_no_mutation_guard: column % is immutable on table %.%',
        v_col, TG_TABLE_SCHEMA, TG_TABLE_NAME;
    end if;
  end loop;
  return new;
end;
$$;

create or replace function public.atom_no_delete_guard()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  raise exception 'append-only table %.%: delete is not allowed',
    TG_TABLE_SCHEMA, TG_TABLE_NAME;
end;
$$;

create or replace function public.assert_same_group(p_a uuid, p_b uuid)
returns void
language plpgsql
set search_path = public
as $$
begin
  if p_a is null or p_b is null then raise exception 'assert_same_group: null group_id'; end if;
  if p_a is distinct from p_b then raise exception 'cross-tenant violation: group_id mismatch (% vs %)', p_a, p_b; end if;
end;
$$;

create or replace function public.assert_resource_type()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_expected text := TG_ARGV[0];
  v_actual   text;
begin
  select resource_type into v_actual from public.group_resources where id = NEW.resource_id;
  if v_actual is distinct from v_expected then
    raise exception 'resource % has type %, expected %', NEW.resource_id, v_actual, v_expected;
  end if;
  return NEW;
end;
$$;

create or replace function public.assert_member_role_same_group()
returns trigger
language plpgsql
set search_path = public
as $$
declare v_membership_group uuid; v_role_group uuid;
begin
  select group_id into v_membership_group from public.group_memberships where id = NEW.membership_id;
  select group_id into v_role_group       from public.group_roles       where id = NEW.role_id;
  perform public.assert_same_group(v_membership_group, v_role_group);
  return NEW;
end;
$$;

create or replace function public.assert_settlement_obligation_same_group()
returns trigger
language plpgsql
set search_path = public
as $$
declare v_s uuid; v_o uuid;
begin
  select group_id into v_s from public.group_settlements where id = NEW.settlement_id;
  select group_id into v_o from public.group_obligations where id = NEW.obligation_id;
  perform public.assert_same_group(v_s, v_o);
  return NEW;
end;
$$;
