-- ============================================================================
-- 00001_canonical_schema.sql — Ruul canonical schema (DRAFT)
-- ============================================================================
--
-- Reemplaza las 343 migraciones forward acumuladas hasta 2026-05-26.
-- Doctrina fuente: Plans/Active/GroupPrimitives.md (25 primitivas).
-- Decisiones de modelado: Plans/Active/Plan.md §2 + memoria
--                        doctrine_canonical_schema_decisions.md.
--
-- Principio: "Todo lo social importante tiene entidad propia."
-- No esconder deuda en transacciones, representación en roles,
-- cultura en settings, disolución en archived, ni reputación en un score.
--
-- Convenciones:
--   * prefijo `group_*` para tablas multi-tenant
--   * `text` con `check (… in (…))` para enums (no enum types nativos)
--   * `id uuid primary key default gen_random_uuid()`
--   * `created_at`/`updated_at timestamptz not null default now()`
--   * append-only enforced via trigger atom_no_mutation_guard
--   * RLS habilitado en todas las tablas con policies via helpers
--   * security definer functions con `set search_path = public`
--   * comentario SQL por tabla nombrando la(s) primitiva(s) que cubre
--
-- ============================================================================

-- ============================================================================
-- §0. Extensions + helper functions
-- ============================================================================

create extension if not exists pgcrypto;

-- Trigger universal: set updated_at on UPDATE.
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- Trigger universal: reject UPDATE except whitelisted columns. Used by
-- append-only tables. The whitelist of mutable columns comes via TG_ARGV[0]
-- as a comma-separated list. Empty/absent argv = strictly immutable.
create or replace function public.atom_no_mutation_guard()
returns trigger
language plpgsql
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
    where table_schema = TG_TABLE_SCHEMA
      and table_name   = TG_TABLE_NAME
  )
  loop
    if v_col = any(v_whitelist) then
      continue;
    end if;
    if to_jsonb(new) -> v_col is distinct from to_jsonb(old) -> v_col then
      raise exception
        'atom_no_mutation_guard: column % is immutable on table %.%',
        v_col, TG_TABLE_SCHEMA, TG_TABLE_NAME;
    end if;
  end loop;

  return new;
end;
$$;

-- Trigger universal: reject DELETE on append-only tables.
create or replace function public.atom_no_delete_guard()
returns trigger
language plpgsql
as $$
begin
  raise exception 'append-only table %.%: delete is not allowed',
    TG_TABLE_SCHEMA, TG_TABLE_NAME;
end;
$$;

-- Helper: raise if two group_ids differ. Used by cross-table same-group triggers.
create or replace function public.assert_same_group(p_a uuid, p_b uuid)
returns void
language plpgsql
as $$
begin
  if p_a is null or p_b is null then
    raise exception 'assert_same_group: null group_id';
  end if;
  if p_a is distinct from p_b then
    raise exception 'cross-tenant violation: group_id mismatch (% vs %)', p_a, p_b;
  end if;
end;
$$;

-- Helper: assert that the referenced resource has the expected resource_type.
create or replace function public.assert_resource_type()
returns trigger
language plpgsql
as $$
declare
  v_expected text := TG_ARGV[0];
  v_actual   text;
begin
  select resource_type into v_actual
    from public.group_resources
   where id = NEW.resource_id;
  if v_actual is distinct from v_expected then
    raise exception 'resource % has type %, expected %', NEW.resource_id, v_actual, v_expected;
  end if;
  return NEW;
end;
$$;

-- ============================================================================
-- §1. Identity — profiles (primitive 1: Personas)
-- ============================================================================

