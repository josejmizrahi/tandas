-- Mig 00170: Governance baseline — Rule Templates + Versions + Evaluations + Conflicts + Member Overrides.
-- Constitution: capa 8 (Governance) — append-only audit (rule_versions, rule_evaluations) +
-- mutable workflow state (rule_conflicts, member_capability_overrides).
-- Doctrine: Plans/Active/Governance.md §0.5 (Hybrid 2026-05-14) — preserves runtime-declarative
-- `public.rule_shapes` + `LiveRuleShapeRepository` (founder principle 2026-05-10). Adds curated
-- Templates layer above shape pieces. `public.rules` table NOT touched in this migration.
--
-- Tables introduced:
--   1. rule_templates              (curated UX recipes — mirror of TS canonical source)
--   2. rule_versions               (append-only snapshots of compiled rules)
--   3. rule_evaluations            (technical audit — per engine evaluation, append-only)
--   4. rule_conflicts              (publish-time conflict detection state — mutable lifecycle)
--   5. member_capability_overrides (David fuera de rotativa, etc.)
--
-- RPCs (publish_rule_version, list_rule_templates, sync_rule_templates_from_seed) come in mig 00171
-- after schema review.

-- =============================================================================
-- 1. rule_templates — curated UX recipes
-- =============================================================================
-- Templates are pre-composed recipes of shape pieces (from public.rule_shapes).
-- Canonical source = TS code in supabase/functions/_shared/ruleTemplates/.
-- This table is a runtime mirror loaded by iOS via list_rule_templates RPC.
-- Adding/changing a template = TS code change + sync_rule_templates_from_seed run.
-- Per Governance.md §0.5.1.

create table public.rule_templates (
  id                    text primary key,                                              -- slug-like, matches TS key
  display_name_es       text not null,
  description_es        text not null,
  category              text not null check (category in ('attendance','money','allocation','governance','custody','other')),
  template_kind         text not null check (template_kind in ('behavior','governance','allocation','approval','penalty')),
  required_capabilities text[] not null default '{}',
  default_params        jsonb not null default '{}'::jsonb,
  composition           jsonb not null,                                                -- {trigger_shape_id, condition_shape_ids[], consequence_shape_ids[], scope_hint}
  status                text not null default 'active' check (status in ('active','deprecated','draft')),
  sort_order            int  not null default 100,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now()
);

create trigger rule_templates_set_updated_at
  before update on public.rule_templates
  for each row execute function public.set_updated_at();

create index idx_rule_templates_status_sort
  on public.rule_templates (status, sort_order)
  where status = 'active';

comment on table public.rule_templates is
  'Curated UX recipes that pre-compose shape pieces from public.rule_shapes. Canonical source = TS code (supabase/functions/_shared/ruleTemplates/). This table is a mirror loaded by iOS at boot via list_rule_templates RPC. Templates are read-only from client. Per Governance.md §0.5.';
comment on column public.rule_templates.composition is
  'jsonb: {trigger_shape_id: text, condition_shape_ids: text[], consequence_shape_ids: text[], scope_hint: text}. References ids from public.rule_shapes. The publish_rule_version RPC compiles a frozen snapshot from this composition + user params.';
comment on column public.rule_templates.default_params is
  'jsonb: pre-filled parameter values shown in the iOS form. Keyed by RuleShapeField.key. Marked "strict" in template if rule is monetary and should be pre-checked (per memoria feedback_create_flow_defaults).';

alter table public.rule_templates enable row level security;

-- Templates are a public catalog (any authenticated member sees them in the gallery).
create policy "rule_templates_read"
  on public.rule_templates
  for select to authenticated
  using (true);

-- =============================================================================
-- 2. rule_versions — append-only snapshots of compiled rules
-- =============================================================================
-- Every publish creates a new rule_versions row. The `compiled` jsonb is the frozen
-- canonical form (trigger/conditions/consequences/exceptions/scope/target) materialized
-- at publish time from (template + params) or (per-piece draft). Engine evaluates
-- against `compiled`, never against the mutable `rules` row.
--
-- Append-only: triggers block UPDATE except for `effective_until` (set when superseded
-- by a newer version). DELETE blocked entirely. Pattern: system_events (mig 00162).

create table public.rule_versions (
  id                  uuid primary key default gen_random_uuid(),
  rule_id             uuid not null references public.rules(id) on delete restrict,
  version             int  not null check (version >= 1),
  template_id         text references public.rule_templates(id) on delete set null,    -- null if per-piece authored
  shape_params        jsonb not null default '{}'::jsonb,
  compiled            jsonb not null,                                                   -- frozen rule body
  status              text not null check (status in ('active','inactive','superseded','draft')),
  effective_from      timestamptz not null,
  effective_until     timestamptz,
  previous_version_id uuid references public.rule_versions(id) on delete set null,
  created_by          uuid not null references auth.users(id) on delete restrict,
  change_reason       text,
  created_at          timestamptz not null default now(),
  unique (rule_id, version)
);

create index idx_rule_versions_rule
  on public.rule_versions (rule_id, version desc);
