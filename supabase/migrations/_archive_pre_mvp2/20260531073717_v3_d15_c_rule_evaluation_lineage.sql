-- V3 FASE D.15 — Mig C: rule_evaluation_lineage(rule_id, since)
-- Returns one row per emitted/failed action of every matched evaluation,
-- polymorphic JOIN to the target entity to provide a human label.

BEGIN;

CREATE OR REPLACE FUNCTION public.rule_evaluation_lineage(
  p_rule_id uuid,
  p_since timestamptz DEFAULT NULL
) RETURNS TABLE (
  evaluation_id          uuid,
  rule_version_id        uuid,
  source_event_uuid_id   uuid,
  source_event_type      text,
  occurred_at            timestamptz,
  consequence_kind       text,
  consequence_status     text,
  target_kind            text,
  target_id              uuid,
  target_label           text,
  recipient_user_ids     uuid[],
  error                  text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH evals AS (
    SELECT gre.id              AS evaluation_id,
           gre.rule_version_id,
           gre.source_event_id,
           gre.created_at       AS occurred_at,
           gre.actions_emitted
    FROM public.group_rule_evaluations gre
    JOIN public.group_rule_versions rv ON rv.id = gre.rule_version_id
    WHERE rv.rule_id = p_rule_id
      AND gre.matched = true
      AND (p_since IS NULL OR gre.created_at >= p_since)
  ),
  flat AS (
    SELECT e.evaluation_id,
           e.rule_version_id,
           e.source_event_id        AS source_event_uuid_id,
           ev.event_type            AS source_event_type,
           e.occurred_at,
           a.value->>'kind'         AS consequence_kind,
           a.value->>'status'       AS consequence_status,
           a.value->>'target_kind'  AS target_kind,
           NULLIF(a.value->>'target_id', '')::uuid AS target_id,
           a.value->>'error'        AS error,
           CASE
             WHEN a.value->'recipient_user_ids' IS NULL THEN NULL
             ELSE ARRAY(
               SELECT (jsonb_array_elements_text(a.value->'recipient_user_ids'))::uuid)
           END AS recipient_user_ids
    FROM evals e
    LEFT JOIN public.group_events ev ON ev.uuid_id = e.source_event_id
    CROSS JOIN LATERAL jsonb_array_elements(COALESCE(e.actions_emitted, '[]'::jsonb)) a
    WHERE (a.value->>'status') IN ('emitted','failed')
  )
  SELECT f.evaluation_id,
         f.rule_version_id,
         f.source_event_uuid_id,
         f.source_event_type,
         f.occurred_at,
         f.consequence_kind,
         f.consequence_status,
         f.target_kind,
         f.target_id,
         CASE f.target_kind
           WHEN 'sanction'     THEN (SELECT format('Sanción %s: %s',
                                                   s.sanction_kind, s.reason)
                                       FROM public.group_sanctions s WHERE s.id = f.target_id)
           WHEN 'decision'     THEN (SELECT d.title
                                       FROM public.group_decisions d WHERE d.id = f.target_id)
           WHEN 'obligation'   THEN (SELECT format('%s · %s %s',
                                                   o.obligation_kind,
                                                   o.amount_original::text, o.unit)
                                       FROM public.group_obligations o WHERE o.id = f.target_id)
           WHEN 'resource'     THEN (SELECT format('%s · %s', gr.resource_type, gr.name)
                                       FROM public.group_resources gr WHERE gr.id = f.target_id)
           WHEN 'membership'   THEN (SELECT format('Membership %s (%s)', gm.id, p.display_name)
                                       FROM public.group_memberships gm
                                       LEFT JOIN public.profiles p ON p.id = gm.user_id
                                      WHERE gm.id = f.target_id)
           WHEN 'notification' THEN format('%s recipient(s)',
                                           COALESCE(array_length(f.recipient_user_ids,1), 0))
           ELSE NULL
         END AS target_label,
         f.recipient_user_ids,
         f.error
    FROM flat f
   ORDER BY f.occurred_at DESC;
$$;

REVOKE ALL ON FUNCTION public.rule_evaluation_lineage(uuid, timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rule_evaluation_lineage(uuid, timestamptz) TO authenticated, service_role;

COMMIT;
