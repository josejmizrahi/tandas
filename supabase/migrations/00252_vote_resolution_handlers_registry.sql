-- 00241 — finalize_vote dispatches post-resolution to per-vote_type handlers.

create or replace function public.on_fine_appeal_resolved(
  p_vote_id    uuid,
  p_resolution text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_vote             public.votes;
  v_fine             public.fines;
  v_fine_user_id     uuid;
  v_fine_resource_id uuid;
  v_fine_member_id   uuid;
begin
  if p_resolution <> 'passed' then return; end if;
  select * into v_vote from public.votes where id = p_vote_id;
  if v_vote.id is null or v_vote.reference_id is null then return; end if;
  select * into v_fine from public.fines where id = v_vote.reference_id;
  if v_fine.id is null then return; end if;

  v_fine_user_id     := v_fine.user_id;
  v_fine_resource_id := v_fine.resource_id;
  select id into v_fine_member_id from public.group_members
    where group_id = v_fine.group_id and user_id = v_fine_user_id;

  insert into public.ledger_entries (
    group_id, type, from_member_id, amount_cents, metadata
  ) values (
    v_fine.group_id, 'fine_voided', v_fine_member_id,
    (v_fine.amount * 100)::bigint,
    jsonb_build_object(
      'fine_id', v_fine.id, 'reason', 'appeal_passed', 'vote_id', p_vote_id
    )
  );
end;
$$;

revoke execute on function public.on_fine_appeal_resolved(uuid, text) from public, anon;
grant  execute on function public.on_fine_appeal_resolved(uuid, text) to authenticated, service_role;

comment on function public.on_fine_appeal_resolved(uuid, text) is
  'Post-resolution handler for vote_type=fine_appeal. Invoked by finalize_vote (mig 00241) via naming-convention dispatch.';

create or replace function public.on_rule_change_resolved(
  p_vote_id    uuid,
  p_resolution text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_vote             public.votes;
  v_current_amount   int;
  v_proposed_amount  int;
  v_rule_id          uuid;
begin
  if p_resolution <> 'passed' then return; end if;
  select * into v_vote from public.votes where id = p_vote_id;
  if v_vote.id is null then return; end if;

  v_current_amount  := nullif(v_vote.payload->>'current_amount',  '')::int;
  v_proposed_amount := nullif(v_vote.payload->>'proposed_amount', '')::int;
  v_rule_id         := nullif(v_vote.payload->>'rule_id',         '')::uuid;
  if v_current_amount is null or v_proposed_amount is null or v_rule_id is null then return; end if;

  update public.rules
     set consequences = jsonb_set(consequences, '{0,config,amount}', to_jsonb(v_proposed_amount), true)
   where id = v_rule_id;
end;
$$;

revoke execute on function public.on_rule_change_resolved(uuid, text) from public, anon;
grant  execute on function public.on_rule_change_resolved(uuid, text) to authenticated, service_role;

comment on function public.on_rule_change_resolved(uuid, text) is
  'Post-resolution handler for vote_type=rule_change. Invoked by finalize_vote (mig 00241) via naming-convention dispatch.';

create or replace function public.finalize_vote(p_vote_id uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_vote          public.votes%rowtype;
  v_in_favor      int;
  v_against       int;
  v_abstained     int;
  v_pending       int;
  v_total         int;
  v_voted         int;
  v_quorum_count  int;
  v_resolution    text;
  v_handler       text;
begin
  select * into v_vote from public.votes where id = p_vote_id for update;
  if not found then raise exception 'vote not found' using errcode = '02000'; end if;
  if v_vote.status <> 'open' then
    return coalesce(v_vote.payload->>'resolution', 'unknown');
  end if;

  with latest_per_member as (
    select distinct on (member_id) member_id, choice
    from public.vote_casts where vote_id = p_vote_id
    order by member_id, created_at desc, id desc
  )
  select
    count(*) filter (where choice = 'in_favor'),
    count(*) filter (where choice = 'against'),
    count(*) filter (where choice = 'abstained'),
    count(*) filter (where choice = 'pending'),
    count(*)
  into v_in_favor, v_against, v_abstained, v_pending, v_total
  from latest_per_member;

  v_voted := v_in_favor + v_against + v_abstained;
  v_quorum_count := greatest(
    ceil(v_total::numeric * v_vote.quorum_percent / 100)::int,
    v_vote.quorum_min_absolute
  );

  if v_voted < v_quorum_count then
    v_resolution := 'quorum_failed';
  elsif v_in_favor::numeric * 100 >= (v_in_favor + v_against)::numeric * v_vote.threshold_percent then
    v_resolution := 'passed';
  else
    v_resolution := 'failed';
  end if;

  update public.votes
     set status      = case when v_resolution = 'quorum_failed' then 'quorum_failed' else 'resolved' end,
         resolved_at = now(),
         counts      = jsonb_build_object(
                         'inFavor', v_in_favor, 'against', v_against, 'abstained', v_abstained,
                         'pending', v_pending, 'totalEligible', v_total,
                         'quorumRequired', v_quorum_count, 'resolution', v_resolution
                       ),
         payload     = payload || jsonb_build_object('resolution', v_resolution)
   where id = p_vote_id;

  insert into public.system_events (group_id, event_type, resource_id, member_id, payload)
  values (
    v_vote.group_id, 'voteResolved', p_vote_id, null,
    jsonb_build_object('vote_type', v_vote.vote_type, 'reference_id', v_vote.reference_id, 'resolution', v_resolution)
  );

  insert into public.notifications_outbox (
    group_id, recipient_member_id, notification_type, payload, deep_link
  )
  select
    v_vote.group_id, vc.member_id, 'voteResolved',
    jsonb_build_object(
      'vote_id', p_vote_id, 'vote_type', v_vote.vote_type,
      'reference_id', v_vote.reference_id, 'resolution', v_resolution, 'title', v_vote.title
    ),
    'ruul://vote/' || p_vote_id::text
  from (select distinct member_id from public.vote_casts where vote_id = p_vote_id) vc;

  if v_vote.vote_type = 'fine_appeal' then
    insert into public.notifications_outbox (
      group_id, recipient_member_id, notification_type, payload, deep_link
    )
    select
      v_vote.group_id, (v_vote.payload->>'member_id')::uuid, 'voteResolved',
      jsonb_build_object(
        'vote_id', p_vote_id, 'vote_type', v_vote.vote_type,
        'reference_id', v_vote.reference_id, 'resolution', v_resolution,
        'title', v_vote.title, 'is_appellant', true
      ),
      'ruul://vote/' || p_vote_id::text
    where v_vote.payload ? 'member_id' and (v_vote.payload->>'member_id') <> '';
  end if;

  -- mig 00241: dispatch to per-vote_type handler by naming convention.
  v_handler := 'on_' || v_vote.vote_type || '_resolved';
  if exists (
    select 1 from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = v_handler
      and pg_get_function_identity_arguments(p.oid) = 'uuid, text'
  ) then
    execute format('select public.%I($1, $2)', v_handler) using p_vote_id, v_resolution;
  end if;

  return v_resolution;
end;
$$;

comment on function public.finalize_vote(uuid) is
  'v3 (mig 00241): post-resolution side effects dispatched to on_<vote_type>_resolved(uuid, text) by naming convention. Adding a new vote_type with side effects = implementing the handler only, no edits here.';
