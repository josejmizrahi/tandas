-- 20260527231000 — record_dispute_resolution now releases the linked
-- sanction's status when a sanction-subject dispute resolves.
--
-- Bug surfaced 2026-05-27 (continuation): when a member disputes a
-- sanction, `dispute_sanction` flips `group_sanctions.status` to
-- 'disputed'. Resolving the dispute via `record_dispute_resolution`
-- only flipped the sanction further IF `p_outcome ? 'reverse_sanction'`
-- was true — any other resolution path left the sanction stranded
-- in 'disputed' forever, so `group_sanctions_active` kept returning
-- it and the Inicio "Necesita atención" cluster never released it.
--
-- Fix: when subject_kind = 'sanction', always reconcile the
-- sanction's status at resolution time:
--   * outcome includes reverse_sanction = true → 'reversed' (unchanged)
--   * else if linked obligation is settled        → 'completed'
--   * else                                          → 'active'
--
-- Rationale: a resolved dispute exits the 'disputed' transient state.
-- Whether the sanction is upheld (back to active), fulfilled
-- (completed because already paid), or overturned (reversed) is the
-- semantic of the resolution. No resolution path should leave it
-- in 'disputed'.

CREATE OR REPLACE FUNCTION public.record_dispute_resolution(
  p_dispute_id uuid,
  p_method text,
  p_resolution_text text,
  p_outcome jsonb DEFAULT NULL::jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
declare
  v_d                public.group_disputes%rowtype;
  v_actor            uuid;
  v_sanction         public.group_sanctions%rowtype;
  v_obligation_status text;
  v_new_sanction_status text;
begin
  select * into v_d from public.group_disputes where id = p_dispute_id for update;
  if v_d.id is null then raise exception 'dispute not found'; end if;
  v_actor := (select id from public.group_memberships where group_id = v_d.group_id and user_id = auth.uid());
  if v_d.mediator_membership_id <> v_actor and not public.has_group_permission(v_d.group_id, 'disputes.resolve') then
    raise exception 'caller cannot resolve this dispute';
  end if;

  update public.group_disputes
     set status = 'resolved', resolution_method = p_method, resolution = p_resolution_text, resolved_at = now()
   where id = p_dispute_id;

  insert into public.group_dispute_events (dispute_id, actor_membership_id, event_type, body, metadata)
  values (p_dispute_id, v_actor, 'resolution', p_resolution_text, coalesce(p_outcome, '{}'::jsonb));

  -- Reconcile linked sanction's status (sanction subject only).
  if v_d.subject_kind = 'sanction' then
    if coalesce((p_outcome ->> 'reverse_sanction')::boolean, false) then
      -- Sanction overturned: status → reversed + void the linked obligation.
      perform public.update_sanction_status(v_d.subject_id, 'reversed', 'dispute_resolution');
    else
      -- Sanction upheld (or resolution didn't address overturn).
      -- Snap status back out of the 'disputed' transient state.
      select * into v_sanction from public.group_sanctions where id = v_d.subject_id;
      if v_sanction.id is not null and v_sanction.status = 'disputed' then
        select status into v_obligation_status
          from public.group_obligations
         where id = v_sanction.obligation_id;

        if v_obligation_status = 'settled' then
          v_new_sanction_status := 'completed';
        else
          v_new_sanction_status := 'active';
        end if;

        update public.group_sanctions
           set status      = v_new_sanction_status,
               resolved_at = case when v_new_sanction_status = 'completed'
                                  then coalesce(resolved_at, now())
                                  else resolved_at
                             end,
               updated_at  = now()
         where id = v_sanction.id;
      end if;
    end if;
  end if;

  insert into public.group_reputation_events (group_id, subject_membership_id, actor_membership_id, reputation_type, reason, evidence_entity_kind, evidence_entity_id)
  select v_d.group_id, m, v_actor, 'conflict_resolved', p_resolution_text, 'dispute', p_dispute_id
  from unnest(ARRAY[v_d.opened_by_membership_id, v_d.respondent_membership_id]) as m
  where m is not null;

  perform public.record_system_event(
    v_d.group_id, 'dispute.resolved', 'dispute', p_dispute_id, p_resolution_text,
    coalesce(p_outcome, '{}'::jsonb)
  );
end;
$function$;

COMMENT ON FUNCTION public.record_dispute_resolution(uuid, text, text, jsonb) IS
  'Dispute resolution writer. Closes the dispute, appends a resolution event, emits conflict_resolved reputation events, records the system event. Patched 20260527231000: when the dispute subject is a sanction, the sanction''s status is reconciled out of ''disputed'' regardless of resolution outcome — reversed if outcome.reverse_sanction=true, completed if the linked obligation already settled, otherwise active.';

-- Backfill: sanctions stuck in 'disputed' whose dispute already
-- resolved. Re-running is a no-op thanks to the dispute-status guard.
WITH resolved AS (
  SELECT s.id        AS sanction_id,
         s.obligation_id,
         d.id        AS dispute_id,
         o.status    AS obligation_status
    FROM public.group_sanctions s
    JOIN public.group_disputes  d ON d.id = s.dispute_id
    LEFT JOIN public.group_obligations o ON o.id = s.obligation_id
   WHERE s.status   = 'disputed'
     AND d.status   = 'resolved'
)
UPDATE public.group_sanctions s
   SET status      = CASE WHEN r.obligation_status = 'settled' THEN 'completed' ELSE 'active' END,
       resolved_at = CASE WHEN r.obligation_status = 'settled'
                          THEN COALESCE(s.resolved_at, now())
                          ELSE s.resolved_at
                     END,
       updated_at  = now()
  FROM resolved r
 WHERE s.id = r.sanction_id;
