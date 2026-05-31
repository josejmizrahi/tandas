-- 00058 — Slice E.2: drop legacy `rules` columns + rewrite writers in
-- platform-only shape.
--
-- Plan: `Plans/Active/RulesPlatformOnly.md` § Slice E.2.
-- Pre-reqs: E.1 (PR #3, commit 625aa5a) renamed iOS view callsites and made
-- `LiveRuleRepository.setEnabled` dual-write `enabled`/`is_active`. This
-- migration completes the cleanup by:
--
--   1. Rewriting `create_initial_rule` to take platform fields directly
--      (slug, name, is_active, trigger jsonb, conditions jsonb,
--      consequences jsonb). The 00054 helper that translated legacy
--      `code` → platform shape is now redundant.
--   2. Rewriting `seed_dinner_template_rules` to insert platform-only
--      rows. The legacy column writes are dropped.
--   3. Rewriting `emit_rule_mutation_events` (00024) to read
--      `is_active` and `name` instead of the dropped `enabled` and
--      `title` columns. Audit semantics unchanged: still one
--      `ruleEnabledChanged` row per is_active flip, one
--      `ruleAmountChanged` per consequences change.
--   4. ALTER TABLE rules DROP COLUMN code, title, description, trigger,
--      action, enabled, status, exceptions, approved_via_vote_id.
--
-- Backfill safety: every prod row inserted post-00018 has its platform
-- columns populated (00018 backfilled pre-Sprint-1b groups, and 00054
-- ensured every subsequent insert via `create_initial_rule` writes both
-- shapes). E.1's setEnabled dual-write closed the only divergent writer.
-- Verified before applying via:
--   select count(*) from rules
--    where name is null or is_active is null
--       or trigger is null;
-- Should be 0.

-- =========================================================
-- 1. create_initial_rule — platform-only signature
-- =========================================================
-- Drop the old (uuid, text, text, text, jsonb, jsonb) overload first so
-- the new (uuid, text, text, boolean, jsonb, jsonb, jsonb) signature
-- doesn't collide with stale grants.
drop function if exists public.create_initial_rule(uuid, text, text, text, jsonb, jsonb);

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
  r public.rules;
begin
  if not public.is_group_admin(p_group_id, auth.uid()) then
    raise exception 'only admins can seed rules';
  end if;

  insert into public.rules (
    group_id, slug, name, is_active, trigger, conditions, consequences,
    proposed_by
  ) values (
    p_group_id, p_slug, p_name, p_is_active,
    p_trigger, coalesce(p_conditions, '[]'::jsonb), coalesce(p_consequences, '[]'::jsonb),
    auth.uid()
  ) returning * into r;
  return r;
end;
$$;

revoke execute on function public.create_initial_rule(uuid, text, text, boolean, jsonb, jsonb, jsonb) from public, anon;
grant  execute on function public.create_initial_rule(uuid, text, text, boolean, jsonb, jsonb, jsonb) to authenticated;

comment on function public.create_initial_rule(uuid, text, text, boolean, jsonb, jsonb, jsonb) is
  'Founder-onboarding seed for one rule. Platform-only since Slice E.2 (00058) — caller sends slug/name/is_active/trigger/conditions/consequences in canonical shape.';

-- =========================================================
-- 2. seed_dinner_template_rules — platform-only INSERT
-- =========================================================
create or replace function public.seed_dinner_template_rules(
  p_group_id uuid
) returns setof public.rules
language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
begin
  if uid is null then raise exception 'not authenticated'; end if;
  if not public.is_group_admin(p_group_id, uid) then
    raise exception 'only group admins can seed template rules';
  end if;

  -- Idempotency: skip if any platform-shape rule already exists for this group.
  if exists (
    select 1 from public.rules
     where group_id = p_group_id
       and consequences <> '[]'::jsonb
  ) then
    return;
  end if;

  return query
  insert into public.rules (
    group_id, slug, name, is_active, trigger, conditions, consequences,
    proposed_by
  )
  values
  (
    p_group_id, 'dinner_late_arrival',
    'Llegada tardía', true,
    jsonb_build_object('eventType', 'checkInRecorded', 'config', '{}'::jsonb),
    jsonb_build_array(
      jsonb_build_object('type', 'checkInMinutesLate', 'config', jsonb_build_object('thresholdMinutes', 0))
    ),
    jsonb_build_array(
      jsonb_build_object('type', 'fine', 'config', jsonb_build_object('baseAmount', 200, 'stepAmount', 50, 'stepMinutes', 30))
    ),
    uid
  ),
  (
    p_group_id, 'dinner_no_response',
    'No confirmó a tiempo', true,
    jsonb_build_object('eventType', 'eventClosed', 'config', '{}'::jsonb),
    jsonb_build_array(
      jsonb_build_object('type', 'responseStatusIs', 'config', jsonb_build_object('status', 'pending'))
    ),
    jsonb_build_array(
      jsonb_build_object('type', 'fine', 'config', jsonb_build_object('amount', 200))
    ),
    uid
  ),
  (
    p_group_id, 'dinner_same_day_cancel',
    'Cancelación mismo día', true,
    jsonb_build_object('eventType', 'rsvpChangedSameDay', 'config', '{}'::jsonb),
    jsonb_build_array(
      jsonb_build_object('type', 'alwaysTrue', 'config', '{}'::jsonb)
    ),
    jsonb_build_array(
      jsonb_build_object('type', 'fine', 'config', jsonb_build_object('amount', 200))
    ),
    uid
  ),
  (
    p_group_id, 'dinner_no_show',
    'No-show', true,
    jsonb_build_object('eventType', 'eventClosed', 'config', '{}'::jsonb),
    jsonb_build_array(
      jsonb_build_object('type', 'responseStatusIs', 'config', jsonb_build_object('status', 'going')),
      jsonb_build_object('type', 'checkInExists',     'config', jsonb_build_object('exists', false))
    ),
    jsonb_build_array(
      jsonb_build_object('type', 'fine', 'config', jsonb_build_object('amount', 300))
    ),
    uid
  ),
  (
    p_group_id, 'dinner_host_no_menu',
    'Anfitrión sin menú', false,
    jsonb_build_object('eventType', 'hoursBeforeEvent', 'config', jsonb_build_object('hours', 24)),
    jsonb_build_array(
      jsonb_build_object('type', 'eventDescriptionMissing', 'config', '{}'::jsonb)
    ),
    jsonb_build_array(
      jsonb_build_object('type', 'fine', 'config', jsonb_build_object('amount', 200))
    ),
    uid
  )
  returning *;
end;
$$;

revoke execute on function public.seed_dinner_template_rules(uuid) from public, anon;
grant  execute on function public.seed_dinner_template_rules(uuid) to authenticated;

-- =========================================================
-- 3. emit_rule_mutation_events — read is_active + name
-- =========================================================
-- Audit trigger now reads the platform columns. Same semantics: emit
-- ruleEnabledChanged on `is_active` flip, ruleAmountChanged on
-- consequences change. The system_events `event_type` strings stay
-- unchanged so consumers don't break.
create or replace function public.emit_rule_mutation_events()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_member_id uuid;
begin
  select id into v_member_id
  from public.group_members
  where group_id = new.group_id
    and user_id = auth.uid()
    and active
  limit 1;

  if new.is_active is distinct from old.is_active then
    insert into public.system_events (group_id, event_type, resource_id, member_id, payload)
    values (new.group_id, 'ruleEnabledChanged', new.id, v_member_id, jsonb_build_object(
      'rule_name', new.name,
      'before', old.is_active,
      'after', new.is_active
    ));
  end if;

  if new.consequences is distinct from old.consequences then
    insert into public.system_events (group_id, event_type, resource_id, member_id, payload)
    values (new.group_id, 'ruleAmountChanged', new.id, v_member_id, jsonb_build_object(
      'rule_name', new.name,
      'before', old.consequences,
      'after', new.consequences
    ));
  end if;

  return new;
end;
$$;

comment on function public.emit_rule_mutation_events() is
  'Emits ruleEnabledChanged / ruleAmountChanged system_events atomically on UPDATE. Slice E.2 (00058) switched from reading enabled/title to is_active/name.';

-- =========================================================
-- 4. archive_rule_on_repeal_pass — write is_active instead of enabled+status
-- =========================================================
-- 00026 archives a rule when its rule_repeal vote resolves passed by
-- writing `enabled = false` + `status = 'archived'`. After E.2 the
-- canonical signal is `is_active = false`. The trigger keeps firing the
-- ruleEnabledChanged audit event via emit_rule_mutation_events because
-- is_active flips.
create or replace function public.archive_rule_on_repeal_pass()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.vote_type = 'rule_repeal'
     and new.status = 'resolved'
     and old.status = 'open'
     and (new.payload->>'resolution') = 'passed'
     and new.reference_id is not null then
    update public.rules
    set is_active = false
    where id = new.reference_id;
  end if;
  return new;
end;
$$;

comment on function public.archive_rule_on_repeal_pass() is
  'Archives a rule when its rule_repeal vote resolves passed. Slice E.2 (00058) switched from enabled/status to is_active.';

-- =========================================================
-- 5. Drop the legacy V1 evaluate_event_rules — orphaned
-- =========================================================
-- 00003/00008 defined this V1 fine evaluator that reads `enabled` and
-- `status`. The platform engine in `_shared/ruleEngine.ts` replaced it
-- (driven by `process-system-events` cron). The only mention in edge
-- functions is a "Does NOT invoke evaluate_event_rules" comment in
-- `auto-close-events`, so dropping it is safe.
drop function if exists public.evaluate_event_rules(uuid);

-- =========================================================
-- 6. Drop legacy columns
-- =========================================================
-- Last step. After the writers above no longer touch these columns,
-- the drop is safe. Includes column comments left over from 00033.
alter table public.rules
  drop column if exists code,
  drop column if exists title,
  drop column if exists description,
  drop column if exists trigger,
  drop column if exists action,
  drop column if exists enabled,
  drop column if exists status,
  drop column if exists exceptions,
  drop column if exists approved_via_vote_id;
