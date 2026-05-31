-- 00073 — seed_module_rules + archive_module_rules RPCs.
--
-- Phase A step 3 of the L1 rules-architecture refactor (audit doc:
-- Plans/Active/L1_Audit_2026-05-10.md).
--
-- Two SECURITY DEFINER functions, both admin-gated:
--
--   public.seed_module_rules(p_group_id uuid, p_module_slug text)
--     returns setof public.rules
--     - Reads modules.provided_rules_def for the slug
--     - Inserts a row per rule into public.rules with module_key = slug
--     - Idempotent: skips slugs that already exist for the group with
--       module_key set (re-enable scenario after archive doesn't dup)
--     - Re-activates archived rules instead of creating duplicates
--
--   public.archive_module_rules(p_group_id uuid, p_module_slug text)
--     returns setof public.rules
--     - Sets is_active = false on every rule with module_key = slug
--     - Does NOT delete (preserves audit + appeal history)
--     - Returns the affected rows
--
-- Wired into set_group_module by 00074. Existing groups get their
-- module_key annotations backfilled in 00075.

-- =========================================================
-- 1. seed_module_rules
-- =========================================================
create or replace function public.seed_module_rules(
  p_group_id    uuid,
  p_module_slug text
) returns setof public.rules
language plpgsql security definer set search_path = public as $$
declare
  uid                 uuid := auth.uid();
  v_provided_rules    jsonb;
  r                   jsonb;
  v_existing_id       uuid;
  v_inserted_or_kept  public.rules;
begin
  if uid is null then
    raise exception 'not authenticated';
  end if;

  if not public.is_group_admin(p_group_id, uid) then
    raise exception 'only group admins can seed module rules';
  end if;

  if p_module_slug is null or length(trim(p_module_slug)) = 0 then
    raise exception 'seed_module_rules: p_module_slug is required';
  end if;

  select provided_rules_def into v_provided_rules
    from public.modules
   where id = p_module_slug;

  if v_provided_rules is null then
    -- Unknown module slug → no-op (forward-compat with iOS shipping a
    -- module slug not yet seeded server-side).
    return;
  end if;

  if jsonb_typeof(v_provided_rules) <> 'array' then
    raise exception 'modules.% provided_rules_def is not an array', p_module_slug;
  end if;

  for r in select * from jsonb_array_elements(v_provided_rules) loop
    -- Re-enable existing archived rule if (group, module, slug) already has one.
    select id into v_existing_id
      from public.rules
     where group_id   = p_group_id
       and module_key = p_module_slug
       and slug       = r ->> 'slug'
     limit 1;

    if v_existing_id is not null then
      update public.rules
         set is_active    = coalesce((r ->> 'isActive')::boolean, true),
             name         = r ->> 'name',
             trigger      = jsonb_build_object(
                              'eventType', r -> 'trigger' ->> 'eventType',
                              'config',    coalesce(r -> 'trigger' -> 'config', '{}'::jsonb)
                            ),
             conditions   = coalesce(r -> 'conditions',   '[]'::jsonb),
             consequences = coalesce(r -> 'consequences', '[]'::jsonb),
             updated_at   = now()
       where id = v_existing_id
       returning * into v_inserted_or_kept;
    else
      insert into public.rules (
        group_id, slug, name, is_active,
        trigger, conditions, consequences,
        module_key, proposed_by
      ) values (
        p_group_id,
        r ->> 'slug',
        r ->> 'name',
        coalesce((r ->> 'isActive')::boolean, true),
        jsonb_build_object(
          'eventType', r -> 'trigger' ->> 'eventType',
          'config',    coalesce(r -> 'trigger' -> 'config', '{}'::jsonb)
        ),
        coalesce(r -> 'conditions',   '[]'::jsonb),
        coalesce(r -> 'consequences', '[]'::jsonb),
        p_module_slug,
        uid
      ) returning * into v_inserted_or_kept;
    end if;

    return next v_inserted_or_kept;
  end loop;

  return;
end;
$$;

revoke execute on function public.seed_module_rules(uuid, text) from public, anon;
grant  execute on function public.seed_module_rules(uuid, text) to authenticated;

comment on function public.seed_module_rules(uuid, text) is
  'Seeds rules for a module activation. Reads modules.provided_rules_def[slug] and upserts into public.rules with module_key = slug. Idempotent — re-enables archived rules instead of duplicating. Called by set_group_module on enable.';

-- =========================================================
-- 2. archive_module_rules
-- =========================================================
create or replace function public.archive_module_rules(
  p_group_id    uuid,
  p_module_slug text
) returns setof public.rules
language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
begin
  if uid is null then
    raise exception 'not authenticated';
  end if;

  if not public.is_group_admin(p_group_id, uid) then
    raise exception 'only group admins can archive module rules';
  end if;

  if p_module_slug is null or length(trim(p_module_slug)) = 0 then
    raise exception 'archive_module_rules: p_module_slug is required';
  end if;

  return query
  update public.rules
     set is_active  = false,
         updated_at = now()
   where group_id   = p_group_id
     and module_key = p_module_slug
     and is_active  = true
   returning *;
end;
$$;

revoke execute on function public.archive_module_rules(uuid, text) from public, anon;
grant  execute on function public.archive_module_rules(uuid, text) to authenticated;

comment on function public.archive_module_rules(uuid, text) is
  'Archives (is_active=false) all rules with module_key = slug for a group. Does NOT delete — preserves audit, appeal, and fine-history references. Called by set_group_module on disable.';