-- Enforces: at most one active version per rule at any time.
create unique index idx_rule_versions_one_active_per_rule
  on public.rule_versions (rule_id)
  where status = 'active';
create index idx_rule_versions_effective
  on public.rule_versions (effective_from, effective_until);
create index idx_rule_versions_template
  on public.rule_versions (template_id)
  where template_id is not null;

comment on table public.rule_versions is
  'Append-only snapshots of compiled rule bodies. Each publish writes a new row; previous row gets its effective_until set. Engine reads `compiled` jsonb (frozen), never the mutable `rules` row. Per Governance.md §7.1 + §16. Atom-like: only `effective_until` may be updated post-insert (when superseded).';
comment on column public.rule_versions.compiled is
  'jsonb: canonical compiled form {trigger, conditions[], consequences[], exceptions[], scope, target, priority}. Materialized by publish_rule_version RPC from template composition + shape_params, or from per-piece draft. Engine never re-derives this from the template — frozen snapshot only.';
comment on column public.rule_versions.template_id is
  'NULL when the rule was authored per-piece (admin/dev mode). Set when the rule was created via a curated template. Allows audit of how many rules came from each template.';

-- Append-only guard: only effective_until is mutable; everything else immutable.
create or replace function public.rule_versions_atom_guard()
returns trigger language plpgsql as $$
begin
  if TG_OP = 'DELETE' then
    raise exception 'rule_versions is append-only. DELETE not allowed.'
      using errcode = 'check_violation';
  end if;
  if TG_OP = 'UPDATE' then
    if OLD.id                  is distinct from NEW.id                  or
       OLD.rule_id             is distinct from NEW.rule_id             or
       OLD.version             is distinct from NEW.version             or
       OLD.template_id         is distinct from NEW.template_id         or
       OLD.shape_params        is distinct from NEW.shape_params        or
       OLD.compiled            is distinct from NEW.compiled            or
       OLD.effective_from      is distinct from NEW.effective_from      or
       OLD.previous_version_id is distinct from NEW.previous_version_id or
       OLD.created_by          is distinct from NEW.created_by          or
       OLD.change_reason       is distinct from NEW.change_reason       or
       OLD.created_at          is distinct from NEW.created_at then
      raise exception 'rule_versions is append-only. Only effective_until and status (active→superseded/inactive) may be updated.'
        using errcode = 'check_violation';
    end if;
  end if;
  return NEW;
end;
$$;

create trigger rule_versions_atom_guard_trg
  before update or delete on public.rule_versions
  for each row execute function public.rule_versions_atom_guard();

alter table public.rule_versions enable row level security;

-- Group members read all versions of rules in their group.
create policy "rule_versions_member_read"
  on public.rule_versions
  for select to authenticated
  using (
    public.is_group_member(
      (select group_id from public.rules where id = rule_versions.rule_id),
      auth.uid()
    )
  );

-- Only service role writes (via publish_rule_version RPC in mig 00171).

-- =============================================================================
-- 3. rule_evaluations — technical audit, append-only
-- =============================================================================
-- One row per engine evaluation. Idempotency_key UNIQUE prevents double-execution
-- on retries. Per Governance.md §15.2: this is technical audit, NOT user-facing
-- activity. User feed shows emitted consequence atoms (fines, role_assigned),
-- not rule_evaluations. Admin sees this via RuleDetailView → Activity tab.

create table public.rule_evaluations (
  id                  uuid primary key default gen_random_uuid(),
  rule_id             uuid not null references public.rules(id) on delete restrict,
  rule_version_id     uuid not null references public.rule_versions(id) on delete restrict,
  trigger_event_id    uuid not null,
  trigger_event_table text not null check (trigger_event_table in
                        ('system_events','rsvp_actions','check_in_actions','vote_casts','ledger_entries')),
  group_id            uuid not null references public.groups(id) on delete cascade,
  actor_id            uuid references auth.users(id) on delete set null,
  verdict             text not null check (verdict in
                        ('matched_consequences','matched_no_action','exception_short_circuit','no_match','error')),
  consequences        jsonb not null default '[]'::jsonb,
  conflicts_detected  jsonb not null default '[]'::jsonb,
  error_message       text,
  evaluated_at        timestamptz not null default now(),
  idempotency_key     text not null,
  unique (idempotency_key)
);

create index idx_rule_evaluations_rule
  on public.rule_evaluations (rule_id, evaluated_at desc);
create index idx_rule_evaluations_group
  on public.rule_evaluations (group_id, evaluated_at desc);
create index idx_rule_evaluations_trigger
  on public.rule_evaluations (trigger_event_id, trigger_event_table);

comment on table public.rule_evaluations is
  'Technical audit row per engine evaluation. Append-only. UNIQUE idempotency_key prevents duplicate consequence on retry. Per Governance.md §15.2 — NOT routed to user feed; admins see via RuleDetailView → Activity.';
comment on column public.rule_evaluations.idempotency_key is
  'sha1(rule_version_id || trigger_event_id || target_id || consequence_index). UNIQUE constraint absorbs retries.';

