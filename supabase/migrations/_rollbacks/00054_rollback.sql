-- Rollback for 00048 — restore 00003 broken propose_rule + 00011
-- create_initial_rule (legacy-only writer).
--
-- WARNING: this rollback re-introduces the V1 onboarding bug
-- (rules created via create_initial_rule with no platform shape do NOT
-- fire in the engine).

create or replace function public.create_initial_rule(
  p_group_id uuid,
  p_code text,
  p_title text,
  p_description text,
  p_trigger jsonb,
  p_action jsonb
) returns public.rules
language plpgsql security definer set search_path = public as $$
declare r public.rules;
begin
  if not public.is_group_admin(p_group_id, auth.uid()) then
    raise exception 'only admins can seed rules';
  end if;
  insert into public.rules (
    group_id, code, title, description, trigger, action, status, enabled, proposed_by
  ) values (
    p_group_id, p_code, p_title, p_description, p_trigger, p_action, 'active', true, auth.uid()
  ) returning * into r;
  return r;
end;
$$;
revoke execute on function public.create_initial_rule(uuid, text, text, text, jsonb, jsonb) from public, anon;
grant  execute on function public.create_initial_rule(uuid, text, text, text, jsonb, jsonb) to authenticated;

create or replace function public.propose_rule(
  p_group_id uuid, p_title text, p_description text,
  p_trigger jsonb, p_action jsonb, p_exceptions jsonb, p_committee_only boolean
)
returns public.rules language plpgsql security definer set search_path = public as $$
declare r public.rules;
begin
  if not public.is_group_member(p_group_id, auth.uid()) then raise exception 'not a member'; end if;
  insert into public.rules (group_id, title, description, trigger, action, exceptions, status, proposed_by, enabled)
  values (p_group_id, p_title, p_description, p_trigger, p_action, coalesce(p_exceptions, '[]'::jsonb), 'proposed', auth.uid(), false)
  returning * into r;
  -- Note: the original function called create_vote(...) which was dropped
  -- in 00020. Rollback restores the broken version verbatim.
  return r;
end;
$$;
revoke execute on function public.propose_rule(uuid, text, text, jsonb, jsonb, jsonb, boolean) from public, anon;
grant  execute on function public.propose_rule(uuid, text, text, jsonb, jsonb, jsonb, boolean) to authenticated;
