-- Row level security for all public tables.
-- Membership is enforced via SECURITY DEFINER helpers (is_group_member / is_group_admin / is_group_committee)
-- defined in 00001_core_schema.sql.

alter table public.profiles enable row level security;
alter table public.groups enable row level security;
alter table public.group_members enable row level security;
alter table public.rules enable row level security;
alter table public.events enable row level security;
alter table public.event_attendance enable row level security;
alter table public.votes enable row level security;
alter table public.vote_ballots enable row level security;
alter table public.fines enable row level security;
alter table public.pots enable row level security;
alter table public.pot_entries enable row level security;
alter table public.expenses enable row level security;
alter table public.expense_shares enable row level security;
alter table public.payments enable row level security;

-- profiles: visible to self and to other members of any shared group
create policy "profiles_select" on public.profiles for select to authenticated
using (
  id = auth.uid() or exists (
    select 1 from public.group_members a join public.group_members b on a.group_id = b.group_id
    where a.user_id = auth.uid() and b.user_id = profiles.id
  )
);
create policy "profiles_insert_self" on public.profiles for insert to authenticated with check (id = auth.uid());
create policy "profiles_update_self" on public.profiles for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

-- groups
create policy "groups_select" on public.groups for select to authenticated
using (public.is_group_member(id, auth.uid()) or created_by = auth.uid());
create policy "groups_insert" on public.groups for insert to authenticated with check (created_by = auth.uid());
create policy "groups_update_admin" on public.groups for update to authenticated
using (public.is_group_admin(id, auth.uid())) with check (public.is_group_admin(id, auth.uid()));
create policy "groups_delete_admin" on public.groups for delete to authenticated using (public.is_group_admin(id, auth.uid()));

-- group_members
create policy "members_select" on public.group_members for select to authenticated using (public.is_group_member(group_id, auth.uid()));
create policy "members_insert_self" on public.group_members for insert to authenticated with check (user_id = auth.uid());
create policy "members_update_admin" on public.group_members for update to authenticated
using (public.is_group_admin(group_id, auth.uid())) with check (public.is_group_admin(group_id, auth.uid()));
create policy "members_delete" on public.group_members for delete to authenticated
using (user_id = auth.uid() or public.is_group_admin(group_id, auth.uid()));

-- rules: any member can propose; only admin can edit/archive/insert active rules.
create policy "rules_select" on public.rules for select to authenticated using (public.is_group_member(group_id, auth.uid()));
create policy "rules_insert_member" on public.rules for insert to authenticated with check (public.is_group_member(group_id, auth.uid()));
create policy "rules_update_admin" on public.rules for update to authenticated
using (public.is_group_admin(group_id, auth.uid())) with check (public.is_group_admin(group_id, auth.uid()));
create policy "rules_delete_admin" on public.rules for delete to authenticated using (public.is_group_admin(group_id, auth.uid()));

-- events
create policy "events_select" on public.events for select to authenticated using (public.is_group_member(group_id, auth.uid()));
create policy "events_insert" on public.events for insert to authenticated with check (public.is_group_member(group_id, auth.uid()));
create policy "events_update" on public.events for update to authenticated
using (public.is_group_admin(group_id, auth.uid()) or created_by = auth.uid())
with check (public.is_group_admin(group_id, auth.uid()) or created_by = auth.uid());
create policy "events_delete_admin" on public.events for delete to authenticated using (public.is_group_admin(group_id, auth.uid()));

-- attendance: members can RSVP/checkin themselves; admins can mark anyone.
create policy "att_select" on public.event_attendance for select to authenticated
using (exists (select 1 from public.events e where e.id = event_id and public.is_group_member(e.group_id, auth.uid())));
create policy "att_insert" on public.event_attendance for insert to authenticated
with check (
  exists (select 1 from public.events e where e.id = event_id and public.is_group_member(e.group_id, auth.uid()))
  and (user_id = auth.uid() or exists (select 1 from public.events e where e.id = event_id and public.is_group_admin(e.group_id, auth.uid())))
);
create policy "att_update" on public.event_attendance for update to authenticated
using (
  user_id = auth.uid()
  or exists (select 1 from public.events e where e.id = event_id and public.is_group_admin(e.group_id, auth.uid()))
)
with check (
  user_id = auth.uid()
  or exists (select 1 from public.events e where e.id = event_id and public.is_group_admin(e.group_id, auth.uid()))
);
create policy "att_delete_admin" on public.event_attendance for delete to authenticated
using (exists (select 1 from public.events e where e.id = event_id and public.is_group_admin(e.group_id, auth.uid())));

-- votes
create policy "votes_select" on public.votes for select to authenticated using (public.is_group_member(group_id, auth.uid()));
create policy "votes_insert" on public.votes for insert to authenticated
with check (public.is_group_member(group_id, auth.uid()) and created_by = auth.uid());
create policy "votes_update_admin" on public.votes for update to authenticated
using (public.is_group_admin(group_id, auth.uid())) with check (public.is_group_admin(group_id, auth.uid()));
create policy "votes_delete_admin" on public.votes for delete to authenticated using (public.is_group_admin(group_id, auth.uid()));

