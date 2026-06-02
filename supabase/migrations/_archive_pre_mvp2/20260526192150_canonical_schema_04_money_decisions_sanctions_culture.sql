-- §7. Money 2.0
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
create trigger group_settlement_obligations_atom_guard before update on public.group_settlement_obligations
  for each row execute function public.atom_no_mutation_guard();
create trigger group_settlement_obligations_no_delete before delete on public.group_settlement_obligations
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

-- §8. Decisions
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
  reference_kind  text,
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
  'Primitive 16 — strict append-only ballots. Members may cast multiple times while the decision is open; the current vote per (decision, voter) is the row with the largest seq. No is_current column; no UPDATE; no DELETE. Counting must use DISTINCT ON.';
create index group_votes_decision_idx on public.group_votes(decision_id, voter_membership_id, seq desc);
create trigger group_votes_atom_guard before update on public.group_votes
  for each row execute function public.atom_no_mutation_guard();
create trigger group_votes_no_delete before delete on public.group_votes
  for each row execute function public.atom_no_delete_guard();

-- §9. Sanctions
create table public.group_sanctions (
  id                       uuid primary key default gen_random_uuid(),
  group_id                 uuid not null references public.groups(id) on delete cascade,
  target_membership_id     uuid not null references public.group_memberships(id) on delete cascade,
  issued_by_membership_id  uuid references public.group_memberships(id) on delete set null,
  rule_version_id          uuid references public.group_rule_versions(id) on delete set null,
  source_event_id          uuid,
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
  dispute_id               uuid,
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

-- §10. Disputes
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
create trigger group_dispute_events_atom_guard before update on public.group_dispute_events
  for each row execute function public.atom_no_mutation_guard();
create trigger group_dispute_events_no_delete before delete on public.group_dispute_events
  for each row execute function public.atom_no_delete_guard();

-- §11. Reputation
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
  evidence_entity_kind     text,
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
create trigger group_reputation_events_atom_guard before update on public.group_reputation_events
  for each row execute function public.atom_no_mutation_guard('status,visibility');
create trigger group_reputation_events_no_delete before delete on public.group_reputation_events
  for each row execute function public.atom_no_delete_guard();

-- §12. Cultural norms
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

-- §13. Dissolutions
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
