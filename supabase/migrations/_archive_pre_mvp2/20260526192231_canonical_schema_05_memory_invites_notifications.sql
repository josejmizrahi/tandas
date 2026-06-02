-- §14. Memory + invites
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
  'Primitive 13 (Memory). Universal append-only audit log. id is a monotonic database cursor for order/pagination/replay, NOT a gapless sequence and NOT a strict commit-time clock. uuid_id is the stable public identifier for cross-entity references. Use occurred_at/created_at for human chronology.';
create index group_events_group_id_idx          on public.group_events(group_id, id);
create index group_events_group_created_at_idx  on public.group_events(group_id, created_at desc, id desc);
create index group_events_entity_idx            on public.group_events(entity_kind, entity_id);
create trigger group_events_atom_guard before update on public.group_events
  for each row execute function public.atom_no_mutation_guard();
create trigger group_events_no_delete before delete on public.group_events
  for each row execute function public.atom_no_delete_guard();

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
  code               text,
  expires_at         timestamptz,
  accepted_at        timestamptz,
  metadata           jsonb not null default '{}'::jsonb,
  created_at         timestamptz not null default now()
);
comment on table public.group_invites is
  'Primitive 15 (Entry) — pending invitation. Tokens stored as hash; codes for shareable links.';
create index group_invites_group_idx on public.group_invites(group_id);
create index group_invites_email_idx on public.group_invites(email);

-- §15. Notifications
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
  category    text not null,
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
create index notifications_outbox_pending_idx on public.notifications_outbox(dispatch_status)
  where dispatch_status = 'pending';

-- §15.5 Same-group enforcement
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

alter table public.group_votes
  add constraint group_votes_decision_same_group_fk
  foreign key (decision_id, group_id) references public.group_decisions(id, group_id),
  add constraint group_votes_voter_same_group_fk
  foreign key (voter_membership_id, group_id) references public.group_memberships(id, group_id);

alter table public.group_resource_transactions
  add constraint group_resource_transactions_resource_same_group_fk
  foreign key (resource_id, group_id) references public.group_resources(id, group_id);

alter table public.group_resource_bookings
  add constraint group_resource_bookings_resource_same_group_fk
  foreign key (resource_id, group_id) references public.group_resources(id, group_id),
  add constraint group_resource_bookings_member_same_group_fk
  foreign key (booked_by_membership_id, group_id) references public.group_memberships(id, group_id);

alter table public.group_rsvp_actions
  add constraint group_rsvp_actions_resource_same_group_fk
  foreign key (resource_id, group_id) references public.group_resources(id, group_id),
  add constraint group_rsvp_actions_member_same_group_fk
  foreign key (membership_id, group_id) references public.group_memberships(id, group_id);

alter table public.group_check_in_actions
  add constraint group_check_in_actions_resource_same_group_fk
  foreign key (resource_id, group_id) references public.group_resources(id, group_id),
  add constraint group_check_in_actions_member_same_group_fk
  foreign key (membership_id, group_id) references public.group_memberships(id, group_id);

alter table public.group_obligations
  add constraint group_obligations_owed_by_same_group_fk
  foreign key (owed_by_membership_id, group_id) references public.group_memberships(id, group_id);

alter table public.group_settlements
  add constraint group_settlements_paid_by_same_group_fk
  foreign key (paid_by_membership_id, group_id) references public.group_memberships(id, group_id);

alter table public.group_sanctions
  add constraint group_sanctions_target_same_group_fk
  foreign key (target_membership_id, group_id) references public.group_memberships(id, group_id);

alter table public.group_contributions
  add constraint group_contributions_member_same_group_fk
  foreign key (membership_id, group_id) references public.group_memberships(id, group_id);

alter table public.group_membership_events
  add constraint group_membership_events_member_same_group_fk
  foreign key (membership_id, group_id) references public.group_memberships(id, group_id);

alter table public.group_mandates
  add constraint group_mandates_representative_same_group_fk
  foreign key (representative_membership_id, group_id) references public.group_memberships(id, group_id);

alter table public.group_reputation_events
  add constraint group_reputation_events_subject_same_group_fk
  foreign key (subject_membership_id, group_id) references public.group_memberships(id, group_id);

alter table public.group_resources
  add constraint group_resources_series_same_group_fk
  foreign key (series_id, group_id) references public.group_resource_series(id, group_id);

create or replace function public.assert_member_role_same_group()
returns trigger language plpgsql as $$
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
returns trigger language plpgsql as $$
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

-- §15.6 Resource subtype type assertion
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
