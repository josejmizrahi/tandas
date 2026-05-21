-- 00357 — Shared pool marker + seed (SharedMoney Phase 1, brick 2).
--
-- Why
-- ===
-- Shared Money doctrine (founder 2026-05-21, doctrine_shared_money.md)
-- says every NEW group is born with exactly ONE canonical shared pool —
-- a resources(type='fund') row stamped is_shared_pool=true. From that
-- pool, gastos/aportaciones contextualize via source_resource_id
-- (mig 00356) rather than spawning new fund rows per event.
--
-- This brick:
--   * Adds a partial unique index enforcing "at most one shared pool
--     per group" so concurrent create_group calls race-safely.
--   * Adds a SECURITY DEFINER helper `seed_shared_pool_for_group` that
--     create_group_with_admin invokes. Idempotent: no-ops if the
--     group already has a shared pool.
--   * Adds `seed_shared_pool_for_existing_group` — admin-gated Option C
--     opt-in path for legacy groups. NOT auto-run on existing data.
--   * Patches `create_group_with_admin` to call the helper after the
--     admin member + template-role seeds, before returning.
--
-- Atom posture (founder decision § 9.5)
-- =====================================
-- Auto-seeded shared pools MUST NOT emit `fundCreated` system_events.
-- Auto-seed is not a human action and would pollute the activity feed.
-- Verified pre-flight: no AFTER INSERT trigger on resources emits
-- fundCreated for fund-typed rows; the existing 4 INSERT triggers
-- either self-filter to resource_type='event' or are universally safe.
-- The atom is only emitted by the explicit `create_fund` RPC, which
-- this helper bypasses by INSERTing directly.
--
-- Metadata stamps (founder decision § 9.5)
-- =========================================
-- For technical traceability without human activity noise, the seeded
-- row carries:
--   * is_shared_pool        : true
--   * seeded_by_system      : true
--   * seeded_at             : ISO timestamp at insert time
--   * currency              : copied from p_currency (founder § 9.1)
--   * name                  : 'Dinero compartido' (founder § 9.2)
--
-- Future debug/audit can distinguish seeded rows via
-- metadata.seeded_by_system without parsing activity.
--
-- Existing groups (Option C, ratified)
-- ====================================
-- This migration does NOT touch existing rows. Legacy groups continue
-- to work with whatever fund(s) they currently have. The opt-in path
-- is `seed_shared_pool_for_existing_group(p_group_id)` — admin-gated,
-- idempotent, surfaceable by Phase 3 UI ("Activar dinero compartido").
--
-- Rollback
-- ========
-- _rollbacks/20260521151500_rollback.sql restores create_group_with_admin
-- to its pre-mig body, drops both helper RPCs, then drops the unique
-- index. Already-seeded shared pool rows on NEW groups stay — they're
-- inert fund rows behaviorally indistinguishable from user-created
-- funds (just with extra metadata.is_shared_pool=true that nothing
-- post-rollback reads).

-- ---------------------------------------------------------------------
-- 1. Partial unique index: at most one active shared pool per group.
-- ---------------------------------------------------------------------
-- WHERE clause uses metadata->>'is_shared_pool' = 'true' (text compare)
-- which works for both jsonb true and "true" string variants.
-- Filters archived_at IS NULL so a group could theoretically archive
-- its shared pool and create a new one — but the helper is idempotent
-- and seed-on-create only, so this is forward-compat only.

create unique index if not exists resources_one_shared_pool_per_group
  on public.resources (group_id)
 where resource_type = 'fund'
   and (metadata->>'is_shared_pool') = 'true'
   and archived_at is null;

comment on index public.resources_one_shared_pool_per_group is
  'SharedMoney Phase 1 (mig 00357): exactly one active shared pool per group. Partial on (resource_type=fund, is_shared_pool=true, not archived). Concurrent create_group calls race-safely on unique_violation.';

-- ---------------------------------------------------------------------
-- 2. Helper: seed_shared_pool_for_group(p_group_id, p_currency).
-- ---------------------------------------------------------------------
-- SECURITY DEFINER. Idempotent: returns the existing shared pool row if
-- one already exists for the group, else inserts and returns the new
-- row. Caller (create_group_with_admin) handles authz already; this
-- helper is internal — exposing it would be a footgun.
--
-- created_by resolves to auth.uid() at call time. For
-- create_group_with_admin context that's the group creator. For
-- seed_shared_pool_for_existing_group (next function), it's the
-- admin invoking the opt-in.

