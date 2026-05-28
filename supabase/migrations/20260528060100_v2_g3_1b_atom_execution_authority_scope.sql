-- 20260528060100 — V2-G3 sub-slice 1b: doctrine lock-in en el catálogo.
--
-- Founder doctrine (doctrine_rule_engine_g3 punto 3): la distinción
-- sync canonical vs async derived es load-bearing. Hay que tagearla
-- DESDE EL DÍA 1 en los atoms del catálogo, no como follow-up.
--
-- - consequence.issue_sanction → sync canonical · requires sanctions.create
-- - consequence.set_membership_state → sync canonical · requires members.suspend
-- - consequence.send_notification → async derived · sin authority gate
--
-- Triggers cargan scope (group/member/resource) — informativo para
-- G3.1, será load-bearing para el filtrado por subject context en G3.3.

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
