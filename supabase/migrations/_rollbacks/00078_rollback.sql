-- 00078 rollback — Reverse BigBang OpenPlatform Foundation.
--
-- Note: this rollback CANNOT restore wiped Beta 1 data. It only reverses the
-- schema changes. Use only if a critical regression appears; data loss is
-- permanent. Roll-forward is the expected path.

-- =========================================================
-- 1. Drop new tables (and their RLS / indexes via cascade)
-- =========================================================
drop table if exists public.rsvp_actions          cascade;
drop table if exists public.ledger_entries        cascade;
drop table if exists public.resource_capabilities cascade;
drop table if exists public.resource_series       cascade;

-- =========================================================
-- 2. Drop helper RPC
-- =========================================================
drop function if exists public.list_module_capability_blocks();

-- =========================================================
-- 3. Drop columns added to existing tables
-- =========================================================
drop index if exists public.idx_rules_membership;
drop index if exists public.idx_rules_series;
alter table public.rules
  drop column if exists membership_id,
  drop column if exists series_id;

drop index if exists public.idx_resources_series;
alter table public.resources
  drop column if exists series_id;

alter table public.modules
  drop column if exists provided_capability_blocks;

-- =========================================================
-- 4. Restore legacy RPCs
-- =========================================================
create or replace function public.seed_template_rules_legacy(
  p_template_id text,
  p_group_id    uuid
) returns setof public.rules
language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  v_default_rules jsonb;
begin
  if uid is null then raise exception 'not authenticated'; end if;
  if not public.is_group_admin(p_group_id, uid) then
    raise exception 'only group admins can seed template rules';
  end if;
  select config -> 'defaultRules' into v_default_rules
    from public.templates where id = p_template_id;
  if v_default_rules is null or jsonb_typeof(v_default_rules) <> 'array' then
    raise exception 'template % has no defaultRules array', p_template_id;
  end if;
  if exists (select 1 from public.rules where group_id = p_group_id and consequences <> '[]'::jsonb) then
    return;
  end if;
  return query
  insert into public.rules (group_id, slug, name, is_active, trigger, conditions, consequences, proposed_by)
  select p_group_id, r ->> 'slug', r ->> 'name',
    coalesce((r ->> 'isActive')::boolean, true),
    jsonb_build_object('eventType', r -> 'trigger' ->> 'eventType', 'config', coalesce(r -> 'trigger' -> 'config', '{}'::jsonb)),
    coalesce(r -> 'conditions', '[]'::jsonb),
    coalesce(r -> 'consequences', '[]'::jsonb),
    uid
  from jsonb_array_elements(v_default_rules) r returning *;
end;
$$;

revoke execute on function public.seed_template_rules_legacy(text, uuid) from public, anon;
grant  execute on function public.seed_template_rules_legacy(text, uuid) to authenticated;

create or replace function public.seed_dinner_template_rules(p_group_id uuid)
returns setof public.rules
language sql security definer set search_path = public as $$
  select * from public.seed_template_rules('recurring_dinner', p_group_id);
$$;

revoke execute on function public.seed_dinner_template_rules(uuid) from public, anon;
grant  execute on function public.seed_dinner_template_rules(uuid) to authenticated;

-- =========================================================
-- 5. Restore legacy `groups` columns (empty — data was wiped pre-BigBang)
-- =========================================================
alter table public.groups
  add column if not exists event_label          text,
  add column if not exists frequency_type       text,
  add column if not exists frequency_config     jsonb,
  add column if not exists default_day_of_week  int,
  add column if not exists default_start_time   text,
  add column if not exists default_location     text,
  add column if not exists fund_balance         numeric default 0,
  add column if not exists fund_target          numeric,
  add column if not exists rotation_mode        text,
  add column if not exists rotation_enabled     boolean default false;