create or replace function public.rule_evaluations_atom_guard()
returns trigger language plpgsql as $$
begin
  raise exception 'rule_evaluations is append-only. UPDATE/DELETE not allowed.'
    using errcode = 'check_violation';
end;
$$;

create trigger rule_evaluations_atom_guard_trg
  before update or delete on public.rule_evaluations
  for each row execute function public.rule_evaluations_atom_guard();

alter table public.rule_evaluations enable row level security;

-- Only group admins read evaluations (technical audit).
create policy "rule_evaluations_admin_read"
  on public.rule_evaluations
  for select to authenticated
  using (public.is_group_admin(rule_evaluations.group_id, auth.uid()));

-- =============================================================================
-- 4. rule_conflicts — publish-time conflict detection state
-- =============================================================================
-- Mutable lifecycle: detected_at on insert, resolved_at when one side changes.
-- Per Governance.md §13 — Beta 1 detects 4 conflict types blocking/warning publish.

create table public.rule_conflicts (
  id                uuid primary key default gen_random_uuid(),
  group_id          uuid not null references public.groups(id) on delete cascade,
  rule_a_version_id uuid not null references public.rule_versions(id) on delete cascade,
  rule_b_version_id uuid not null references public.rule_versions(id) on delete cascade,
  conflict_type     text not null check (conflict_type in
                      ('contradictory_consequences','same_scope_overlapping','impossible_condition',
                       'consequence_missing_capability','priority_ambiguity','loop_detected',
                       'approval_deadlock','quota_overlap')),
  severity          text not null check (severity in ('blocking','warning')),
  detected_at       timestamptz not null default now(),
  resolved_at       timestamptz,
  resolution        text,
  check (rule_a_version_id <> rule_b_version_id)
);

create index idx_rule_conflicts_open
  on public.rule_conflicts (group_id, detected_at desc)
  where resolved_at is null;
create index idx_rule_conflicts_rule_a
  on public.rule_conflicts (rule_a_version_id);
create index idx_rule_conflicts_rule_b
  on public.rule_conflicts (rule_b_version_id);

comment on table public.rule_conflicts is
  'Publish-time conflict detection between rule versions. Mutable: resolved_at + resolution set when one side changes. Per Governance.md §13. Beta 1 detects: contradictory_consequences, same_scope_overlapping, impossible_condition, consequence_missing_capability.';

alter table public.rule_conflicts enable row level security;

create policy "rule_conflicts_admin_read"
  on public.rule_conflicts
  for select to authenticated
  using (public.is_group_admin(rule_conflicts.group_id, auth.uid()));

-- =============================================================================
-- 5. member_capability_overrides — exclusions / priority deviations
-- =============================================================================
-- Per Governance.md §7.2 — David fuera de rotativa, guest con permiso especial,
-- socio fundador con prioridad, exemption por nuevo miembro 30 días, etc.
-- Mutable lifecycle: set effective_until to deactivate.
--
-- POST-BETA: generalize to relation_capability_overrides (guest/role/ownership/custodian).
-- Beta 1 keeps member-only.

create table public.member_capability_overrides (
  id              uuid primary key default gen_random_uuid(),
  group_id        uuid not null references public.groups(id) on delete cascade,
  member_id       uuid not null references public.group_members(id) on delete cascade,
  capability      text not null,
  override        text not null check (override in
                    ('excluded','allowed','priority_high','priority_low','exempt')),
  effective_from  timestamptz not null default now(),
  effective_until timestamptz,
  reason          text,
  created_by      uuid not null references auth.users(id) on delete restrict,
  created_at      timestamptz not null default now()
);

-- Enforces: at most one open override per (group, member, capability) at a time.
create unique index idx_member_overrides_one_open_per_triple
  on public.member_capability_overrides (group_id, member_id, capability)
  where effective_until is null;
create index idx_member_overrides_member
  on public.member_capability_overrides (member_id, capability);

comment on table public.member_capability_overrides is
  'Per-member exceptions to a capability (excluded, allowed, priority_high/low, exempt). Engine consults active overrides during evaluation. Per Governance.md §7.2 — generalizes to relation_capability_overrides Post-Beta.';

alter table public.member_capability_overrides enable row level security;

-- Group members can see overrides for their group (transparency).
create policy "member_overrides_read"
  on public.member_capability_overrides
  for select to authenticated
  using (public.is_group_member(member_capability_overrides.group_id, auth.uid()));

-- Admin write policy. Member self-write (e.g. opt-out from rotation) deferred Post-Beta.
create policy "member_overrides_admin_write"
  on public.member_capability_overrides
  for all to authenticated
  using (public.is_group_admin(member_capability_overrides.group_id, auth.uid()))
  with check (public.is_group_admin(member_capability_overrides.group_id, auth.uid()));

-- =============================================================================
-- End of mig 00170. Next: mig 00171 will add publish_rule_version,
-- list_rule_templates, sync_rule_templates_from_seed RPCs.
-- =============================================================================