-- ballots
create policy "ballots_select" on public.vote_ballots for select to authenticated
using (exists (select 1 from public.votes v where v.id = vote_id and public.is_group_member(v.group_id, auth.uid())));
create policy "ballots_insert_self" on public.vote_ballots for insert to authenticated
with check (
  user_id = auth.uid()
  and exists (
    select 1 from public.votes v
    where v.id = vote_id and v.status = 'open' and public.is_group_member(v.group_id, auth.uid())
      and (not v.committee_only or public.is_group_committee(v.group_id, auth.uid()))
  )
);
create policy "ballots_update_self" on public.vote_ballots for update to authenticated
using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "ballots_delete_self" on public.vote_ballots for delete to authenticated using (user_id = auth.uid());

-- fines
create policy "fines_select" on public.fines for select to authenticated using (public.is_group_member(group_id, auth.uid()));
create policy "fines_insert_admin" on public.fines for insert to authenticated with check (public.is_group_admin(group_id, auth.uid()));
create policy "fines_update_admin" on public.fines for update to authenticated
using (public.is_group_admin(group_id, auth.uid())) with check (public.is_group_admin(group_id, auth.uid()));
create policy "fines_update_self" on public.fines for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "fines_delete_admin" on public.fines for delete to authenticated using (public.is_group_admin(group_id, auth.uid()));

-- pots
create policy "pots_select" on public.pots for select to authenticated using (public.is_group_member(group_id, auth.uid()));
create policy "pots_insert" on public.pots for insert to authenticated with check (public.is_group_member(group_id, auth.uid()));
create policy "pots_update" on public.pots for update to authenticated
using (created_by = auth.uid() or public.is_group_admin(group_id, auth.uid()))
with check (created_by = auth.uid() or public.is_group_admin(group_id, auth.uid()));
create policy "pots_delete" on public.pots for delete to authenticated
using (created_by = auth.uid() or public.is_group_admin(group_id, auth.uid()));

create policy "pot_entries_select" on public.pot_entries for select to authenticated
using (exists (select 1 from public.pots p where p.id = pot_id and public.is_group_member(p.group_id, auth.uid())));
create policy "pot_entries_insert_self" on public.pot_entries for insert to authenticated
with check (
  exists (select 1 from public.pots p where p.id = pot_id and public.is_group_member(p.group_id, auth.uid()))
  and (user_id = auth.uid() or exists (select 1 from public.pots p where p.id = pot_id and (p.created_by = auth.uid() or public.is_group_admin(p.group_id, auth.uid()))))
);
create policy "pot_entries_update" on public.pot_entries for update to authenticated
using (
  user_id = auth.uid()
  or exists (select 1 from public.pots p where p.id = pot_id and (p.created_by = auth.uid() or public.is_group_admin(p.group_id, auth.uid())))
)
with check (
  user_id = auth.uid()
  or exists (select 1 from public.pots p where p.id = pot_id and (p.created_by = auth.uid() or public.is_group_admin(p.group_id, auth.uid())))
);
create policy "pot_entries_delete" on public.pot_entries for delete to authenticated
using (
  user_id = auth.uid()
  or exists (select 1 from public.pots p where p.id = pot_id and (p.created_by = auth.uid() or public.is_group_admin(p.group_id, auth.uid())))
);

-- expenses
create policy "expenses_select" on public.expenses for select to authenticated using (public.is_group_member(group_id, auth.uid()));
create policy "expenses_insert" on public.expenses for insert to authenticated
with check (public.is_group_member(group_id, auth.uid()) and paid_by = auth.uid());
create policy "expenses_update" on public.expenses for update to authenticated
using (paid_by = auth.uid() or public.is_group_admin(group_id, auth.uid()))
with check (paid_by = auth.uid() or public.is_group_admin(group_id, auth.uid()));
create policy "expenses_delete" on public.expenses for delete to authenticated
using (paid_by = auth.uid() or public.is_group_admin(group_id, auth.uid()));

create policy "shares_select" on public.expense_shares for select to authenticated
using (exists (select 1 from public.expenses e where e.id = expense_id and public.is_group_member(e.group_id, auth.uid())));
create policy "shares_write" on public.expense_shares for all to authenticated
using (exists (select 1 from public.expenses e where e.id = expense_id and (e.paid_by = auth.uid() or public.is_group_admin(e.group_id, auth.uid()))))
with check (exists (select 1 from public.expenses e where e.id = expense_id and (e.paid_by = auth.uid() or public.is_group_admin(e.group_id, auth.uid()))));

-- payments
create policy "payments_select" on public.payments for select to authenticated using (public.is_group_member(group_id, auth.uid()));
create policy "payments_insert" on public.payments for insert to authenticated
with check (public.is_group_member(group_id, auth.uid()) and (from_user = auth.uid() or to_user = auth.uid()));
create policy "payments_delete" on public.payments for delete to authenticated
using (from_user = auth.uid() or to_user = auth.uid() or public.is_group_admin(group_id, auth.uid()));
