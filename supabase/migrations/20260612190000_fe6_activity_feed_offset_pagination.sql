-- ────────────────────────────────────────────────────────────────────────────
-- FE.6 — paginación del feed personal (R.3A): `activity_feed` gana
-- `p_offset` (offset-pagination preservando el orden rankeado por score —
-- un cursor temporal rompería el ranking del digest). Se DROPea el overload
-- de 2 params para no proliferar overloads (doctrina AUDIT.12/13); los
-- callers existentes siguen funcionando por los defaults.
-- ────────────────────────────────────────────────────────────────────────────

drop function if exists public.activity_feed(uuid, integer);

create or replace function public.activity_feed(
  p_actor_id uuid default null,
  p_limit int default 50,
  p_offset int default 0
) returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_actor uuid := coalesce(p_actor_id, v_caller);
  v_limit int := least(greatest(coalesce(p_limit, 50), 1), 200);
  v_offset int := greatest(coalesce(p_offset, 0), 0);
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode='28000'; end if;
  if v_actor <> v_caller then
    raise exception 'cannot read feed of another actor' using errcode='42501';
  end if;

  return jsonb_build_object(
    'actor_id', v_actor,
    'limit', v_limit,
    'offset', v_offset,
    'feed', coalesce((
      with
      -- (a) Subscriptions activas
      subs as (
        select s.subscription_type,
               s.target_type,
               s.target_actor_id,
               s.target_resource_id,
               s.target_decision_id,
               s.target_event_id,
               s.target_obligation_id
          from public.subscriptions s
         where s.subscriber_actor_id = v_actor
           and s.removed_at is null
      ),
      -- (b) Recursos donde el actor es OWN activo
      owned_resources as (
        select rr.resource_id
          from public.resource_rights rr
         where rr.holder_actor_id = v_actor
           and rr.right_kind = 'own'
           and rr.revoked_at is null
           and rr.expired_at is null
           and (rr.starts_at is null or rr.starts_at <= now())
           and (rr.ends_at is null or rr.ends_at > now())
      ),
      -- (c) Contextos donde el actor es miembro activo (incluye su propio actor)
      my_contexts as (
        select v_actor as context_actor_id
        union
        select am.context_actor_id
          from public.actor_memberships am
         where am.member_actor_id = v_actor
           and am.membership_status = 'active'
      ),
      -- Candidatos: cada evento puede aparecer por múltiples fuentes; tomamos
      -- la mejor (mayor score). UNION ALL + DISTINCT ON.
      candidates as (
        -- subscription: actor/context target → eventos de ese contexto
        select ae.*,
               'subscription'::text as source,
               s.subscription_type,
               case s.subscription_type
                 when 'owner_interest' then 100
                 when 'stakeholder'    then 80
                 when 'audit'          then 65
                 when 'watch'          then 50
                 when 'follow'         then 30
                 else 30 end as score
          from public.activity_events ae
          join subs s on (s.target_type in ('actor','context') and s.target_actor_id = ae.context_actor_id)
        union all
        -- subscription: resource → eventos donde resource_id matchea
        select ae.*,
               'subscription'::text,
               s.subscription_type,
               case s.subscription_type
                 when 'owner_interest' then 100
                 when 'stakeholder'    then 80
                 when 'audit'          then 65
                 when 'watch'          then 50
                 when 'follow'         then 30
                 else 30 end
          from public.activity_events ae
          join subs s on (s.target_type = 'resource' and s.target_resource_id = ae.resource_id)
        union all
        -- subscription: decision
        select ae.*,
               'subscription'::text,
               s.subscription_type,
               case s.subscription_type
                 when 'owner_interest' then 100
                 when 'stakeholder'    then 80
                 when 'audit'          then 65
                 when 'watch'          then 50
                 when 'follow'         then 30
                 else 30 end
          from public.activity_events ae
          join subs s on (s.target_type = 'decision' and s.target_decision_id = ae.decision_id)
        union all
        -- subscription: event (subject_id of subject_type='calendar_event')
        select ae.*,
               'subscription'::text,
               s.subscription_type,
               case s.subscription_type
                 when 'owner_interest' then 100
                 when 'stakeholder'    then 80
                 when 'audit'          then 65
                 when 'watch'          then 50
                 when 'follow'         then 30
                 else 30 end
          from public.activity_events ae
          join subs s on (s.target_type = 'event' and ae.subject_type in ('calendar_event','event') and ae.subject_id = s.target_event_id)
        union all
        -- subscription: obligation
        select ae.*,
               'subscription'::text,
               s.subscription_type,
               case s.subscription_type
                 when 'owner_interest' then 100
                 when 'stakeholder'    then 80
                 when 'audit'          then 65
                 when 'watch'          then 50
                 when 'follow'         then 30
                 else 30 end
          from public.activity_events ae
          join subs s on (s.target_type = 'obligation' and s.target_obligation_id = ae.obligation_id)
        union all
        -- ownership: eventos sobre recursos que el actor posee
        select ae.*,
               'ownership'::text,
               null::text,
               90
          from public.activity_events ae
          join owned_resources o on o.resource_id = ae.resource_id
        union all
        -- membership: eventos en contextos donde el actor es miembro
        select ae.*,
               'membership'::text,
               null::text,
               70
          from public.activity_events ae
          join my_contexts mc on mc.context_actor_id = ae.context_actor_id
      ),
      -- Best source/score per (event_id)
      best as (
        select distinct on (id)
               id, context_actor_id, actor_id, event_type, subject_type, subject_id,
               payload, resource_id, decision_id, obligation_id, occurred_at,
               source, subscription_type, score
          from candidates
         order by id, score desc, occurred_at desc
      ),
      -- Final ranking
      ranked as (
        select * from best
         order by score desc, occurred_at desc
         limit v_limit offset v_offset
      )
      select jsonb_agg(jsonb_build_object(
        'id', r.id,
        'event_type', r.event_type,
        'actor_id', r.actor_id,
        'context_actor_id', r.context_actor_id,
        'subject_type', r.subject_type,
        'subject_id', r.subject_id,
        'payload', r.payload,
        'resource_id', r.resource_id,
        'decision_id', r.decision_id,
        'obligation_id', r.obligation_id,
        'occurred_at', r.occurred_at,
        'source', r.source,
        'subscription_type', r.subscription_type,
        'score', r.score
      ) order by r.score desc, r.occurred_at desc)
      from ranked r
    ), '[]'::jsonb)
  );
end; $$;

revoke all on function public.activity_feed(uuid, int, int) from public, anon;
grant execute on function public.activity_feed(uuid, int, int) to authenticated, service_role;