create table public.profiles (
  id            uuid primary key references auth.users(id) on delete cascade,
  username      text unique,
  display_name  text,
  avatar_url    text,
  bio           text,
  phone         text,
  timezone      text not null default 'UTC',
  locale        text not null default 'es',
  deleted_at    timestamptz,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
comment on table public.profiles is
  'Primitive 1 (Members) — public per-user identity. 1:1 with auth.users.';

create trigger profiles_set_updated_at before update on public.profiles
  for each row execute function public.set_updated_at();

-- ============================================================================
-- §2. Groups + Purposes (primitives 1, 3, 25)
-- ============================================================================

create table public.groups (
  id            uuid primary key default gen_random_uuid(),
  slug          text unique,
  name          text not null,
  description   text,
  purpose_summary text,                              -- denormalized 1-liner; SOT lives in group_purposes
  visibility    text not null default 'private'
                check (visibility in ('private', 'unlisted', 'public')),
  status        text not null default 'active'
                check (status in ('active','archived','dissolving','dissolved','deleted')),
  category      text,                                 -- 'family' | 'friends' | 'company' | 'community' | ...
  settings      jsonb not null default '{}'::jsonb,
  decision_rules jsonb not null default '{}'::jsonb,  -- thresholds, quorums, who-can rules (was: governance)
  roles_catalog jsonb not null default '{}'::jsonb,   -- custom role definitions per group
  archived_at   timestamptz,
  dissolved_at  timestamptz,
  created_by    uuid references public.profiles(id) on delete set null,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
comment on table public.groups is
  'Primitive 1 (Group identity). decision_rules jsonb carries Permission/Authority config (replaces governance).';

create index groups_status_idx on public.groups(status);

create trigger groups_set_updated_at before update on public.groups
  for each row execute function public.set_updated_at();

create table public.group_purposes (
  id          uuid primary key default gen_random_uuid(),
  group_id    uuid not null references public.groups(id) on delete cascade,
  kind        text not null check (kind in ('declared','operative','emotional')),
  body        text not null,
  visibility  text not null default 'members'
              check (visibility in ('private','members','public')),
  status      text not null default 'active'
              check (status in ('draft','active','archived')),
  created_by  uuid references public.profiles(id) on delete set null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
comment on table public.group_purposes is
  'Primitive 3 (Purpose). Multi-kind. Unique active row per (group, kind).';

create unique index group_purposes_one_active_per_kind
  on public.group_purposes(group_id, kind)
  where status = 'active';

create index group_purposes_group_idx on public.group_purposes(group_id);

create trigger group_purposes_set_updated_at before update on public.group_purposes
  for each row execute function public.set_updated_at();

-- ============================================================================
-- §3. Memberships + lifecycle audit (primitives 1, 2, 15)
-- ============================================================================

create table public.group_memberships (
  id                uuid primary key default gen_random_uuid(),
  group_id          uuid not null references public.groups(id) on delete cascade,
  user_id           uuid not null references public.profiles(id) on delete cascade,
  status            text not null default 'active'
                    check (status in (
                      'requested','invited','active','suspended','left','banned'
                    )),
  membership_type   text not null default 'member'
                    check (membership_type in (
                      'member','provisional','guest','observer','external'
                    )),
  title             text,
  invited_by        uuid references public.profiles(id) on delete set null,
  joined_at         timestamptz,
  provisional_until timestamptz,
  confirmed_at      timestamptz,
  suspended_until   timestamptz,
  suspended_reason  text,
  left_at           timestamptz,
  left_reason       text,
  joined_via        text check (joined_via in ('founder_seed','invite_code','admin_add','placeholder_claim','migration')),
  turn_order        integer,                          -- for rotating-host modules
  metadata          jsonb not null default '{}'::jsonb,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  unique (group_id, user_id)
);
comment on table public.group_memberships is
  'Primitives 1 (Members), 2 (Membership boundary), 15 (Entry/Exit). status = lifecycle, membership_type = quality of belonging.';

create index group_memberships_group_idx on public.group_memberships(group_id);
create index group_memberships_user_idx on public.group_memberships(user_id);
create index group_memberships_active_idx
  on public.group_memberships(group_id, user_id)
  where status = 'active';

create trigger group_memberships_set_updated_at before update on public.group_memberships
  for each row execute function public.set_updated_at();

create table public.group_membership_events (
  id              uuid primary key default gen_random_uuid(),
  group_id        uuid not null references public.groups(id) on delete cascade,
  membership_id   uuid not null references public.group_memberships(id) on delete cascade,
  actor_user_id   uuid references public.profiles(id) on delete set null,
  event_type      text not null check (event_type in (
                    'requested','invited','joined','provisional_started','confirmed',
                    'suspended','reactivated','left','removed','banned',
                    'role_assigned','role_revoked','type_changed','other'
                  )),
  reason          text,
  payload         jsonb not null default '{}'::jsonb,
  created_at      timestamptz not null default now()
);
comment on table public.group_membership_events is
  'Primitive 15 (Entry/Exit audit). Append-only.';

create index group_membership_events_membership_idx
  on public.group_membership_events(membership_id);

create trigger group_membership_events_atom_guard
  before update on public.group_membership_events
  for each row execute function public.atom_no_mutation_guard();
create trigger group_membership_events_no_delete
  before delete on public.group_membership_events
  for each row execute function public.atom_no_delete_guard();

-- ============================================================================
-- §4. Authority — permissions, roles, mandates (primitives 5, 6, 17, 23)
-- ============================================================================

create table public.permissions (
  key         text primary key,
  description text not null,
  category    text not null default 'general'
);
comment on table public.permissions is
  'Primitive 17 (Permissions catalog). Global, read-only for app code.';

create table public.group_roles (
  id           uuid primary key default gen_random_uuid(),
  group_id     uuid not null references public.groups(id) on delete cascade,
  key          text not null,
  name         text not null,
  description  text,
  is_default   boolean not null default false,
  is_system    boolean not null default false,        -- founder/admin/member auto-created
  created_at   timestamptz not null default now(),
  unique (group_id, key)
);
comment on table public.group_roles is
  'Primitive 5 (Roles). Per-group catalog of named roles.';

create unique index group_roles_one_default_per_group
  on public.group_roles(group_id)
  where is_default = true;

create table public.group_role_permissions (
  role_id        uuid not null references public.group_roles(id) on delete cascade,
  permission_key text not null references public.permissions(key) on delete cascade,
  created_at     timestamptz not null default now(),
  primary key (role_id, permission_key)
);
comment on table public.group_role_permissions is
  'Primitive 17 — bridge between roles and the permissions catalog.';

create table public.group_member_roles (
  membership_id  uuid not null references public.group_memberships(id) on delete cascade,
  role_id        uuid not null references public.group_roles(id) on delete cascade,
  assigned_by    uuid references public.profiles(id) on delete set null,
  created_at     timestamptz not null default now(),
  primary key (membership_id, role_id)
);
comment on table public.group_member_roles is
  'Primitive 5/6 — which members hold which roles.';
create index group_member_roles_role_idx on public.group_member_roles(role_id);

create table public.group_mandates (
  id                          uuid primary key default gen_random_uuid(),
  group_id                    uuid not null references public.groups(id) on delete cascade,
  principal_type              text not null check (principal_type in ('group','committee','role','membership')),
  principal_id                uuid,                  -- nullable when principal_type='group'
  representative_membership_id uuid not null references public.group_memberships(id) on delete restrict,
  mandate_type                text not null check (mandate_type in (
                                'speak','sign','vote','negotiate','spend','represent','delegate','other'
                              )),
  scope                       jsonb not null default '{}'::jsonb,   -- e.g. {"counterparty":"vendor X","max_amount":10000}
  status                      text not null default 'active'
                              check (status in ('active','expired','revoked','fulfilled')),
  starts_at                   timestamptz not null default now(),
  ends_at                     timestamptz,
  source_decision_id          uuid,                  -- FK added later (cross-section)
  granted_by                  uuid references public.profiles(id) on delete set null,
  revoked_at                  timestamptz,
  revoked_by                  uuid references public.profiles(id) on delete set null,
  revoked_reason              text,
  metadata                    jsonb not null default '{}'::jsonb,
  created_at                  timestamptz not null default now(),
  updated_at                  timestamptz not null default now()
);
comment on table public.group_mandates is
  'Primitive 23 (Representation). Revocable, scoped delegations. Distinct from roles.';

create index group_mandates_group_idx on public.group_mandates(group_id);
create index group_mandates_rep_idx   on public.group_mandates(representative_membership_id);
create index group_mandates_active_idx on public.group_mandates(group_id) where status = 'active';

create trigger group_mandates_set_updated_at before update on public.group_mandates
  for each row execute function public.set_updated_at();

-- ============================================================================
-- §5. Rules (primitive 4) — dual mode: text + engine
-- ============================================================================

create table public.rule_shapes_catalog (
  shape_key      text primary key,
  category       text not null check (category in ('trigger','condition','consequence')),
  display_name   text not null,
  description    text,
  schema         jsonb not null default '{}'::jsonb,  -- jsonschema for params
  resource_types text[] not null default '{}'::text[],
  metadata       jsonb not null default '{}'::jsonb
);
comment on table public.rule_shapes_catalog is
  'Primitive 4 — reusable trigger/condition/consequence shapes the rule engine can reference.';

create table public.group_rules (
  id                  uuid primary key default gen_random_uuid(),
  group_id            uuid not null references public.groups(id) on delete cascade,
  slug                text,
  title               text not null,
  rule_type           text not null default 'norm'
                      check (rule_type in ('norm','requirement','prohibition','process','principle')),
  status              text not null default 'draft'
                      check (status in ('draft','active','deprecated','archived')),
  severity            int not null default 1 check (severity between 0 and 5),
  scope_resource_type text,                                 -- optional restriction
  scope_resource_id   uuid,                                 -- optional restriction
  current_version_id  uuid,                                 -- FK to rule_versions, set on publish
  created_by          uuid references public.profiles(id) on delete set null,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  unique (group_id, slug)
);
comment on table public.group_rules is
  'Primitive 4 (Rules) — stable rule identity. Current text/engine body lives in group_rule_versions.';

create index group_rules_group_idx on public.group_rules(group_id);
create trigger group_rules_set_updated_at before update on public.group_rules
  for each row execute function public.set_updated_at();

create table public.group_rule_versions (
  id                  uuid primary key default gen_random_uuid(),
  rule_id             uuid not null references public.group_rules(id) on delete cascade,
  version             int not null,
  execution_mode      text not null check (execution_mode in ('text','engine')),
  body                text,                                  -- human-readable for text mode and engine mode alike
  trigger_event_type  text,                                  -- engine only
  condition_tree      jsonb,                                 -- engine only
  consequences        jsonb,                                 -- engine only — array of {type, params, target}
  shape_key           text references public.rule_shapes_catalog(shape_key),
  effective_from      timestamptz not null default now(),
  effective_until     timestamptz,
  published_by        uuid references public.profiles(id) on delete set null,
  created_at          timestamptz not null default now(),
  unique (rule_id, version)
);
comment on table public.group_rule_versions is
  'Primitive 4 — append-only versions of a rule. Only effective_until is mutable (set when superseded).';

alter table public.group_rules
  add constraint group_rules_current_version_fk
  foreign key (current_version_id) references public.group_rule_versions(id) on delete set null;

create index group_rule_versions_rule_idx on public.group_rule_versions(rule_id);
create trigger group_rule_versions_atom_guard
  before update on public.group_rule_versions
  for each row execute function public.atom_no_mutation_guard('effective_until');
create trigger group_rule_versions_no_delete
  before delete on public.group_rule_versions
  for each row execute function public.atom_no_delete_guard();

create table public.group_rule_evaluations (
  id                uuid primary key default gen_random_uuid(),
  rule_version_id   uuid not null references public.group_rule_versions(id) on delete cascade,
  group_id          uuid not null references public.groups(id) on delete cascade,
  source_event_id   uuid,                                   -- FK to group_events, set later
  matched           boolean not null,
  consequences_emitted jsonb not null default '[]'::jsonb,
  idempotency_key   text not null,
  created_at        timestamptz not null default now(),
  unique (idempotency_key)
);
comment on table public.group_rule_evaluations is
  'Primitive 4 — engine audit row. One per evaluation. Idempotent.';

create trigger group_rule_evaluations_atom_guard
  before update on public.group_rule_evaluations
  for each row execute function public.atom_no_mutation_guard();
create trigger group_rule_evaluations_no_delete
  before delete on public.group_rule_evaluations
  for each row execute function public.atom_no_delete_guard();

-- ============================================================================
-- §6. Resources — envelope + subtypes (primitives 8, 18, 21)
-- ============================================================================

create table public.group_resources (
  id                    uuid primary key default gen_random_uuid(),
  group_id              uuid not null references public.groups(id) on delete cascade,
  resource_type         text not null check (resource_type in (
                          'event','fund','slot','space','asset','right',
                          'money','time','points','document','data','access','other'
                        )),
  name                  text not null,
  description           text,
  status                text not null default 'active'
                        check (status in ('draft','active','archived','deleted')),
  visibility            text not null default 'members'
                        check (visibility in ('private','members','public')),
  ownership_kind        text not null default 'group'
                        check (ownership_kind in ('group','individual','shared','custodial','external')),
  owner_membership_id   uuid references public.group_memberships(id) on delete set null,
  ownership_metadata    jsonb not null default '{}'::jsonb,
  unit                  text,                                -- e.g. 'MXN','USD','hours','points'
  metadata              jsonb not null default '{}'::jsonb,
  created_by            uuid references public.profiles(id) on delete set null,
  archived_at           timestamptz,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now()
);
comment on table public.group_resources is
  'Primitive 8 (Resources) + 18 (Ownership). Polymorphic envelope. Subtype-specific data in companion tables.';

create index group_resources_group_idx on public.group_resources(group_id);
create index group_resources_type_idx  on public.group_resources(resource_type);
create trigger group_resources_set_updated_at before update on public.group_resources
  for each row execute function public.set_updated_at();

-- §6.1 Resource subtypes -----------------------------------------------------

create table public.group_resource_events (
  resource_id        uuid primary key references public.group_resources(id) on delete cascade,
  starts_at          timestamptz not null,
  ends_at            timestamptz,
  location           text,
  location_geo       jsonb,
  capacity           int,
  host_membership_id uuid references public.group_memberships(id) on delete set null,
  rsvp_deadline      timestamptz,
  check_in_window    interval,
  cancelled_at       timestamptz,
  closed_at          timestamptz,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);
comment on table public.group_resource_events is
  'Subtype: event — gathering with RSVP/check-in lifecycle.';
create trigger group_resource_events_set_updated_at
  before update on public.group_resource_events
  for each row execute function public.set_updated_at();

create table public.group_resource_funds (
  resource_id         uuid primary key references public.group_resources(id) on delete cascade,
  fund_kind           text not null default 'pool'
                      check (fund_kind in ('pool','protected','shared_pool')),
  currency            text not null default 'MXN',
  is_shared_pool      boolean not null default false,
  is_in_kind          boolean not null default false,
  threshold_target    numeric(18,4),
  locked_at           timestamptz,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);
comment on table public.group_resource_funds is
  'Subtype: fund — pool/protected/shared_pool money envelope.';
create trigger group_resource_funds_set_updated_at
  before update on public.group_resource_funds
  for each row execute function public.set_updated_at();

create table public.group_resource_slots (
  resource_id        uuid primary key references public.group_resources(id) on delete cascade,
  slot_starts_at     timestamptz not null,
  slot_ends_at       timestamptz,
  assigned_membership_id uuid references public.group_memberships(id) on delete set null,
  released_at        timestamptz,
  expired_at         timestamptz,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);
comment on table public.group_resource_slots is
  'Subtype: slot — time-bounded assignable position.';
create trigger group_resource_slots_set_updated_at
  before update on public.group_resource_slots
  for each row execute function public.set_updated_at();

create table public.group_resource_spaces (
  resource_id        uuid primary key references public.group_resources(id) on delete cascade,
  address            text,
  geo                jsonb,
  capacity           int,
  rules              text,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);
comment on table public.group_resource_spaces is
  'Subtype: space — physical or logical location bookable by members.';
create trigger group_resource_spaces_set_updated_at
  before update on public.group_resource_spaces
  for each row execute function public.set_updated_at();

create table public.group_resource_assets (
  resource_id        uuid primary key references public.group_resources(id) on delete cascade,
  asset_kind         text,                                  -- 'tool','vehicle','equipment',...
  serial_number      text,
  current_value      numeric(18,4),
  current_value_unit text,
  condition          text,
  custodian_membership_id uuid references public.group_memberships(id) on delete set null,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);
comment on table public.group_resource_assets is
  'Subtype: asset — tangible item the group owns or uses.';
create trigger group_resource_assets_set_updated_at
  before update on public.group_resource_assets
  for each row execute function public.set_updated_at();

create table public.group_resource_asset_valuations (
  id            uuid primary key default gen_random_uuid(),
  resource_id   uuid not null references public.group_resource_assets(resource_id) on delete cascade,
  value         numeric(18,4) not null,
  unit          text not null,
  basis         text,                                  -- 'market','book','appraised','member_estimate'
  recorded_by   uuid references public.profiles(id) on delete set null,
  recorded_at   timestamptz not null default now()
);
comment on table public.group_resource_asset_valuations is
  'Append-only valuation history for an asset.';
create trigger group_resource_asset_valuations_atom_guard
  before update on public.group_resource_asset_valuations
  for each row execute function public.atom_no_mutation_guard();
create trigger group_resource_asset_valuations_no_delete
  before delete on public.group_resource_asset_valuations
  for each row execute function public.atom_no_delete_guard();

create table public.group_resource_rights (
  resource_id           uuid primary key references public.group_resources(id) on delete cascade,
  right_kind            text not null,                  -- 'use','exclusion','transfer','income','vote',...
  holder_membership_id  uuid references public.group_memberships(id) on delete set null,
  granted_at            timestamptz not null default now(),
  expires_at            timestamptz,
  expired_at            timestamptz,
  revoked_at            timestamptz,
  transferable          boolean not null default false,
  conditions            text,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now()
);
comment on table public.group_resource_rights is
  'Subtype: right — discrete derecho de uso/exclusión/transferencia held by a member.';
create trigger group_resource_rights_set_updated_at
  before update on public.group_resource_rights
  for each row execute function public.set_updated_at();

-- §6.2 Resource ops ----------------------------------------------------------

create table public.group_resource_capabilities (
  id              uuid primary key default gen_random_uuid(),
  resource_id     uuid not null references public.group_resources(id) on delete cascade,
  capability_key  text not null,                       -- 'rsvp','check_in','rotation','reminders','threshold',...
  enabled         boolean not null default true,
  config          jsonb not null default '{}'::jsonb,
  enabled_by      uuid references public.profiles(id) on delete set null,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (resource_id, capability_key)
);
comment on table public.group_resource_capabilities is
  'Per-resource feature toggles (rsvp/check-in/rotation/reminders). Replaces capability registry.';
create trigger group_resource_capabilities_set_updated_at
  before update on public.group_resource_capabilities
  for each row execute function public.set_updated_at();

create table public.group_resource_series (
  id                uuid primary key default gen_random_uuid(),
  group_id          uuid not null references public.groups(id) on delete cascade,
  resource_type     text not null,
  cadence           text not null check (cadence in ('once','daily','weekly','biweekly','monthly','quarterly','yearly','custom')),
  pattern           jsonb not null default '{}'::jsonb,  -- detailed recurrence rule
  starts_on         date,
  ends_on           date,
  ritual_meaning    text,                                -- e.g. "Asamblea anual", "Cena del grupo"
  ritual_marker_kind text check (ritual_marker_kind in (
                      'weekly_meeting','monthly_meeting','annual_assembly','onboarding','farewell','celebration','retrospective','none'
                    )),
  ritual_norm_id    uuid,                                -- FK to group_cultural_norms, set later
  template_payload  jsonb not null default '{}'::jsonb,  -- defaults for each occurrence
  created_by        uuid references public.profiles(id) on delete set null,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);
comment on table public.group_resource_series is
  'Primitive 21 (Ritual). Recurrence container + optional ritual meaning anchored on a cadence.';
create trigger group_resource_series_set_updated_at
  before update on public.group_resource_series
  for each row execute function public.set_updated_at();

-- Series → instance link (one resource may belong to a series)
alter table public.group_resources
  add column series_id uuid references public.group_resource_series(id) on delete set null;

create table public.group_resource_bookings (
  id                  uuid primary key default gen_random_uuid(),
  group_id            uuid not null references public.groups(id) on delete cascade,
  resource_id         uuid not null references public.group_resources(id) on delete cascade,
  booked_by_membership_id uuid not null references public.group_memberships(id) on delete cascade,
  starts_at           timestamptz not null,
  ends_at             timestamptz,
  status              text not null default 'confirmed'
                      check (status in ('requested','confirmed','cancelled','no_show','completed')),
  reason              text,
  metadata            jsonb not null default '{}'::jsonb,
  created_at          timestamptz not null default now()
);
comment on table public.group_resource_bookings is
  'Append-only: a booking claim on a slot/space/asset. Cancellation = new row.';
create index group_resource_bookings_resource_idx on public.group_resource_bookings(resource_id);
create trigger group_resource_bookings_atom_guard
  before update on public.group_resource_bookings
  for each row execute function public.atom_no_mutation_guard('status,reason,metadata');
create trigger group_resource_bookings_no_delete
  before delete on public.group_resource_bookings
  for each row execute function public.atom_no_delete_guard();

create table public.group_rsvp_actions (
  id              uuid primary key default gen_random_uuid(),
  group_id        uuid not null references public.groups(id) on delete cascade,
  resource_id     uuid not null references public.group_resources(id) on delete cascade,
  membership_id   uuid not null references public.group_memberships(id) on delete cascade,
  user_id         uuid references public.profiles(id) on delete set null,
  rsvp_status     text not null check (rsvp_status in ('going','not_going','maybe','pending')),
  source          text not null default 'manual'
                  check (source in ('manual','auto_host','admin_override','imported')),
  note            text,
  acted_at        timestamptz not null default now(),
  created_at      timestamptz not null default now()
);
comment on table public.group_rsvp_actions is
  'Append-only RSVP atom. Latest per (resource, membership) is canonical.';
create index group_rsvp_actions_resource_idx on public.group_rsvp_actions(resource_id);
create trigger group_rsvp_actions_atom_guard
  before update on public.group_rsvp_actions
  for each row execute function public.atom_no_mutation_guard();
create trigger group_rsvp_actions_no_delete
  before delete on public.group_rsvp_actions
  for each row execute function public.atom_no_delete_guard();

create table public.group_check_in_actions (
  id                       uuid primary key default gen_random_uuid(),
  group_id                 uuid not null references public.groups(id) on delete cascade,
  resource_id              uuid not null references public.group_resources(id) on delete cascade,
  membership_id            uuid not null references public.group_memberships(id) on delete cascade,
  check_in_method          text not null check (check_in_method in (
                             'self','geo','host_marked','qr','passive','manual_admin'
                           )),
  location_verified        boolean,
  marked_by_membership_id  uuid references public.group_memberships(id) on delete set null,
  notes                    text,
  acted_at                 timestamptz not null default now(),
  created_at               timestamptz not null default now()
);
comment on table public.group_check_in_actions is
  'Append-only check-in atom. Latest per (resource, membership) is canonical.';
create index group_check_in_actions_resource_idx on public.group_check_in_actions(resource_id);
create trigger group_check_in_actions_atom_guard
  before update on public.group_check_in_actions
  for each row execute function public.atom_no_mutation_guard();
create trigger group_check_in_actions_no_delete
  before delete on public.group_check_in_actions
  for each row execute function public.atom_no_delete_guard();

create table public.group_resource_transactions (
  id                    uuid primary key default gen_random_uuid(),
  seq                   bigint generated always as identity unique,
  group_id              uuid not null references public.groups(id) on delete cascade,
  resource_id           uuid not null references public.group_resources(id) on delete cascade,
  -- transaction_type describes MOVEMENT OF VALUE, not domain events.
  -- "fine_issued" / "sanction_issued" / "obligation_created" live in their
  -- own tables + group_events, NOT here.
  transaction_type      text not null check (transaction_type in (
                          'income','expense','transfer','contribution','refund',
                          'adjustment','allocation','payout','reversal',
                          'settlement_payment','fine_payment','pool_charge','booking_charge'
                        )),
  from_membership_id    uuid references public.group_memberships(id) on delete set null,
  to_membership_id      uuid references public.group_memberships(id) on delete set null,
  paid_by_membership_id uuid references public.group_memberships(id) on delete set null,
  amount                numeric(18,4) not null check (amount > 0),
  unit                  text not null,
  source_resource_id    uuid references public.group_resources(id) on delete set null,
  -- Provenance: where did this value movement originate (sanction, settlement,
  -- booking, obligation, decision)? Keeps transaction_type small.
  source_entity_kind    text check (source_entity_kind in (
                          'sanction','settlement','obligation','booking',
                          'decision','contribution','manual'
                        )),
  source_entity_id      uuid,
  reversed_entry_id     uuid references public.group_resource_transactions(id) on delete set null,
  split_breakdown       jsonb,                                -- for expenses with multiple participants
  split_mode            text check (split_mode in ('even','custom','percentage','share')),
  in_kind               boolean not null default false,
  description           text,
  metadata              jsonb not null default '{}'::jsonb,
  client_id             text,                                 -- idempotency
  recorded_by           uuid references public.profiles(id) on delete set null,
  occurred_at           timestamptz not null default now(),
  created_at            timestamptz not null default now(),
  unique (group_id, client_id)
);
comment on table public.group_resource_transactions is
  'Primitive 19 (Accounting) — append-only money/resource atoms. Rows represent value movements only. ' ||
  'Reversal = new row referencing reversed_entry_id; nothing mutates. seq is a monotonic cursor for FIFO.';
create index group_resource_transactions_group_idx     on public.group_resource_transactions(group_id, seq);
create index group_resource_transactions_resource_idx  on public.group_resource_transactions(resource_id);
create index group_resource_transactions_source_idx    on public.group_resource_transactions(source_entity_kind, source_entity_id);
create trigger group_resource_transactions_atom_guard
  before update on public.group_resource_transactions
  for each row execute function public.atom_no_mutation_guard();
create trigger group_resource_transactions_no_delete
  before delete on public.group_resource_transactions
  for each row execute function public.atom_no_delete_guard();

-- ============================================================================
-- §7. Money 2.0 — obligations, settlements, contributions
-- ============================================================================

create table public.group_obligations (
  id                       uuid primary key default gen_random_uuid(),
  group_id                 uuid not null references public.groups(id) on delete cascade,
  owed_by_membership_id    uuid not null references public.group_memberships(id) on delete cascade,
  owed_to_membership_id    uuid references public.group_memberships(id) on delete set null,
  owed_to_kind             text not null default 'member' check (owed_to_kind in ('member','pool','vendor','group')),
  source_transaction_id    uuid references public.group_resource_transactions(id) on delete set null,
  source_resource_id       uuid references public.group_resources(id) on delete set null,
  obligation_kind          text not null check (obligation_kind in (
                             'expense_share','fine','pool_charge','contribution_due','custom'
                           )),
  amount_original          numeric(18,4) not null check (amount_original > 0),
  amount_outstanding       numeric(18,4) not null check (amount_outstanding >= 0),
  unit                     text not null,
  status                   text not null default 'open'
                           check (status in ('open','partially_settled','settled','voided')),
  constraint group_obligations_outstanding_leq_original
    check (amount_outstanding <= amount_original),
  description              text,
  metadata                 jsonb not null default '{}'::jsonb,
  created_at               timestamptz not null default now(),
  updated_at               timestamptz not null default now()
);
comment on table public.group_obligations is
  'Primitive 19 — peer-to-peer or member-to-pool debt with identity. Amount_outstanding decreases as settlements close it.';
create index group_obligations_owed_by_idx on public.group_obligations(owed_by_membership_id) where status in ('open','partially_settled');
create trigger group_obligations_set_updated_at before update on public.group_obligations
  for each row execute function public.set_updated_at();

create table public.group_settlements (
  id                  uuid primary key default gen_random_uuid(),
  group_id            uuid not null references public.groups(id) on delete cascade,
  paid_by_membership_id uuid not null references public.group_memberships(id) on delete cascade,
  paid_to_membership_id uuid references public.group_memberships(id) on delete set null,
  paid_to_kind        text not null default 'member' check (paid_to_kind in ('member','pool','vendor','group')),
  amount              numeric(18,4) not null check (amount > 0),
  unit                text not null,
  status              text not null default 'initiated'
                      check (status in ('initiated','confirmed','rejected','disputed','cancelled')),
  ledger_entry_id     uuid references public.group_resource_transactions(id) on delete set null,
  client_id           text,
  notes               text,
  metadata            jsonb not null default '{}'::jsonb,
  recorded_by         uuid references public.profiles(id) on delete set null,
  confirmed_at        timestamptz,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  unique (group_id, client_id)
);
comment on table public.group_settlements is
  'Money 2.0 — canonical settlement entity. Closes obligations FIFO via settlement_obligations.';
create trigger group_settlements_set_updated_at before update on public.group_settlements
  for each row execute function public.set_updated_at();

create table public.group_settlement_obligations (
  id              uuid primary key default gen_random_uuid(),
  settlement_id   uuid not null references public.group_settlements(id) on delete cascade,
  obligation_id   uuid not null references public.group_obligations(id) on delete cascade,
  amount_closed   numeric(18,4) not null check (amount_closed > 0),
  created_at      timestamptz not null default now()
);
comment on table public.group_settlement_obligations is
  'Bridge: which obligations did this settlement close and by how much. Append-only.';
create index group_settlement_obligations_settlement_idx on public.group_settlement_obligations(settlement_id);
create index group_settlement_obligations_obligation_idx on public.group_settlement_obligations(obligation_id);
create trigger group_settlement_obligations_atom_guard
  before update on public.group_settlement_obligations
  for each row execute function public.atom_no_mutation_guard();
create trigger group_settlement_obligations_no_delete
  before delete on public.group_settlement_obligations
  for each row execute function public.atom_no_delete_guard();

create table public.group_contributions (
  id                 uuid primary key default gen_random_uuid(),
  group_id           uuid not null references public.groups(id) on delete cascade,
  membership_id      uuid not null references public.group_memberships(id) on delete cascade,
  contribution_type  text not null check (contribution_type in (
                       'money','labor','time','idea','care','moderation','content','contact','asset','hosting','docs','trust','other'
                     )),
  amount             numeric(18,4),
  unit               text,
  title              text,
  description        text,
  source_resource_id uuid references public.group_resources(id) on delete set null,
  source_transaction_id uuid references public.group_resource_transactions(id) on delete set null,
  status             text not null default 'claimed'
                     check (status in ('claimed','verified','rejected','rewarded')),
  verified_by        uuid references public.profiles(id) on delete set null,
  metadata           jsonb not null default '{}'::jsonb,
  occurred_at        timestamptz not null default now(),
  created_at         timestamptz not null default now()
);
comment on table public.group_contributions is
  'Primitive 9 (Contributions). Captures non-monetary aportes (cuidado/moderación/docs) as first-class.';
create index group_contributions_group_idx      on public.group_contributions(group_id);
create index group_contributions_membership_idx on public.group_contributions(membership_id);

-- ============================================================================
-- §8. Decisions (primitives 16, 22)
-- ============================================================================

create table public.group_decisions (
  id              uuid primary key default gen_random_uuid(),
  group_id        uuid not null references public.groups(id) on delete cascade,
  title           text not null,
  body            text,
  decision_type   text not null default 'proposal'
                  check (decision_type in (
                    'proposal','poll','election','budget','rule_change','membership',
                    'sanction_appeal','mandate_grant','mandate_revoke','dissolution','other'
                  )),
  method          text not null default 'majority'
                  check (method in (
                    'admin','majority','supermajority','consensus','consent',
                    'ranked_choice','weighted','veto'
                  )),
  legitimacy_source text not null default 'majority'
                  check (legitimacy_source in (
                    'founder','election','majority','supermajority','committee','unanimity',
                    'expert','external_contract','tradition','emergency'
                  )),
  status          text not null default 'draft'
                  check (status in ('draft','open','closed','passed','rejected','cancelled')),
  threshold_pct   numeric(5,2),
  quorum_pct      numeric(5,2),
  committee_only  boolean not null default false,
  reference_kind  text,                                 -- 'rule','sanction','mandate','member','dispute',...
  reference_id    uuid,
  opens_at        timestamptz,
  closes_at       timestamptz,
  decided_at      timestamptz,
  result          jsonb not null default '{}'::jsonb,
  metadata        jsonb not null default '{}'::jsonb,
  created_by      uuid references public.profiles(id) on delete set null,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
comment on table public.group_decisions is
  'Primitive 16 (Decisions) + 22 (Legitimacy) — every decision records what method made it legitimate.';
create index group_decisions_group_idx on public.group_decisions(group_id);
create trigger group_decisions_set_updated_at before update on public.group_decisions
  for each row execute function public.set_updated_at();

alter table public.group_mandates
  add constraint group_mandates_source_decision_fk
  foreign key (source_decision_id) references public.group_decisions(id) on delete set null;

create table public.group_decision_options (
  id           uuid primary key default gen_random_uuid(),
  decision_id  uuid not null references public.group_decisions(id) on delete cascade,
  label        text not null,
  body         text,
  sort_order   int not null default 0,
  created_at   timestamptz not null default now()
);
comment on table public.group_decision_options is
  'Optional discrete options for a decision (polls, ranked-choice, elections).';

create table public.group_votes (
  id                  uuid primary key default gen_random_uuid(),
  seq                 bigint generated always as identity unique,
  group_id            uuid not null references public.groups(id) on delete cascade,
  decision_id         uuid not null references public.group_decisions(id) on delete cascade,
  voter_membership_id uuid not null references public.group_memberships(id) on delete cascade,
  option_id           uuid references public.group_decision_options(id) on delete set null,
  vote_value          text check (vote_value in ('yes','no','abstain','block')),
  weight              numeric(18,4) not null default 1,
  reason              text,
  cast_at             timestamptz not null default now(),
  created_at          timestamptz not null default now()
);
comment on table public.group_votes is
  'Primitive 16 — strict append-only ballots. Members may cast multiple times while the decision is open; ' ||
  'the current vote per (decision, voter) is the row with the largest seq. ' ||
  'No is_current column; no UPDATE; no DELETE. Counting must use DISTINCT ON.';
create index group_votes_decision_idx
  on public.group_votes(decision_id, voter_membership_id, seq desc);
create trigger group_votes_atom_guard
  before update on public.group_votes
  for each row execute function public.atom_no_mutation_guard();
create trigger group_votes_no_delete
  before delete on public.group_votes
  for each row execute function public.atom_no_delete_guard();

-- ============================================================================
-- §9. Sanctions (primitive 11)
-- ============================================================================

create table public.group_sanctions (
  id                       uuid primary key default gen_random_uuid(),
  group_id                 uuid not null references public.groups(id) on delete cascade,
  target_membership_id     uuid not null references public.group_memberships(id) on delete cascade,
  issued_by_membership_id  uuid references public.group_memberships(id) on delete set null,
  rule_version_id          uuid references public.group_rule_versions(id) on delete set null,
  source_event_id          uuid,                                   -- FK to group_events, set later
  sanction_kind            text not null check (sanction_kind in (
                             'warning','monetary','suspension','loss_of_role',
                             'expulsion','repair_task','reputation_note','other'
                           )),
  status                   text not null default 'proposed'
                           check (status in ('proposed','active','disputed','reversed','completed','cancelled')),
  amount                   numeric(18,4),
  unit                     text,
  reason                   text not null,
  starts_at                timestamptz default now(),
  ends_at                  timestamptz,
  resolved_at              timestamptz,
  dispute_id               uuid,                                   -- FK to group_disputes, set later
  obligation_id            uuid references public.group_obligations(id) on delete set null,
  metadata                 jsonb not null default '{}'::jsonb,
  client_id                text,
  created_at               timestamptz not null default now(),
  updated_at               timestamptz not null default now(),
  unique (group_id, client_id)
);
comment on table public.group_sanctions is
  'Primitive 11 (Sanctions). kind ranges over monetary/warning/suspension/repair_task etc. Replaces fines.';
create index group_sanctions_group_idx  on public.group_sanctions(group_id);
create index group_sanctions_target_idx on public.group_sanctions(target_membership_id);
create trigger group_sanctions_set_updated_at before update on public.group_sanctions
  for each row execute function public.set_updated_at();

-- ============================================================================
-- §10. Disputes (primitive 14)
-- ============================================================================

create table public.group_disputes (
  id                          uuid primary key default gen_random_uuid(),
  group_id                    uuid not null references public.groups(id) on delete cascade,
  opened_by_membership_id     uuid references public.group_memberships(id) on delete set null,
  respondent_membership_id    uuid references public.group_memberships(id) on delete set null,
  subject_kind                text check (subject_kind in ('sanction','rule','resource','member','other')),
  subject_id                  uuid,
  title                       text not null,
  description                 text,
  status                      text not null default 'open'
                              check (status in ('open','in_review','mediation','resolved','dismissed','escalated','closed')),
  mediator_membership_id      uuid references public.group_memberships(id) on delete set null,
  resolution_method           text check (resolution_method in (
                                'conversation','mediation','vote','admin_decision','arbitration','separation','other'
                              )),
  resolution                  text,
  escalated_decision_id       uuid references public.group_decisions(id) on delete set null,
  opened_at                   timestamptz not null default now(),
  resolved_at                 timestamptz,
  metadata                    jsonb not null default '{}'::jsonb,
  updated_at                  timestamptz not null default now()
);
comment on table public.group_disputes is
  'Primitive 14 (Conflict resolution). State machine: open → mediation → resolved | escalated_to_vote.';
create index group_disputes_group_idx on public.group_disputes(group_id);
create trigger group_disputes_set_updated_at before update on public.group_disputes
  for each row execute function public.set_updated_at();

alter table public.group_sanctions
  add constraint group_sanctions_dispute_fk
  foreign key (dispute_id) references public.group_disputes(id) on delete set null;

create table public.group_dispute_events (
  id                    uuid primary key default gen_random_uuid(),
  dispute_id            uuid not null references public.group_disputes(id) on delete cascade,
  actor_membership_id   uuid references public.group_memberships(id) on delete set null,
  event_type            text not null check (event_type in (
                          'comment','status_change','evidence_added','mediation_note','resolution','escalation','other'
                        )),
  body                  text,
  metadata              jsonb not null default '{}'::jsonb,
  created_at            timestamptz not null default now()
);
comment on table public.group_dispute_events is
  'Append-only timeline of a dispute (comments, evidence, mediation notes, resolution).';
create trigger group_dispute_events_atom_guard
  before update on public.group_dispute_events
  for each row execute function public.atom_no_mutation_guard();
create trigger group_dispute_events_no_delete
  before delete on public.group_dispute_events
  for each row execute function public.atom_no_delete_guard();

-- ============================================================================
-- §11. Reputation — fact-only, NO score (primitive 12)
-- ============================================================================

create table public.group_reputation_events (
  id                       uuid primary key default gen_random_uuid(),
  group_id                 uuid not null references public.groups(id) on delete cascade,
  subject_membership_id    uuid not null references public.group_memberships(id) on delete cascade,
  actor_membership_id      uuid references public.group_memberships(id) on delete set null,
  reputation_type          text not null check (reputation_type in (
                             'trust_event','contribution_recognized','commitment_kept','commitment_broken',
                             'conflict_resolved','care_shown','leadership_shown','rule_violation',
                             'reliability_signal','skill_signal','other'
                           )),
  reason                   text,
  evidence_entity_kind     text,                              -- 'sanction','dispute','contribution','settlement','obligation','rule_evaluation'
  evidence_entity_id       uuid,
  visibility               text not null default 'members'
                           check (visibility in ('private','members','public')),
  status                   text not null default 'active'
                           check (status in ('active','retracted','archived')),
  metadata                 jsonb not null default '{}'::jsonb,
  occurred_at              timestamptz not null default now(),
  created_at               timestamptz not null default now()
);
comment on table public.group_reputation_events is
  'Primitive 12 (Trust). Append-only facts. NO score column — UI never ranks. Aggregation is qualitative.';
create index group_reputation_events_subject_idx on public.group_reputation_events(subject_membership_id);
create trigger group_reputation_events_atom_guard
  before update on public.group_reputation_events
  for each row execute function public.atom_no_mutation_guard('status,visibility');
create trigger group_reputation_events_no_delete
  before delete on public.group_reputation_events
  for each row execute function public.atom_no_delete_guard();

-- ============================================================================
-- §12. Cultural norms — opt-in (primitive 20)
-- ============================================================================

create table public.group_cultural_norms (
  id            uuid primary key default gen_random_uuid(),
  group_id      uuid not null references public.groups(id) on delete cascade,
  norm_type     text not null check (norm_type in (
                  'value','taboo','symbol','story','language','ritual','custom','aesthetic','principle'
                )),
  title         text not null,
  body          text,
  visibility    text not null default 'members'
                check (visibility in ('private','members','public')),
  status        text not null default 'proposed'
                check (status in ('proposed','endorsed','retired')),
  endorsed_count int not null default 0,
  proposed_by   uuid references public.profiles(id) on delete set null,
  metadata      jsonb not null default '{}'::jsonb,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
comment on table public.group_cultural_norms is
  'Primitive 20 (Culture). Opt-in. Activated via groups.settings.cultural_norms_enabled. Declarativo, no rule engine.';
create index group_cultural_norms_group_idx on public.group_cultural_norms(group_id);
create trigger group_cultural_norms_set_updated_at before update on public.group_cultural_norms
  for each row execute function public.set_updated_at();

alter table public.group_resource_series
  add constraint group_resource_series_ritual_norm_fk
  foreign key (ritual_norm_id) references public.group_cultural_norms(id) on delete set null;

-- ============================================================================
-- §13. Dissolutions (primitive 25)
-- ============================================================================

create table public.group_dissolutions (
  id                  uuid primary key default gen_random_uuid(),
  group_id            uuid not null references public.groups(id) on delete cascade,
  initiated_by        uuid references public.profiles(id) on delete set null,
  source_decision_id  uuid references public.group_decisions(id) on delete set null,
  status              text not null default 'proposed'
                      check (status in ('proposed','approved','liquidating','executed','cancelled')),
  reason              text,
  plan                jsonb not null default '{}'::jsonb,
  asset_disposition   jsonb not null default '{}'::jsonb,
  obligations_plan    jsonb not null default '{}'::jsonb,
  proposed_at         timestamptz not null default now(),
  approved_at         timestamptz,
  executed_at         timestamptz,
  metadata            jsonb not null default '{}'::jsonb,
  updated_at          timestamptz not null default now()
);
comment on table public.group_dissolutions is
  'Primitive 25 (Dissolution). proposed → approved → liquidating → executed. groups.status mirrors high-level state.';
create index group_dissolutions_group_idx on public.group_dissolutions(group_id);
create trigger group_dissolutions_set_updated_at before update on public.group_dissolutions
  for each row execute function public.set_updated_at();

-- ============================================================================
-- §14. Memory — universal audit log + invites (primitives 7, 13, 15)
-- ============================================================================

create table public.group_events (
  id            bigint generated always as identity primary key,
  uuid_id       uuid not null default gen_random_uuid() unique,
  group_id      uuid not null references public.groups(id) on delete cascade,
  actor_user_id uuid references public.profiles(id) on delete set null,
  event_type    text not null,
  entity_kind   text,
  entity_id     uuid,
  summary       text,
  payload       jsonb not null default '{}'::jsonb,
  occurred_at   timestamptz not null default now(),
  created_at    timestamptz not null default now()
);
comment on table public.group_events is
  'Primitive 13 (Memory). Universal append-only audit log. ' ||
  'id is a monotonic database cursor for order/pagination/replay, NOT a gapless sequence and NOT a strict commit-time clock. ' ||
  'uuid_id is the stable public identifier for cross-entity references. ' ||
  'Use occurred_at/created_at for human chronology.';
create index group_events_group_id_idx          on public.group_events(group_id, id);
create index group_events_group_created_at_idx  on public.group_events(group_id, created_at desc, id desc);
create index group_events_entity_idx            on public.group_events(entity_kind, entity_id);
create trigger group_events_atom_guard
  before update on public.group_events
  for each row execute function public.atom_no_mutation_guard();
create trigger group_events_no_delete
  before delete on public.group_events
  for each row execute function public.atom_no_delete_guard();

-- Now we can wire the cross-section FKs that pointed forward to group_events.
alter table public.group_rule_evaluations
  add constraint group_rule_evaluations_source_event_fk
  foreign key (source_event_id) references public.group_events(uuid_id) on delete set null;
alter table public.group_sanctions
  add constraint group_sanctions_source_event_fk
  foreign key (source_event_id) references public.group_events(uuid_id) on delete set null;

create table public.group_invites (
  id                 uuid primary key default gen_random_uuid(),
  group_id           uuid not null references public.groups(id) on delete cascade,
  email              text,
  phone              text,
  invited_user_id    uuid references public.profiles(id) on delete set null,
  placeholder_membership_id uuid references public.group_memberships(id) on delete set null,
  invited_by         uuid references public.profiles(id) on delete set null,
  status             text not null default 'pending'
                     check (status in ('pending','sent','accepted','declined','expired','revoked')),
  token_hash         text,
  code               text,                                 -- short shareable code
  expires_at         timestamptz,
  accepted_at        timestamptz,
  metadata           jsonb not null default '{}'::jsonb,
  created_at         timestamptz not null default now()
);
comment on table public.group_invites is
  'Primitive 15 (Entry) — pending invitation. Tokens stored as hash; codes for shareable links.';
create index group_invites_group_idx on public.group_invites(group_id);
create index group_invites_email_idx on public.group_invites(email);

-- ============================================================================
-- §15. Notifications
-- ============================================================================

create table public.notification_tokens (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references public.profiles(id) on delete cascade,
  platform      text not null check (platform in ('apns','fcm','web')),
  token         text not null,
  device_id     text,
  enabled       boolean not null default true,
  last_seen_at  timestamptz default now(),
  created_at    timestamptz not null default now(),
  unique (user_id, token)
);
create index notification_tokens_user_idx on public.notification_tokens(user_id);

create table public.notification_preferences (
  user_id     uuid not null references public.profiles(id) on delete cascade,
  group_id    uuid not null references public.groups(id) on delete cascade,
  category    text not null,             -- 'rsvp','sanction','vote','dispute','reminder',…
  channel     text not null check (channel in ('push','email','sms','in_app')),
  enabled     boolean not null default true,
  updated_at  timestamptz not null default now(),
  primary key (user_id, group_id, category, channel)
);
create trigger notification_preferences_set_updated_at before update on public.notification_preferences
  for each row execute function public.set_updated_at();

create table public.notifications_outbox (
  id              uuid primary key default gen_random_uuid(),
  group_id        uuid references public.groups(id) on delete cascade,
  recipient_user_id uuid not null references public.profiles(id) on delete cascade,
  category        text not null,
  payload         jsonb not null default '{}'::jsonb,
  dispatch_status text not null default 'pending'
                  check (dispatch_status in ('pending','dispatched','failed','suppressed')),
  attempts        int not null default 0,
  last_error      text,
  dispatched_at   timestamptz,
  created_at      timestamptz not null default now()
);
create index notifications_outbox_pending_idx
  on public.notifications_outbox(dispatch_status)
  where dispatch_status = 'pending';

-- ============================================================================
-- §15.5 Same-group enforcement (cross-tenant invariant)
-- ============================================================================
-- INVARIANT: every cross-entity relationship must live inside one group.
-- Two enforcement mechanisms in use:
--   (a) Composite foreign keys (id, group_id) → parent's UNIQUE(id, group_id).
--       Used when the child row already carries group_id.
--   (b) Constraint triggers that look up the parents and call
--       assert_same_group(...). Used when the child links two siblings
--       without carrying group_id itself.

-- Parent uniqueness so composite FKs can target them.
alter table public.group_memberships      add constraint group_memberships_id_group_uk      unique (id, group_id);
alter table public.group_resources        add constraint group_resources_id_group_uk        unique (id, group_id);
alter table public.group_roles            add constraint group_roles_id_group_uk            unique (id, group_id);
alter table public.group_decisions        add constraint group_decisions_id_group_uk        unique (id, group_id);
alter table public.group_obligations      add constraint group_obligations_id_group_uk      unique (id, group_id);
alter table public.group_settlements      add constraint group_settlements_id_group_uk      unique (id, group_id);
alter table public.group_rules            add constraint group_rules_id_group_uk            unique (id, group_id);
alter table public.group_sanctions        add constraint group_sanctions_id_group_uk        unique (id, group_id);
alter table public.group_disputes         add constraint group_disputes_id_group_uk         unique (id, group_id);
alter table public.group_resource_series  add constraint group_resource_series_id_group_uk  unique (id, group_id);

-- Composite FK pattern — child tables that already carry group_id.
-- (FKs that target id alone are kept for ON DELETE behavior; composite FKs
--  are additive and enforce tenancy.)

alter table public.group_votes
  add constraint group_votes_decision_same_group_fk
  foreign key (decision_id, group_id)
  references public.group_decisions(id, group_id),
  add constraint group_votes_voter_same_group_fk
  foreign key (voter_membership_id, group_id)
  references public.group_memberships(id, group_id);

alter table public.group_resource_transactions
  add constraint group_resource_transactions_resource_same_group_fk
  foreign key (resource_id, group_id)
  references public.group_resources(id, group_id);

alter table public.group_resource_bookings
  add constraint group_resource_bookings_resource_same_group_fk
  foreign key (resource_id, group_id)
  references public.group_resources(id, group_id),
  add constraint group_resource_bookings_member_same_group_fk
  foreign key (booked_by_membership_id, group_id)
  references public.group_memberships(id, group_id);

alter table public.group_rsvp_actions
  add constraint group_rsvp_actions_resource_same_group_fk
  foreign key (resource_id, group_id)
  references public.group_resources(id, group_id),
  add constraint group_rsvp_actions_member_same_group_fk
  foreign key (membership_id, group_id)
  references public.group_memberships(id, group_id);

alter table public.group_check_in_actions
  add constraint group_check_in_actions_resource_same_group_fk
  foreign key (resource_id, group_id)
  references public.group_resources(id, group_id),
  add constraint group_check_in_actions_member_same_group_fk
  foreign key (membership_id, group_id)
  references public.group_memberships(id, group_id);

alter table public.group_obligations
  add constraint group_obligations_owed_by_same_group_fk
  foreign key (owed_by_membership_id, group_id)
  references public.group_memberships(id, group_id);

alter table public.group_settlements
  add constraint group_settlements_paid_by_same_group_fk
  foreign key (paid_by_membership_id, group_id)
  references public.group_memberships(id, group_id);

alter table public.group_sanctions
  add constraint group_sanctions_target_same_group_fk
  foreign key (target_membership_id, group_id)
  references public.group_memberships(id, group_id);

alter table public.group_contributions
  add constraint group_contributions_member_same_group_fk
  foreign key (membership_id, group_id)
  references public.group_memberships(id, group_id);

alter table public.group_membership_events
  add constraint group_membership_events_member_same_group_fk
  foreign key (membership_id, group_id)
  references public.group_memberships(id, group_id);

alter table public.group_mandates
  add constraint group_mandates_representative_same_group_fk
  foreign key (representative_membership_id, group_id)
  references public.group_memberships(id, group_id);

alter table public.group_reputation_events
  add constraint group_reputation_events_subject_same_group_fk
  foreign key (subject_membership_id, group_id)
  references public.group_memberships(id, group_id);

alter table public.group_resources
  add constraint group_resources_series_same_group_fk
  foreign key (series_id, group_id)
  references public.group_resource_series(id, group_id);

-- Trigger pattern — child links two siblings without carrying group_id.

create or replace function public.assert_member_role_same_group()
returns trigger
language plpgsql
as $$
declare v_membership_group uuid; v_role_group uuid;
begin
  select group_id into v_membership_group from public.group_memberships where id = NEW.membership_id;
  select group_id into v_role_group       from public.group_roles       where id = NEW.role_id;
  perform public.assert_same_group(v_membership_group, v_role_group);
  return NEW;
end;
$$;
create trigger group_member_roles_same_group
  before insert or update on public.group_member_roles
  for each row execute function public.assert_member_role_same_group();

create or replace function public.assert_settlement_obligation_same_group()
returns trigger
language plpgsql
as $$
declare v_s uuid; v_o uuid;
begin
  select group_id into v_s from public.group_settlements where id = NEW.settlement_id;
  select group_id into v_o from public.group_obligations where id = NEW.obligation_id;
  perform public.assert_same_group(v_s, v_o);
  return NEW;
end;
$$;
create trigger group_settlement_obligations_same_group
  before insert on public.group_settlement_obligations
  for each row execute function public.assert_settlement_obligation_same_group();

create or replace function public.assert_decision_option_same_group_via_decision()
returns trigger
language plpgsql
as $$
declare v_d uuid;
begin
  select group_id into v_d from public.group_decisions where id = NEW.decision_id;
  if v_d is null then
    raise exception 'decision % not found', NEW.decision_id;
  end if;
  return NEW;
end;
$$;
-- (group_decision_options has no group_id, but its parent decision lives in
--  exactly one group; the check is implicit via the FK.)

create or replace function public.assert_dispute_event_same_group_via_dispute()
returns trigger
language plpgsql
as $$
declare v_d uuid;
begin
  select group_id into v_d from public.group_disputes where id = NEW.dispute_id;
  if v_d is null then
    raise exception 'dispute % not found', NEW.dispute_id;
  end if;
  return NEW;
end;
$$;
-- Same reasoning as above; trigger included for symmetry/future use.

-- ============================================================================
-- §15.6 Resource subtype type assertion
-- ============================================================================
-- Each subtype table extends group_resources for exactly one resource_type.
-- The trigger guarantees the parent row's resource_type matches the subtype.

create trigger group_resource_events_type_check
  before insert or update on public.group_resource_events
  for each row execute function public.assert_resource_type('event');

create trigger group_resource_funds_type_check
  before insert or update on public.group_resource_funds
  for each row execute function public.assert_resource_type('fund');

create trigger group_resource_slots_type_check
  before insert or update on public.group_resource_slots
  for each row execute function public.assert_resource_type('slot');

create trigger group_resource_spaces_type_check
  before insert or update on public.group_resource_spaces
  for each row execute function public.assert_resource_type('space');

create trigger group_resource_assets_type_check
  before insert or update on public.group_resource_assets
  for each row execute function public.assert_resource_type('asset');

create trigger group_resource_rights_type_check
  before insert or update on public.group_resource_rights
  for each row execute function public.assert_resource_type('right');

-- ============================================================================
-- §16. RLS — enable + helper functions + sample policies
-- ============================================================================

-- All public tables get RLS on. Policies follow two patterns:
--   * READ: is_group_member(group_id)
--   * WRITE: has_group_permission(group_id, '<key>')
-- Append-only tables also enforce writer = caller via WITH CHECK.

create or replace function public.is_group_member(p_group_id uuid)
returns boolean
language sql stable security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.group_memberships gm
    where gm.group_id = p_group_id
      and gm.user_id  = (select auth.uid())
      and gm.status   = 'active'
  );
$$;

create or replace function public.has_group_permission(
  p_group_id uuid,
  p_permission text
)
returns boolean
language sql stable security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.group_memberships gm
    join public.group_member_roles gmr on gmr.membership_id = gm.id
    join public.group_role_permissions grp on grp.role_id   = gmr.role_id
    where gm.group_id      = p_group_id
      and gm.user_id       = (select auth.uid())
      and gm.status        = 'active'
      and grp.permission_key = p_permission
  );
$$;

-- Enable RLS on every public table (loop done explicitly for clarity)
alter table public.profiles                       enable row level security;
alter table public.groups                         enable row level security;
alter table public.group_purposes                 enable row level security;
alter table public.group_memberships              enable row level security;
alter table public.group_membership_events        enable row level security;
alter table public.permissions                    enable row level security;
alter table public.group_roles                    enable row level security;
alter table public.group_role_permissions         enable row level security;
alter table public.group_member_roles             enable row level security;
alter table public.group_mandates                 enable row level security;
alter table public.rule_shapes_catalog            enable row level security;
alter table public.group_rules                    enable row level security;
alter table public.group_rule_versions            enable row level security;
alter table public.group_rule_evaluations         enable row level security;
alter table public.group_resources                enable row level security;
alter table public.group_resource_events          enable row level security;
alter table public.group_resource_funds           enable row level security;
alter table public.group_resource_slots           enable row level security;
alter table public.group_resource_spaces          enable row level security;
alter table public.group_resource_assets          enable row level security;
alter table public.group_resource_asset_valuations enable row level security;
alter table public.group_resource_rights          enable row level security;
alter table public.group_resource_capabilities    enable row level security;
alter table public.group_resource_series          enable row level security;
alter table public.group_resource_bookings        enable row level security;
alter table public.group_rsvp_actions             enable row level security;
alter table public.group_check_in_actions         enable row level security;
alter table public.group_resource_transactions    enable row level security;
alter table public.group_obligations              enable row level security;
alter table public.group_settlements              enable row level security;
alter table public.group_settlement_obligations   enable row level security;
alter table public.group_contributions            enable row level security;
alter table public.group_decisions                enable row level security;
alter table public.group_decision_options         enable row level security;
alter table public.group_votes                    enable row level security;
alter table public.group_sanctions                enable row level security;
alter table public.group_disputes                 enable row level security;
alter table public.group_dispute_events           enable row level security;
alter table public.group_reputation_events        enable row level security;
alter table public.group_cultural_norms           enable row level security;
alter table public.group_dissolutions             enable row level security;
alter table public.group_events                   enable row level security;
alter table public.group_invites                  enable row level security;
alter table public.notification_tokens            enable row level security;
alter table public.notification_preferences       enable row level security;
alter table public.notifications_outbox           enable row level security;

-- Canonical policies (the rest are deliberately omitted in this draft;
-- they all follow the same READ-is_group_member / WRITE-has_group_permission pattern
-- and will be filled in before A4 apply).

create policy "profiles_select_authenticated"
  on public.profiles for select to authenticated using (true);
create policy "profiles_update_self"
  on public.profiles for update to authenticated
  using (id = (select auth.uid())) with check (id = (select auth.uid()));

create policy "groups_select_visible_or_member"
  on public.groups for select to authenticated
  using (visibility = 'public' or public.is_group_member(id));
create policy "groups_insert_authenticated"
  on public.groups for insert to authenticated
  with check (created_by = (select auth.uid()));
create policy "groups_update_with_permission"
  on public.groups for update to authenticated
  using (public.has_group_permission(id, 'group.update'))
  with check (public.has_group_permission(id, 'group.update'));

create policy "memberships_select_members"
  on public.group_memberships for select to authenticated
  using (public.is_group_member(group_id));

create policy "rules_select_members"
  on public.group_rules for select to authenticated
  using (public.is_group_member(group_id));

create policy "resources_select_members"
  on public.group_resources for select to authenticated
  using (public.is_group_member(group_id));

create policy "events_select_members"
  on public.group_events for select to authenticated
  using (public.is_group_member(group_id));

-- Read permissions catalog is public.
create policy "permissions_select_anyone"
  on public.permissions for select to authenticated using (true);

-- TODO before A4: write the full policy set per table (insert/update/delete).
-- Spec lives in Plans/Active/CanonicalSchema_RLS.md (next deliverable).

-- ============================================================================
-- §17. Seeds — permissions catalog
-- ============================================================================

insert into public.permissions (key, description, category) values
  ('group.read',           'Ver el grupo',                 'group'),
  ('group.update',         'Editar información del grupo', 'group'),
  ('group.archive',        'Archivar el grupo',            'group'),
  ('group.dissolve',       'Proponer/aprobar disolución',  'group'),
  ('purpose.set',          'Editar el propósito del grupo','group'),
  ('members.read',         'Ver miembros',                 'members'),
  ('members.invite',       'Invitar miembros',             'members'),
  ('members.update',       'Editar membresías',            'members'),
  ('members.remove',       'Remover miembros',             'members'),
  ('members.suspend',      'Suspender miembros',           'members'),
  ('roles.manage',         'Gestionar roles y permisos',   'roles'),
  ('mandates.grant',       'Otorgar mandatos',             'roles'),
  ('mandates.revoke',      'Revocar mandatos',             'roles'),
  ('rules.read',           'Ver reglas',                   'rules'),
  ('rules.create',         'Crear reglas',                 'rules'),
  ('rules.update',         'Editar reglas',                'rules'),
  ('rules.publish',        'Publicar versión de regla',    'rules'),
  ('rules.archive',        'Archivar reglas',              'rules'),
  ('resources.read',       'Ver recursos',                 'resources'),
  ('resources.create',     'Crear recursos',               'resources'),
  ('resources.update',     'Editar recursos',              'resources'),
  ('resources.transfer',   'Transferir propiedad',         'resources'),
  ('resources.archive',    'Archivar recursos',            'resources'),
  ('bookings.create',      'Reservar recursos',            'resources'),
  ('bookings.cancel',      'Cancelar reservas',            'resources'),
  ('rsvp.submit',          'Responder RSVP',               'resources'),
  ('check_in.submit',      'Hacer check-in',               'resources'),
  ('expense.record',       'Registrar gasto',              'money'),
  ('contribution.record',  'Registrar contribución',       'money'),
  ('settlement.record',    'Registrar pago/settlement',    'money'),
  ('payout.record',        'Registrar payout',             'money'),
  ('pool_charge.record',   'Crear cuota / pool charge',    'money'),
  ('decisions.create',     'Abrir decisiones',             'decisions'),
  ('decisions.vote',       'Votar',                        'decisions'),
  ('decisions.resolve',    'Cerrar / finalizar decisiones','decisions'),
  ('sanctions.create',     'Emitir sanciones',             'sanctions'),
  ('sanctions.update',     'Modificar sanciones',          'sanctions'),
  ('sanctions.dispute',    'Disputar sanciones',           'sanctions'),
  ('disputes.open',        'Abrir disputas',               'disputes'),
  ('disputes.mediate',     'Mediar disputas',              'disputes'),
  ('disputes.resolve',     'Resolver disputas',            'disputes'),
  ('reputation.record',    'Registrar evento de reputación','reputation'),
  ('culture.propose',      'Proponer norma cultural',      'culture'),
  ('culture.endorse',      'Endorsar norma cultural',      'culture'),
  ('records.read',         'Ver registros internos',       'audit')
on conflict (key) do nothing;

-- ============================================================================
-- §18. Realtime publication (post-MVP)
-- ============================================================================

-- The following tables publish via supabase_realtime so multi-device clients
-- see updates immediately:
--   group_memberships, group_resources, group_decisions, group_votes,
--   group_sanctions, group_obligations, group_settlements, group_disputes,
--   group_events, notifications_outbox, group_rsvp_actions, group_check_in_actions.
-- The ALTER PUBLICATION statements live in a follow-up migration (or are
-- applied via the Supabase dashboard) so this canonical schema is replication-agnostic.

-- ============================================================================
-- §19. create_group atomic RPC (entry point)
-- ============================================================================

create or replace function public.create_group(
  p_name            text,
  p_slug            text default null,
  p_category        text default null,
  p_purpose_declared text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_group_id           uuid;
  v_membership_id      uuid;
  v_founder_role_id    uuid;
  v_member_role_id     uuid;
begin
  -- 1. group
  insert into public.groups (name, slug, category, created_by, purpose_summary)
  values (p_name, p_slug, p_category, auth.uid(), p_purpose_declared)
  returning id into v_group_id;

  -- 2. founder membership
  insert into public.group_memberships (
    group_id, user_id, status, membership_type, joined_at, joined_via
  ) values (
    v_group_id, auth.uid(), 'active', 'member', now(), 'founder_seed'
  ) returning id into v_membership_id;

  insert into public.group_membership_events (
    group_id, membership_id, actor_user_id, event_type, reason
  ) values (
    v_group_id, v_membership_id, auth.uid(), 'joined', 'founder_seed'
  );

  -- 3. system roles
  insert into public.group_roles (group_id, key, name, description, is_system, is_default)
  values
    (v_group_id, 'founder', 'Fundador',   'Autoridad fundacional',    true, false),
    (v_group_id, 'admin',   'Administrador','Gestión operativa',      true, false),
    (v_group_id, 'member',  'Miembro',    'Pertenencia plena',        true, true)
  on conflict do nothing;

  select id into v_founder_role_id from public.group_roles
    where group_id = v_group_id and key = 'founder';
  select id into v_member_role_id  from public.group_roles
    where group_id = v_group_id and key = 'member';

  -- 4. all permissions to founder
  insert into public.group_role_permissions (role_id, permission_key)
  select v_founder_role_id, key from public.permissions
  on conflict do nothing;

  -- 5. baseline permissions to member
  insert into public.group_role_permissions (role_id, permission_key) values
    (v_member_role_id, 'group.read'),
    (v_member_role_id, 'members.read'),
    (v_member_role_id, 'rules.read'),
    (v_member_role_id, 'resources.read'),
    (v_member_role_id, 'rsvp.submit'),
    (v_member_role_id, 'check_in.submit'),
    (v_member_role_id, 'expense.record'),
    (v_member_role_id, 'contribution.record'),
    (v_member_role_id, 'settlement.record'),
    (v_member_role_id, 'decisions.vote'),
    (v_member_role_id, 'disputes.open'),
    (v_member_role_id, 'records.read')
  on conflict do nothing;

  -- 6. assign founder role to founder
  insert into public.group_member_roles (membership_id, role_id, assigned_by)
  values (v_membership_id, v_founder_role_id, auth.uid());

  -- 7. seed declared purpose if provided
  if p_purpose_declared is not null and length(p_purpose_declared) > 0 then
    insert into public.group_purposes (group_id, kind, body, created_by)
    values (v_group_id, 'declared', p_purpose_declared, auth.uid());
  end if;

  -- 8. memory event
  insert into public.group_events (
    group_id, actor_user_id, event_type, entity_kind, entity_id, summary
  ) values (
    v_group_id, auth.uid(), 'group.created', 'group', v_group_id, 'Grupo creado'
  );

  return v_group_id;
end;
$$;

-- ============================================================================
-- END — 00001_canonical_schema.sql
-- ============================================================================
-- Pendientes antes de aplicar (siguen como deliverables del Plan):
--   1. Plans/Active/CanonicalSchema_RLS.md — el set completo de policies.
--   2. Plans/Active/CanonicalSchema_RPCs.md — catálogo completo de RPCs.
--   3. Plans/Active/CanonicalSchema_Migration.md — script de export/import
--      mapeando data viva al schema canónico.
-- ============================================================================
