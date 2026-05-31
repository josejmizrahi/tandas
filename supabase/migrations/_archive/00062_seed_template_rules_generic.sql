-- 00062 — Generic `seed_template_rules` RPC reading from
-- `templates.config -> 'defaultRules'`.
--
-- Closes Gap 2 from the post-Slice-E.2 audit. Migration 00038's
-- closing note flagged it: «Add a generic seed_template_rules RPC
-- that reads from templates.config.defaultRules and inserts into
-- public.rules. Replaces template-specific RPCs (the dinner one +
-- future shared_resource one)». Until now templates.config.defaultRules
-- was effectively documentation jsonb — `seed_dinner_template_rules`
-- (00015/00035/00058) hardcoded its own copy of the same 5 rules
-- inside the function body, and shipping a 2nd template required a
-- 2nd template-specific RPC.
--
-- The generic RPC iterates `templates.config -> 'defaultRules'`,
-- normalizes each rule entry into the platform-only shape from
-- mig 00058 (slug, name, is_active, trigger, conditions,
-- consequences) and bulk-inserts. The legacy
-- `seed_dinner_template_rules(uuid)` is rewritten as a thin wrapper
-- that calls the generic version with `recurring_dinner` so any
-- in-flight clients keep working until they redeploy.

create or replace function public.seed_template_rules(
  p_template_id text,
  p_group_id    uuid
) returns setof public.rules
language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  v_default_rules jsonb;
begin
  if uid is null then
    raise exception 'not authenticated';
  end if;
  if not public.is_group_admin(p_group_id, uid) then
    raise exception 'only group admins can seed template rules';
  end if;

  select config -> 'defaultRules' into v_default_rules
    from public.templates
   where id = p_template_id;

  if v_default_rules is null or jsonb_typeof(v_default_rules) <> 'array' then
    raise exception 'template % has no defaultRules array', p_template_id;
  end if;

  -- Idempotency: re-seeding a group that already has any platform-shape
  -- rule is a no-op. Same guard as the dinner-specific predecessor.
  if exists (
    select 1 from public.rules
     where group_id = p_group_id
       and consequences <> '[]'::jsonb
  ) then
    return;
  end if;

  return query
  insert into public.rules (
    group_id, slug, name, is_active,
    trigger, conditions, consequences,
    proposed_by
  )
  select
    p_group_id,
    r ->> 'slug',
    r ->> 'name',
    coalesce((r ->> 'isActive')::boolean, true),
    -- Templates store trigger as { eventType: ..., config?: ... };
    -- normalize so engine consumers always see both keys.
    jsonb_build_object(
      'eventType', r -> 'trigger' ->> 'eventType',
      'config',    coalesce(r -> 'trigger' -> 'config', '{}'::jsonb)
    ),
    coalesce(r -> 'conditions',   '[]'::jsonb),
    coalesce(r -> 'consequences', '[]'::jsonb),
    uid
  from jsonb_array_elements(v_default_rules) r
  returning *;
end;
$$;

revoke execute on function public.seed_template_rules(text, uuid) from public, anon;
grant  execute on function public.seed_template_rules(text, uuid) to authenticated;

comment on function public.seed_template_rules(text, uuid) is
  'Generic template-rule seeder. Reads templates.config.defaultRules and bulk-inserts into public.rules in platform shape. Idempotent. Replaces template-specific seeders (00015/00035/00058) — Phase 2+ templates do NOT need their own RPC.';

-- =========================================================
-- Backwards-compat wrapper for in-flight clients
-- =========================================================
-- iOS code prior to this migration calls `seed_dinner_template_rules`
-- directly. Keep that name working as a thin proxy until every
-- deployed build picks up the rename. Clients that pass templateId
-- via `seed_template_rules` get the same result.

create or replace function public.seed_dinner_template_rules(
  p_group_id uuid
) returns setof public.rules
language sql security definer set search_path = public as $$
  select * from public.seed_template_rules('recurring_dinner', p_group_id);
$$;

revoke execute on function public.seed_dinner_template_rules(uuid) from public, anon;
grant  execute on function public.seed_dinner_template_rules(uuid) to authenticated;

comment on function public.seed_dinner_template_rules(uuid) is
  'Back-compat wrapper for legacy clients. Calls seed_template_rules(''recurring_dinner'', p_group_id). Drop after all clients migrate to the generic RPC.';
