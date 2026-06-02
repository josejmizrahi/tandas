-- D.22 FASE D — Templates faltantes + transitions catalog fix.

INSERT INTO public.decision_templates_catalog
  (template_key, display_name, description, decision_type, reference_kind,
   default_method, default_legitimacy_source, default_threshold_pct, default_quorum_pct,
   execution_mode, metadata)
VALUES
  ('decision.payout',
   'Aprobar payout',
   'Salida de capital del grupo hacia un miembro o externo.',
   'proposal', 'money_movement',
   'supermajority', 'supermajority', 66.66, 50.00,
   'manual',
   jsonb_build_object('action_key','money.payout')),

  ('decision.transaction_reverse',
   'Revertir transacción',
   'Revertir una transacción ya registrada — alto riesgo.',
   'proposal', 'money_movement',
   'supermajority', 'supermajority', 66.66, 50.00,
   'secondary_approval',
   jsonb_build_object('action_key','money.transaction.reverse')),

  ('decision.engine_toggle',
   'Activar/desactivar motor',
   'Encender o apagar el rule engine del grupo — META.',
   'rule_change', 'group',
   'supermajority', 'supermajority', 66.66, 50.00,
   'manual',
   jsonb_build_object('action_key','engine.toggle','constitutional',true)),

  ('decision.governance_change',
   'Cambio constitucional',
   'Cambiar quórum/método/legitimidad — META sobre cómo se decide.',
   'rule_change', 'group',
   'supermajority', 'supermajority', 66.66, 50.00,
   'secondary_approval',
   jsonb_build_object('action_key','group.decision_rules.set','constitutional',true)),

  ('decision.group_boundary',
   'Cambiar política de entrada',
   'Modificar boundary policy del grupo (entry_mode, who_can_invite).',
   'rule_change', 'group',
   'supermajority', 'supermajority', 66.66, 50.00,
   'manual',
   jsonb_build_object('action_key','group.boundary.set','constitutional',true)),

  ('decision.group_visibility',
   'Cambiar visibilidad del grupo',
   'public/private/hidden — afecta quién puede descubrir el grupo.',
   'rule_change', 'group',
   'supermajority', 'supermajority', 66.66, 50.00,
   'manual',
   jsonb_build_object('action_key','group.visibility.set','constitutional',true)),

  ('decision.role_create',
   'Crear rol nuevo',
   'Crear un rol custom — modifica la estructura de autoridad.',
   'rule_change', 'role',
   'supermajority', 'supermajority', 66.66, 50.00,
   'secondary_approval',
   jsonb_build_object('action_key','role.create','constitutional',true)),

  ('decision.role_update',
   'Cambiar permisos de rol',
   'Editar el set de permisos de un rol existente — META.',
   'rule_change', 'role',
   'supermajority', 'supermajority', 66.66, 50.00,
   'secondary_approval',
   jsonb_build_object('action_key','role.update_permissions','constitutional',true)),

  ('decision.mandate_grant',
   'Otorgar mandato',
   'Delegar autoridad a un miembro mediante un mandato.',
   'mandate_grant', 'mandate',
   'majority', 'majority', 50.01, 50.00,
   'manual',
   jsonb_build_object('action_key','mandate.grant')),

  ('decision.norm_promote',
   'Promover norma a regla',
   'Convertir una norma cultural en una regla del grupo.',
   'rule_change', 'norm',
   'majority', 'majority', 50.01, NULL,
   'manual',
   jsonb_build_object('action_key','norm.promote_to_rule')),

  ('decision.resource_unarchive',
   'Restaurar recurso archivado',
   'Revertir el archivado de un recurso.',
   'proposal', 'resource',
   'majority', 'majority', 50.01, NULL,
   'manual',
   jsonb_build_object('action_key','resource.unarchive','action','unarchive')),

  ('decision.dissolution_finalize',
   'Finalizar disolución',
   'Cerrar el grupo definitivamente tras completar liquidación.',
   'dissolution', 'dissolution',
   'supermajority', 'supermajority', 66.66, 50.00,
   'manual',
   jsonb_build_object('action_key','group.dissolve.finalize','constitutional',true,'terminal',true))
ON CONFLICT (template_key) DO NOTHING;

-- Link new templates to their action_catalog rows.
UPDATE public.action_catalog SET default_decision_template_key = 'decision.payout'             WHERE action_key = 'money.payout';
UPDATE public.action_catalog SET default_decision_template_key = 'decision.transaction_reverse' WHERE action_key = 'money.transaction.reverse';
UPDATE public.action_catalog SET default_decision_template_key = 'decision.engine_toggle'       WHERE action_key = 'engine.toggle';
UPDATE public.action_catalog SET default_decision_template_key = 'decision.governance_change'   WHERE action_key = 'group.decision_rules.set';
UPDATE public.action_catalog SET default_decision_template_key = 'decision.group_boundary'      WHERE action_key = 'group.boundary.set';
UPDATE public.action_catalog SET default_decision_template_key = 'decision.group_visibility'    WHERE action_key = 'group.visibility.set';
UPDATE public.action_catalog SET default_decision_template_key = 'decision.role_create'         WHERE action_key = 'role.create';
UPDATE public.action_catalog SET default_decision_template_key = 'decision.role_update'         WHERE action_key = 'role.update_permissions';
UPDATE public.action_catalog SET default_decision_template_key = 'decision.mandate_grant'       WHERE action_key = 'mandate.grant';
UPDATE public.action_catalog SET default_decision_template_key = 'decision.norm_promote'        WHERE action_key = 'norm.promote_to_rule';
UPDATE public.action_catalog SET default_decision_template_key = 'decision.resource_unarchive'  WHERE action_key = 'resource.unarchive';
UPDATE public.action_catalog SET default_decision_template_key = 'decision.dissolution_finalize' WHERE action_key = 'group.dissolve.finalize';

-- Add the deferred invariant.
ALTER TABLE public.action_catalog
  ADD CONSTRAINT action_catalog_decision_template_required
  CHECK (NOT default_requires_decision OR default_decision_template_key IS NOT NULL);

-- Fix membership_state_transitions_catalog drift.
UPDATE public.membership_state_transitions_catalog
   SET requires_decision = true,
       description = description || ' — REQUIRES decision (D.22)'
 WHERE (from_state, to_state) IN (
   ('active','banned'),
   ('active','removed'),
   ('suspended','banned')
 ) AND requires_decision = false;
