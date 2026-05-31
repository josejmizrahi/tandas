-- Mig 00224: my_activity_v1 — cross-group user-scoped atom feed.
-- Unions 4 atom sources (rsvp_actions, check_in_actions, vote_casts,
-- ledger_entries) into a single chronological view. RLS inherited
-- from each source table — view is transport convenience only.

create or replace view public.my_activity_v1 as
  select 'rsvp'::text as kind,
         ra.id,
         ra.resource_id,
         gm.user_id,
         gm.group_id,
         jsonb_build_object('status', ra.status) as payload,
         ra.recorded_at as occurred_at
  from public.rsvp_actions ra
  join public.group_members gm on gm.id = ra.member_id

  union all

  select 'check_in',
         ca.id,
         ca.resource_id,
         gm.user_id,
         gm.group_id,
         jsonb_build_object('method', ca.metadata->>'check_in_method'),
         ca.recorded_at
  from public.check_in_actions ca
  join public.group_members gm on gm.id = ca.member_id

  union all

  select 'vote_cast',
         vc.id,
         vc.vote_id::uuid,
         gm.user_id,
         gm.group_id,
         jsonb_build_object('choice', vc.choice, 'vote_id', vc.vote_id::text),
         coalesce(vc.cast_at, vc.created_at)
  from public.vote_casts vc
  join public.group_members gm on gm.id = vc.member_id
  where vc.cast_at is not null and vc.choice <> 'pending'

  union all

  select 'ledger',
         le.id,
         le.resource_id,
         gmf.user_id,
         le.group_id,
         jsonb_build_object(
           'type', le.type,
           'amount_cents', le.amount_cents,
           'currency', le.currency
         ),
         le.occurred_at
  from public.ledger_entries le
  join public.group_members gmf on gmf.id = le.from_member_id
  where gmf.user_id is not null;

grant select on public.my_activity_v1 to authenticated;
