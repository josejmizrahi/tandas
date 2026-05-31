-- 00122 — Route the rule-create RPCs through `resolve_governance` so
-- the `rule.create` policy seeded by 00100/00111 actually gates the
-- mutation. Today every rule-create path goes is_group_admin-direct,
-- which means a group with `rule.create: vote_required` policy still
-- lets an admin add rules without the vote — silent governance bypass.
--
-- Mirrors the pattern shipped for remove_member in 00120:
--   1. resolve_governance(group, actor, 'rule.create') returns
--      decision: allowed / vote_required / admin_only / denied.
--   2. allowed → insert the rule, return the row.
--   3. vote_required → raise an exception carrying the JSON payload
--      so iOS can auto-promote to a `rule_change` vote via start_vote.
--   4. denied / admin_only-without-permission → clean exception.
--
-- Three RPCs migrated:
--   create_initial_rule       (group-scope, onboarding seed)
--   create_resource_rule      (resource-scope, supersedes create_event_rule)
--   create_event_rule         (legacy event-scope alias, delegates to
--                              create_resource_rule so it picks up the
--                              gate automatically)
--
-- Onboarding flow: recurring_dinner template defaults
-- whoCanModifyRules=founder → seed_default_group_policies (00111) writes
-- rule.create policy as admin_only. Founder has the modifyRules
-- permission via roles jsonb, so the gate resolves to `allowed` for
-- standard onboarding. Groups configured with whoCanModifyRules=
-- majorityVote get rule.create policy_type=vote_required — onboarding
-- seeds would fail until they switch templates or pre-seed via the
-- legacy admin path (seed_template_rules stays on is_group_admin for
-- backward-compat with cron / one-shot setups).

create or replace function public.create_initial_rule(
  p_group_id     uuid,
  p_slug         text,
  p_name         text,
  p_is_active    boolean,
  p_trigger      jsonb,
  p_conditions   jsonb,
  p_consequences jsonb
) returns public.rules
language plpgsql security definer set search_path = public as $$
declare
  r            public.rules;
  v_uid        uuid := auth.uid();
  v_decision   jsonb;
  v_decision_type text;
begin
  if v_uid is null then
    raise exception 'auth required';
  end if;

  v_decision := public.resolve_governance(
    p_group_id, v_uid, 'rule.create', jsonb_build_object('slug', p_slug)
  );
  v_decision_type := v_decision->>'decision';

  if v_decision_type = 'vote_required' then
    raise exception 'governance requires vote: %', v_decision::text;
  end if;
  if v_decision_type = 'denied' then
    raise exception 'governance denied: %', coalesce(v_decision->>'reason', 'no_policy');
  end if;
  if v_decision_type = 'admin_only' then
    raise exception 'admin only';
  end if;

  insert into public.rules (
    group_id, slug, name, is_active, trigger, conditions, consequences, proposed_by
  ) values (
    p_group_id, p_slug, p_name, p_is_active,
    p_trigger, coalesce(p_conditions, '[]'::jsonb), coalesce(p_consequences, '[]'::jsonb),
    v_uid
  ) returning * into r;
  return r;
end;
$$;

comment on function public.create_initial_rule(uuid, text, text, boolean, jsonb, jsonb, jsonb) is
  'Group-scope rule creation. Routes through resolve_governance(rule.create) (00122). vote_required raises an exception so iOS auto-promotes to a rule_change vote.';

create or replace function public.create_resource_rule(
  p_group_id     uuid,
  p_resource_id  uuid,
  p_name         text,
  p_trigger      jsonb,
  p_conditions   jsonb,
  p_consequences jsonb
)
returns public.rules
language plpgsql security definer set search_path = public as $$
declare
  v_rule          public.rules;
  v_resource      public.resources;
  v_uid           uuid := auth.uid();
  v_decision      jsonb;
  v_decision_type text;
  v_is_event_host boolean := false;
begin
  if v_uid is null then
    raise exception 'auth required';
  end if;
  if p_name is null or length(trim(p_name)) < 2 then
    raise exception 'rule name must be at least 2 characters';
  end if;
  if p_trigger is null then
    raise exception 'rule trigger required';
  end if;

  select * into v_resource from public.resources r where r.id = p_resource_id;
  if not found then
    raise exception 'resource not found';
  end if;
  if v_resource.group_id <> p_group_id then
    raise exception 'resource does not belong to group';
  end if;

  v_decision := public.resolve_governance(
    p_group_id,
    v_uid,
    'rule.create',
    jsonb_build_object(
      'resource_id',   p_resource_id::text,
      'resource_type', v_resource.resource_type
    )
  );
  v_decision_type := v_decision->>'decision';

  -- Event-host override: only kicks in when governance returns
  -- admin_only (caller isn't an admin). vote_required + denied still
  -- bind regardless of host status.
  if v_decision_type = 'admin_only'
     and v_resource.resource_type = 'event' then
    select exists(
      select 1 from public.events e
       where e.id = p_resource_id and e.host_id = v_uid
    ) into v_is_event_host;
    if v_is_event_host then
      v_decision_type := 'allowed';
    end if;
  end if;

  if v_decision_type = 'vote_required' then
    raise exception 'governance requires vote: %', v_decision::text;
  end if;
  if v_decision_type = 'denied' then
    raise exception 'governance denied: %', coalesce(v_decision->>'reason', 'no_policy');
  end if;
  if v_decision_type = 'admin_only' then
    raise exception 'admin only';
  end if;

  insert into public.rules (
    group_id, resource_id, slug, name, is_active,
    trigger, conditions, consequences,
    module_key, series_id, membership_id,
    proposed_by
  )
  values (
    p_group_id, p_resource_id, null, trim(p_name), true,
    coalesce(p_trigger, '{}'::jsonb),
    coalesce(p_conditions, '[]'::jsonb),
    coalesce(p_consequences, '[]'::jsonb),
    null, null, null,
    v_uid
  )
  returning * into v_rule;

  return v_rule;
end;
$$;

comment on function public.create_resource_rule(uuid, uuid, text, jsonb, jsonb, jsonb) is
  'Resource-scope rule creation. Routes through resolve_governance(rule.create) (00122). Event host override applies only when governance returns admin_only — vote_required and denied still bind.';

create or replace function public.create_event_rule(
  p_group_id     uuid,
  p_resource_id  uuid,
  p_name         text,
  p_trigger      jsonb,
  p_conditions   jsonb,
  p_consequences jsonb
)
returns public.rules
language plpgsql security definer set search_path = public as $$
begin
  return public.create_resource_rule(
    p_group_id, p_resource_id, p_name, p_trigger, p_conditions, p_consequences
  );
end;
$$;

comment on function public.create_event_rule(uuid, uuid, text, jsonb, jsonb, jsonb) is
  'Legacy alias of create_resource_rule kept for iOS builds pre-00086 rename. Inherits the resolve_governance(rule.create) gate from 00122.';
