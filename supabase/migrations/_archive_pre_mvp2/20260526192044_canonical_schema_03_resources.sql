-- §6. Resources — envelope + subtypes
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
  unit                  text,
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
comment on table public.group_resource_events is 'Subtype: event — gathering with RSVP/check-in lifecycle.';
create trigger group_resource_events_set_updated_at before update on public.group_resource_events
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
comment on table public.group_resource_funds is 'Subtype: fund — pool/protected/shared_pool money envelope.';
create trigger group_resource_funds_set_updated_at before update on public.group_resource_funds
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
comment on table public.group_resource_slots is 'Subtype: slot — time-bounded assignable position.';
create trigger group_resource_slots_set_updated_at before update on public.group_resource_slots
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
comment on table public.group_resource_spaces is 'Subtype: space — physical or logical location bookable by members.';
create trigger group_resource_spaces_set_updated_at before update on public.group_resource_spaces
  for each row execute function public.set_updated_at();

create table public.group_resource_assets (
  resource_id        uuid primary key references public.group_resources(id) on delete cascade,
  asset_kind         text,
  serial_number      text,
  current_value      numeric(18,4),
  current_value_unit text,
  condition          text,
  custodian_membership_id uuid references public.group_memberships(id) on delete set null,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);
comment on table public.group_resource_assets is 'Subtype: asset — tangible item the group owns or uses.';
create trigger group_resource_assets_set_updated_at before update on public.group_resource_assets
  for each row execute function public.set_updated_at();

create table public.group_resource_asset_valuations (
  id            uuid primary key default gen_random_uuid(),
  resource_id   uuid not null references public.group_resource_assets(resource_id) on delete cascade,
  value         numeric(18,4) not null,
  unit          text not null,
  basis         text,
  recorded_by   uuid references public.profiles(id) on delete set null,
  recorded_at   timestamptz not null default now()
);
comment on table public.group_resource_asset_valuations is 'Append-only valuation history for an asset.';
create trigger group_resource_asset_valuations_atom_guard
  before update on public.group_resource_asset_valuations
  for each row execute function public.atom_no_mutation_guard();
create trigger group_resource_asset_valuations_no_delete
  before delete on public.group_resource_asset_valuations
  for each row execute function public.atom_no_delete_guard();

create table public.group_resource_rights (
  resource_id           uuid primary key references public.group_resources(id) on delete cascade,
  right_kind            text not null,
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
comment on table public.group_resource_rights is 'Subtype: right — discrete derecho de uso/exclusión/transferencia held by a member.';
create trigger group_resource_rights_set_updated_at before update on public.group_resource_rights
  for each row execute function public.set_updated_at();

-- §6.2 Resource ops
create table public.group_resource_capabilities (
  id              uuid primary key default gen_random_uuid(),
  resource_id     uuid not null references public.group_resources(id) on delete cascade,
  capability_key  text not null,
  enabled         boolean not null default true,
  config          jsonb not null default '{}'::jsonb,
  enabled_by      uuid references public.profiles(id) on delete set null,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (resource_id, capability_key)
);
comment on table public.group_resource_capabilities is
  'Per-resource feature toggles (rsvp/check-in/rotation/reminders). Replaces capability registry.';
create trigger group_resource_capabilities_set_updated_at before update on public.group_resource_capabilities
  for each row execute function public.set_updated_at();

create table public.group_resource_series (
  id                uuid primary key default gen_random_uuid(),
  group_id          uuid not null references public.groups(id) on delete cascade,
  resource_type     text not null,
  cadence           text not null check (cadence in ('once','daily','weekly','biweekly','monthly','quarterly','yearly','custom')),
  pattern           jsonb not null default '{}'::jsonb,
  starts_on         date,
  ends_on           date,
  ritual_meaning    text,
  ritual_marker_kind text check (ritual_marker_kind in (
                      'weekly_meeting','monthly_meeting','annual_assembly','onboarding','farewell','celebration','retrospective','none'
                    )),
  ritual_norm_id    uuid,
  template_payload  jsonb not null default '{}'::jsonb,
  created_by        uuid references public.profiles(id) on delete set null,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);
comment on table public.group_resource_series is
  'Primitive 21 (Ritual). Recurrence container + optional ritual meaning anchored on a cadence.';
create trigger group_resource_series_set_updated_at before update on public.group_resource_series
  for each row execute function public.set_updated_at();

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
create trigger group_resource_bookings_atom_guard before update on public.group_resource_bookings
  for each row execute function public.atom_no_mutation_guard('status,reason,metadata');
create trigger group_resource_bookings_no_delete before delete on public.group_resource_bookings
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
create trigger group_rsvp_actions_atom_guard before update on public.group_rsvp_actions
  for each row execute function public.atom_no_mutation_guard();
create trigger group_rsvp_actions_no_delete before delete on public.group_rsvp_actions
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
create trigger group_check_in_actions_atom_guard before update on public.group_check_in_actions
  for each row execute function public.atom_no_mutation_guard();
create trigger group_check_in_actions_no_delete before delete on public.group_check_in_actions
  for each row execute function public.atom_no_delete_guard();

create table public.group_resource_transactions (
  id                    uuid primary key default gen_random_uuid(),
  seq                   bigint generated always as identity unique,
  group_id              uuid not null references public.groups(id) on delete cascade,
  resource_id           uuid not null references public.group_resources(id) on delete cascade,
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
  source_entity_kind    text check (source_entity_kind in (
                          'sanction','settlement','obligation','booking',
                          'decision','contribution','manual'
                        )),
  source_entity_id      uuid,
  reversed_entry_id     uuid references public.group_resource_transactions(id) on delete set null,
  split_breakdown       jsonb,
  split_mode            text check (split_mode in ('even','custom','percentage','share')),
  in_kind               boolean not null default false,
  description           text,
  metadata              jsonb not null default '{}'::jsonb,
  client_id             text,
  recorded_by           uuid references public.profiles(id) on delete set null,
  occurred_at           timestamptz not null default now(),
  created_at            timestamptz not null default now(),
  unique (group_id, client_id)
);
comment on table public.group_resource_transactions is
  'Primitive 19 (Accounting) — append-only money/resource atoms. Rows represent value movements only. Reversal = new row referencing reversed_entry_id; nothing mutates. seq is a monotonic cursor for FIFO.';
create index group_resource_transactions_group_idx     on public.group_resource_transactions(group_id, seq);
create index group_resource_transactions_resource_idx  on public.group_resource_transactions(resource_id);
create index group_resource_transactions_source_idx    on public.group_resource_transactions(source_entity_kind, source_entity_id);
create trigger group_resource_transactions_atom_guard before update on public.group_resource_transactions
  for each row execute function public.atom_no_mutation_guard();
create trigger group_resource_transactions_no_delete before delete on public.group_resource_transactions
  for each row execute function public.atom_no_delete_guard();
