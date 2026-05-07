-- 00032 rollback — restaurar finalize_vote v2 (00023).
--
-- USAR cuando V3 cause problemas en producción. Tras este rollback:
--   - rule_change resueltos no producen user_action ni outbox row con
--     deep_link → founders no reciben recordatorio de aplicar.
--   - Resto del flow (voteResolved system_event + voter fan-out) intacto.
--
-- Body capturado de pg_get_functiondef(public.finalize_vote) antes de
-- aplicar 00032.

CREATE OR REPLACE FUNCTION public.finalize_vote(p_vote_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
begin
  select * into v_vote from public.votes where id = p_vote_id for update;
  if not found then
    raise exception 'vote not found' using errcode = '02000';
  end if;
  if v_vote.status <> 'open' then
    return coalesce(v_vote.payload->>'resolution', 'unknown');
  end if;

  select
    count(*) filter (where choice = 'in_favor'),
    count(*) filter (where choice = 'against'),
    count(*) filter (where choice = 'abstained'),
    count(*) filter (where choice = 'pending'),
    count(*)
  into v_in_favor, v_against, v_abstained, v_pending, v_total
  from public.vote_casts
  where vote_id = p_vote_id;

  v_voted        := v_in_favor + v_against + v_abstained;
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
        'inFavor',        v_in_favor,
        'against',        v_against,
        'abstained',      v_abstained,
        'pending',        v_pending,
        'totalEligible',  v_total,
        'quorumRequired', v_quorum_count,
        'resolution',     v_resolution
      ),
      payload = payload || jsonb_build_object('resolution', v_resolution)
  where id = p_vote_id;

  insert into public.system_events (group_id, event_type, resource_id, member_id, payload)
  values (
    v_vote.group_id,
    'voteResolved',
    p_vote_id,
    null,
    jsonb_build_object(
      'vote_type',    v_vote.vote_type,
      'reference_id', v_vote.reference_id,
      'resolution',   v_resolution
    )
  );

  insert into public.notifications_outbox (
    group_id, recipient_member_id, notification_type, payload, deep_link
  )
  select
    v_vote.group_id,
    vc.member_id,
    'voteResolved',
    jsonb_build_object(
      'vote_id',      p_vote_id,
      'vote_type',    v_vote.vote_type,
      'reference_id', v_vote.reference_id,
      'resolution',   v_resolution,
      'title',        v_vote.title
    ),
    'ruul://vote/' || p_vote_id::text
  from public.vote_casts vc
  where vc.vote_id = p_vote_id;

  if v_vote.vote_type = 'fine_appeal' then
    insert into public.notifications_outbox (
      group_id, recipient_member_id, notification_type, payload, deep_link
    )
    select
      v_vote.group_id,
      (v_vote.payload->>'member_id')::uuid,
      'voteResolved',
      jsonb_build_object(
        'vote_id',      p_vote_id,
        'vote_type',    v_vote.vote_type,
        'reference_id', v_vote.reference_id,
        'resolution',   v_resolution,
        'title',        v_vote.title,
        'is_appellant', true
      ),
      'ruul://vote/' || p_vote_id::text
    where v_vote.payload ? 'member_id'
      and (v_vote.payload->>'member_id') <> '';
  end if;

  return v_resolution;
end;
$function$;
