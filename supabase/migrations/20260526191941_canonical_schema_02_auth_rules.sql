-- §4. Authority — permissions, roles, mandates
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
  is_system    boolean not null default false,
  created_at   timestamptz not null default now(),
  unique (group_id, key)
);
comment on table public.group_roles is
  'Primitive 5 (Roles). Per-group catalog of named roles.';
create unique index group_roles_one_default_per_group
  on public.group_roles(group_id) where is_default = true;

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
  principal_id                uuid,
  representative_membership_id uuid not null references public.group_memberships(id) on delete restrict,
  mandate_type                text not null check (mandate_type in (
                                'speak','sign','vote','negotiate','spend','represent','delegate','other'
                              )),
  scope                       jsonb not null default '{}'::jsonb,
  status                      text not null default 'active'
                              check (status in ('active','expired','revoked','fulfilled')),
  starts_at                   timestamptz not null default now(),
  ends_at                     timestamptz,
  source_decision_id          uuid,
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

-- §5. Rules
create table public.rule_shapes_catalog (
  shape_key      text primary key,
  category       text not null check (category in ('trigger','condition','consequence')),
  display_name   text not null,
  description    text,
  schema         jsonb not null default '{}'::jsonb,
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
  scope_resource_type text,
  scope_resource_id   uuid,
  current_version_id  uuid,
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
  body                text,
  trigger_event_type  text,
  condition_tree      jsonb,
  consequences        jsonb,
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
  source_event_id   uuid,
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
