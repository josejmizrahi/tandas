-- V2-G3.1b: lock the institutional-policy metadata into the atom catalog
-- BEFORE iOS or evaluation code reads it, so the sync/async + authority
-- + scope distinctions don't need to be retrofitted later.
--
-- consequence atoms now carry:
--   execution: 'sync'|'async'   — sync = canonical (touches state in the same
--     tx as the trigger event); async = derived (outbox / notification).
--   authority_required: permission key | null — what perm the evaluator
--     must already hold to emit this consequence. null = no perm gate
--     (derived side effect).
--
-- trigger atoms now carry:
--   scope: 'group'|'member'|'resource' — what the policy is bounded to.
--     Informational for G3.1; G3.3 evaluator uses it to filter rules by
--     subject context.

UPDATE public.rule_shapes_catalog
   SET schema = schema || jsonb_build_object(
     'execution', 'sync',
     'authority_required', 'sanctions.create'
   )
 WHERE shape_key = 'consequence.issue_sanction';

UPDATE public.rule_shapes_catalog
   SET schema = schema || jsonb_build_object(
     'execution', 'sync',
     'authority_required', 'members.suspend'
   )
 WHERE shape_key = 'consequence.set_membership_state';

UPDATE public.rule_shapes_catalog
   SET schema = schema || jsonb_build_object(
     'execution', 'async',
     'authority_required', to_jsonb(null::text)
   )
 WHERE shape_key = 'consequence.send_notification';

UPDATE public.rule_shapes_catalog
   SET schema = schema || jsonb_build_object('scope', 'group')
 WHERE shape_key IN ('trigger.money.expense_recorded', 'trigger.decision.finalized');

UPDATE public.rule_shapes_catalog
   SET schema = schema || jsonb_build_object('scope', 'member')
 WHERE shape_key = 'trigger.member.state_changed';