create or replace function public.seed_shared_pool_for_group(
  p_group_id  uuid,
  p_currency  text default null
)
returns public.resources
language plpgsql
security definer
set search_path = 'public', 'pg_catalog'
as $$
declare
  v_uid        uuid := auth.uid();
  v_currency   text;
  v_existing   public.resources;
  v_new        public.resources;
begin
  if p_group_id is null then
    raise exception 'seed_shared_pool_for_group: p_group_id required'
      using errcode = '22023';
  end if;
  if v_uid is null then
    raise exception 'auth required' using errcode = '42501';
  end if;

  -- Idempotency check (optimistic). The partial unique index is the
  -- race-safe backstop — if a parallel caller wins the INSERT, our
  -- INSERT below catches unique_violation and re-fetches.
  select *
    into v_existing
    from public.resources
   where group_id = p_group_id
     and resource_type = 'fund'
     and (metadata->>'is_shared_pool') = 'true'
     and archived_at is null
   limit 1;

  if v_existing.id is not null then
    return v_existing;
  end if;

  -- Resolve currency: explicit param wins; fall through to groups.currency
  -- then to MXN (matches the rest of the platform's defaults).
  v_currency := coalesce(
    p_currency,
    (select currency from public.groups where id = p_group_id),
    'MXN'
  );

  begin
    insert into public.resources (
      group_id, resource_type, status, metadata, created_by
    ) values (
      p_group_id,
      'fund',
      'active',
      jsonb_build_object(
        'name',              'Dinero compartido',
        'currency',          v_currency,
        'target_amount_cents', null,
        'is_shared_pool',    true,
        'seeded_by_system',  true,
        'seeded_at',         to_jsonb(now())
      ),
      v_uid
    )
    returning * into v_new;
  exception when unique_violation then
    -- Race: another caller seeded between our SELECT and INSERT.
    -- Re-fetch and return their row. Idempotency preserved.
    select * into v_existing
      from public.resources
     where group_id = p_group_id
       and resource_type = 'fund'
       and (metadata->>'is_shared_pool') = 'true'
       and archived_at is null
     limit 1;
    if v_existing.id is not null then
      return v_existing;
    end if;
    raise;
  end;

  -- NOTE: deliberately NO record_system_event('fundCreated') here.
  -- Founder doctrine § 9.5: auto-seed must not pollute activity feed.
  -- Technical trace lives in metadata.seeded_by_system + seeded_at.

  return v_new;
end;
$$;

comment on function public.seed_shared_pool_for_group(uuid, text) is
  'SharedMoney Phase 1 (mig 00357): idempotent helper that seeds the canonical shared pool fund row for a group. Called by create_group_with_admin on new groups; called by seed_shared_pool_for_existing_group as Option C opt-in for legacy groups. No fundCreated atom (founder § 9.5). Stamps metadata.is_shared_pool / seeded_by_system / seeded_at for traceability.';

-- Internal helper — restrict execute. create_group_with_admin (also
-- SECURITY DEFINER) and seed_shared_pool_for_existing_group call it
-- with their own SD privileges.
revoke execute on function public.seed_shared_pool_for_group(uuid, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 3. Admin opt-in for existing groups (Option C path).
-- ---------------------------------------------------------------------
-- Idempotent. Caller must be an active admin of the group. Phase 3 UI
-- will surface a "Activar dinero compartido" affordance that hits this
-- RPC. Until opted in, legacy groups continue working as today.

create or replace function public.seed_shared_pool_for_existing_group(
  p_group_id uuid
)
returns public.resources
language plpgsql
security definer
set search_path = 'public', 'pg_catalog'
as $$
declare
  v_uid     uuid := auth.uid();
  v_pool    public.resources;
begin
  if v_uid is null then
    raise exception 'auth required' using errcode = '42501';
  end if;
  if p_group_id is null then
    raise exception 'seed_shared_pool_for_existing_group: p_group_id required'
      using errcode = '22023';
  end if;

  -- Admin gate: only admins of the group may opt-in. Reuses the
  -- platform's permission helper for consistency with other admin RPCs.
  if not public.is_group_admin(p_group_id, v_uid) then
    raise exception 'only admins can activate shared money for an existing group'
      using errcode = '42501';
  end if;

  v_pool := public.seed_shared_pool_for_group(p_group_id, null);
  return v_pool;
end;
$$;

comment on function public.seed_shared_pool_for_existing_group(uuid) is
  'SharedMoney Phase 1 (mig 00357) — Option C opt-in: admin-gated entry point to seed the canonical shared pool on a LEGACY group that pre-dates the SharedMoney doctrine. Idempotent. Phase 3 UI surfaces this as "Activar dinero compartido". No auto-migration: callers always invoke explicitly.';

revoke execute on function public.seed_shared_pool_for_existing_group(uuid) from public, anon;
grant  execute on function public.seed_shared_pool_for_existing_group(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 4. Patch create_group_with_admin to seed the pool on new groups.
-- ---------------------------------------------------------------------
-- Re-defines the function with the seed call appended after the
-- existing admin-member + template-role seeds. All prior behavior
-- preserved — only the trailing `perform public.seed_shared_pool_for_group`
-- is new.

create or replace function public.create_group_with_admin(
  p_name                       text,
  p_description                text default null,
  p_currency                   text default 'MXN',
  p_timezone                   text default 'America/Mexico_City',
  p_base_template              text default null,
  p_cover_image_name           text default null,
  p_initial_event_vocabulary   text default null
)
returns public.groups
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  g                       public.groups;
  uid                     uuid := auth.uid();
  template_config         jsonb;
  resolved_event_vocab    text;
  resolved_active_modules jsonb;
  resolved_governance     jsonb;
  resolved_settings       jsonb;
  resolved_category       text;
  resolved_initials       text;
  trimmed_name            text := trim(p_name);
begin
  if uid is null then
    raise exception 'not authenticated';
  end if;

  if trimmed_name is null or length(trimmed_name) = 0 then
    raise exception 'create_group_with_admin: p_name is required';
  end if;

  if p_base_template is not null and length(trim(p_base_template)) > 0 then
    select t.config into template_config
      from public.templates t
     where t.id = p_base_template
     limit 1;
  end if;

  resolved_event_vocab := coalesce(
    nullif(p_initial_event_vocabulary, ''),
    template_config #>> '{presentation,defaultEventLabel}',
    template_config #>> '{defaultSettings,eventVocabulary}',
    'evento'
  );

  resolved_active_modules := coalesce(
    template_config -> 'defaultModules',
    '[]'::jsonb
  );

  resolved_governance := coalesce(template_config -> 'defaultGovernance', '{}'::jsonb);

  resolved_settings := coalesce(template_config -> 'defaultSettings', '{}'::jsonb)
    || jsonb_build_object('eventVocabulary', resolved_event_vocab);

  resolved_category := coalesce(template_config ->> 'defaultCategory', 'socialRecurring');

  resolved_initials := upper(
    case
      when array_length(string_to_array(trimmed_name, ' '), 1) >= 2 then
        substring(trim(split_part(trimmed_name, ' ', 1)) from 1 for 1) ||
        substring(trim(split_part(trimmed_name, ' ', 2)) from 1 for 1)
      else
        substring(trimmed_name from 1 for 2)
    end
  );

  insert into public.groups (
    name, description, currency, timezone, base_template,
    cover_image_name, active_modules, governance, settings, category,
    initials, created_by
  ) values (
    trimmed_name, nullif(trim(coalesce(p_description, '')), ''),
    coalesce(p_currency, 'MXN'),
    coalesce(p_timezone, 'America/Mexico_City'),
    p_base_template,
    p_cover_image_name,
    resolved_active_modules,
    resolved_governance,
    resolved_settings,
    resolved_category,
    resolved_initials,
    uid
  ) returning * into g;

  insert into public.group_members (group_id, user_id, role, roles, active)
    values (g.id, uid, 'admin', '["founder","member"]'::jsonb, true);

  if p_base_template is not null and length(trim(p_base_template)) > 0 then
    perform public.seed_template_roles(p_base_template, g.id);
  end if;

  -- SharedMoney Phase 1 (mig 00357): seed the canonical shared pool.
  -- Idempotent; no fundCreated atom; stamps is_shared_pool / seeded_by_system.
  perform public.seed_shared_pool_for_group(g.id, coalesce(p_currency, 'MXN'));

  return g;
end;
$function$;

comment on function public.create_group_with_admin(text, text, text, text, text, text, text) is
  'Creates a new group + admin member + template-role seeds + (mig 00357) the canonical shared money pool. SECURITY DEFINER. Every new group is born with exactly one is_shared_pool=true fund row.';
