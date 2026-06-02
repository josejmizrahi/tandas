-- D.22 FASE B — Action Governance Layer: catalog table + seed
-- Doctrine: doctrine_action_governance_tiers.md
-- Plan:     Plans/Active/D22_FaseB_CatalogProposal.md
-- Founder-approved 2026-05-31 with all 5 residual defaults.

CREATE TABLE IF NOT EXISTS public.action_catalog (
  action_key text PRIMARY KEY,
  domain text NOT NULL CHECK (domain IN (
    'identity','group','membership','resource','money','rule',
    'decision','sanction','dispute','mandate','role','norm',
    'reputation','dissolution','engine','inbox','notification'
  )),
  display_name text NOT NULL,
  description text NOT NULL,
  risk_level text NOT NULL CHECK (risk_level IN (
    'low','medium','high','critical','constitutional'
  )),
  is_constitutional boolean NOT NULL DEFAULT false,
  default_required_permission text REFERENCES public.permissions(key),
  default_requires_decision boolean NOT NULL DEFAULT false,
  default_decision_template_key text REFERENCES public.decision_templates_catalog(template_key),
  founder_can_override boolean NOT NULL DEFAULT false,
  has_threshold boolean NOT NULL DEFAULT false,
  default_threshold_amount numeric,
  default_threshold_unit text,
  executable_rpc text,
  target_kind text,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),

  -- Founder cannot override constitutional actions.
  CONSTRAINT action_catalog_founder_no_constitutional
    CHECK (NOT (is_constitutional AND founder_can_override)),
  -- Threshold metadata coherent.
  CONSTRAINT action_catalog_threshold_consistent
    CHECK (NOT has_threshold OR (default_threshold_amount IS NOT NULL AND default_threshold_unit IS NOT NULL))
  -- NOTE: requires_decision → template_key constraint deferred to FASE D
  --       once the 9 missing templates are seeded.
);

CREATE INDEX IF NOT EXISTS idx_action_catalog_domain ON public.action_catalog (domain);
CREATE INDEX IF NOT EXISTS idx_action_catalog_risk ON public.action_catalog (risk_level);

COMMENT ON TABLE public.action_catalog IS
  'Canonical registry of every governable action in Ruul. Drives resolve_action_governance + request_or_execute_action (D.22 FASE C/E).';

-- ---------- SEED ----------

-- 2.1 Identity (4 actions · self-only)
INSERT INTO public.action_catalog (action_key, domain, display_name, description, risk_level, default_required_permission, default_requires_decision, founder_can_override, executable_rpc, metadata) VALUES
('identity.profile.read',         'identity', 'Ver mi perfil',          'Leer perfil propio',                                 'low',    NULL, false, false, 'my_profile',                       '{"self_only":true}'),
('identity.profile.update',       'identity', 'Editar mi perfil',       'Actualizar display_name/username/avatar/bio',        'low',    NULL, false, false, 'update_my_profile',                '{"self_only":true}'),
('identity.gdpr.delete_export',   'identity', 'Eliminar mi cuenta',     'GDPR delete + data export',                          'medium', NULL, false, false, 'delete_and_export_my_data',        '{"self_only":true}'),
('identity.token.register',       'identity', 'Registrar dispositivo',  'APNs/FCM token register',                            'low',    NULL, false, false, 'register_my_notification_token',   '{"self_only":true}');

-- 2.2 Group (5)
INSERT INTO public.action_catalog (action_key, domain, display_name, description, risk_level, is_constitutional, default_required_permission, default_requires_decision, default_decision_template_key, founder_can_override, executable_rpc, target_kind) VALUES
('group.create',          'group', 'Crear grupo',                  'Crear un nuevo grupo',                              'low',  false, NULL,           false, NULL, false, 'create_group',          NULL),
('group.purpose.set',     'group', 'Editar propósito del grupo',   'Establecer/actualizar propósito',                   'low',  false, 'purpose.set',  false, NULL, true,  'set_group_purpose',     'group'),
('group.purpose.archive', 'group', 'Archivar propósito',           'Archivar propósito activo',                         'low',  false, 'purpose.set',  false, NULL, true,  'archive_group_purpose', 'group'),
('group.visibility.set',  'group', 'Cambiar visibilidad',          'Public/private/hidden — política doctrinal',        'high', true,  'group.update', true,  NULL, false, 'set_group_visibility',  'group'),
('group.boundary.set',    'group', 'Cambiar política de entrada', 'Entry mode + who_can_invite + requires_approval',   'high', true,  'group.update', true,  NULL, false, 'set_group_boundary_policy', 'group');

-- 2.3 Group meta — governance & engine (5)
INSERT INTO public.action_catalog (action_key, domain, display_name, description, risk_level, is_constitutional, default_required_permission, default_requires_decision, default_decision_template_key, founder_can_override, executable_rpc, target_kind) VALUES
('group.decision_rules.set',    'group',   'Editar reglas de decisión', 'Cambiar quórum/método/legitimidad — META',     'constitutional', true,  'roles.manage',   true,  NULL, false, 'set_decision_rules',         'group'),
('engine.toggle',               'engine',  'Activar/desactivar motor',  'Toggle rule engine del grupo',                'high',           true,  'engine.toggle',  true,  NULL, false, 'set_group_engine_active',    'group'),
('group.dissolve.start',        'group',   'Proponer disolución',       'Iniciar proceso de disolución',                'high',           false, 'group.dissolve', false, NULL, true,  'propose_dissolution',        'group'),
('group.dissolve.finalize',     'group',   'Finalizar disolución',      'Cerrar el grupo definitivamente',             'constitutional', true,  'group.dissolve', true,  NULL, false, 'finalize_dissolution',       'dissolution'),
('group.dissolve.record_step',  'group',   'Registrar paso de liquidación', 'Step de liquidación durante dissolution',  'medium',         false, 'group.dissolve', false, NULL, true,  'record_liquidation_step',    'dissolution');

-- 2.4 Membership (12)
INSERT INTO public.action_catalog (action_key, domain, display_name, description, risk_level, default_required_permission, default_requires_decision, default_decision_template_key, founder_can_override, executable_rpc, target_kind, metadata) VALUES
('membership.invite',                  'membership', 'Invitar miembro',                'Crear invitación (email/phone)',                 'low',    'members.invite', false, NULL, true,  'invite_member',                'group',      '{}'),
('membership.invite.revoke',           'membership', 'Revocar invitación',             'Cancelar invitación pendiente',                  'low',    'members.invite', false, NULL, true,  'revoke_invite',                'invite',     '{}'),
('membership.invite.accept',           'membership', 'Aceptar invitación',             'Aceptar con código',                             'low',    NULL,             false, NULL, false, 'accept_invite',                'invite',     '{"self_only":true}'),
('membership.request',                 'membership', 'Solicitar entrada',              'Pedir membresía a grupo público/aprobación',     'low',    NULL,             false, NULL, false, 'request_membership',           'group',      '{"self_only":true}'),
('membership.request.approve',         'membership', 'Aprobar solicitud',              'Approve pending join request',                   'medium', 'members.invite', false, 'decision.membership_accept', true,  'approve_membership_request',   'membership', '{"group_overridable":true}'),
('membership.leave',                   'membership', 'Salir del grupo',                'Self-leave',                                     'low',    NULL,             false, NULL, false, 'leave_group',                  'group',      '{"self_only":true}'),
('membership.pause',                   'membership', 'Pausar membresía',               'Pausa voluntaria o administrativa',              'low',    'members.pause',  false, NULL, true,  'set_membership_state',         'membership', '{"target_state":"paused"}'),
('membership.suspend',                 'membership', 'Suspender miembro',              'Suspensión administrativa (admin-direct)',       'medium', 'members.suspend',false, 'decision.membership_suspend', true,  'set_membership_state',         'membership', '{"target_state":"suspended","group_overridable":true}'),
('membership.ban',                     'membership', 'Expulsar miembro (banned)',      'Expulsión fuerte — requiere decisión',           'high',   'members.remove', true,  'decision.membership_remove', true,  'set_membership_state',         'membership', '{"target_state":"banned"}'),
('membership.remove',                  'membership', 'Remover miembro (reversible)',   'Remoción administrativa reversible',             'high',   'members.remove', true,  'decision.membership_remove_reversible', true, 'set_membership_state',  'membership', '{"target_state":"removed"}'),
('membership.reinstate.from_banned',   'membership', 'Reinstalar baneado',             'banned → active vía decisión',                   'high',   'members.update', true,  'decision.membership_reinstate', false, 'set_membership_state',         'membership', '{"target_state":"active","from_state":"banned"}'),
('membership.confirm_provisional',     'membership', 'Confirmar membresía provisional','Provisional → active',                           'low',    'members.update', false, NULL, true,  'confirm_provisional',          'membership', '{}');

-- 2.5 Resource (27)
INSERT INTO public.action_catalog (action_key, domain, display_name, description, risk_level, default_required_permission, default_requires_decision, default_decision_template_key, founder_can_override, has_threshold, default_threshold_amount, default_threshold_unit, executable_rpc, target_kind) VALUES
('resource.create',              'resource', 'Crear recurso',           'Crear cualquier resource_type',          'low',    'resources.create',       false, NULL, true,  false, NULL,   NULL, 'create_group_resource',         'group'),
('resource.update',              'resource', 'Editar recurso',          'Cambiar name/description/visibility/metadata', 'low', 'resources.update',  false, NULL, true,  false, NULL,   NULL, 'update_resource',               'resource'),
('resource.archive',             'resource', 'Archivar recurso',        'Soft-archive con decisión',              'high',   'resources.archive',      true,  'decision.resource_archive', true, false, NULL, NULL, 'archive_resource',              'resource'),
('resource.unarchive',           'resource', 'Restaurar recurso',       'Revertir archive',                       'medium', 'resources.archive',      true,  NULL, true,  false, NULL,   NULL, 'revert_archive_resource',       'resource'),
('resource.transfer',            'resource', 'Transferir propiedad',    'Cambiar owner/ownership_kind',           'high',   'resources.transfer',     true,  'decision.resource_transfer', true, false, NULL, NULL, 'set_resource_ownership',        'resource'),
('resource.value.update',        'resource', 'Actualizar valor',        'Update con threshold',                   'medium', 'resources.update_value', false, NULL, true,  true,  10000, 'MXN', 'update_resource_value',         'resource'),
('resource.valuation.record',    'resource', 'Registrar valuación',     'Record asset valuation event',           'low',    'resources.update_value', false, NULL, true,  false, NULL,   NULL, 'record_asset_valuation',        'resource'),
('resource.event.lifecycle',     'resource', 'Registrar evento ciclo',  'Lifecycle event genérico',               'low',    'resources.record_event', false, NULL, true,  false, NULL,   NULL, 'record_resource_lifecycle_event','resource'),
('resource.custodian.assign',    'resource', 'Asignar custodio',        'Asset custodian assign',                 'low',    'resources.update',       false, NULL, true,  false, NULL,   NULL, 'assign_asset_custodian',        'resource'),
('resource.custodian.release',   'resource', 'Liberar custodio',        'Asset custodian release',                'low',    'resources.update',       false, NULL, true,  false, NULL,   NULL, 'release_asset_custodian',       'resource'),
('resource.condition.mark',      'resource', 'Marcar condición',        'Asset condition (good/damaged/etc)',     'low',    'resources.record_event', false, NULL, true,  false, NULL,   NULL, 'mark_asset_condition',          'resource'),
('resource.book',                'resource', 'Reservar recurso',        'Booking',                                'low',    'bookings.create',        false, NULL, true,  false, NULL,   NULL, 'book_resource',                 'resource'),
('resource.book.cancel',         'resource', 'Cancelar reserva',        'Cancel booking',                         'low',    'bookings.cancel',        false, NULL, true,  false, NULL,   NULL, 'cancel_booking',                'booking'),
('resource.right.grant',         'resource', 'Otorgar derecho',         'Grant right (use/admin/transfer)',       'medium', 'resources.update',       false, NULL, true,  false, NULL,   NULL, 'grant_right',                   'resource'),
('resource.right.transfer',      'resource', 'Transferir derecho',      'Transfer right',                         'medium', 'resources.update',       false, NULL, true,  false, NULL,   NULL, 'transfer_right',                'resource'),
('resource.right.revoke',        'resource', 'Revocar derecho',         'Revoke right',                           'medium', 'resources.update',       false, NULL, true,  false, NULL,   NULL, 'revoke_right',                  'resource'),
('resource.slot.assign',         'resource', 'Asignar slot',            'Slot assign (rotation/turn)',            'low',    'resources.update',       false, NULL, true,  false, NULL,   NULL, 'assign_slot',                   'resource'),
('resource.slot.release',        'resource', 'Liberar slot',            'Slot release',                           'low',    'resources.update',       false, NULL, true,  false, NULL,   NULL, 'release_slot',                  'resource'),
('resource.fund.lock',           'resource', 'Bloquear fondo',          'Lock common fund',                       'medium', 'resources.update',       false, NULL, true,  false, NULL,   NULL, 'lock_fund',                     'resource'),
('resource.fund.unlock',         'resource', 'Desbloquear fondo',       'Unlock common fund',                     'medium', 'resources.update',       false, NULL, true,  false, NULL,   NULL, 'unlock_fund',                   'resource'),
('resource.fund.set_threshold',  'resource', 'Set fund threshold',      'Define target del fondo',                'low',    'resources.update',       false, NULL, true,  false, NULL,   NULL, 'set_fund_threshold',            'resource'),
('resource.capability.enable',   'resource', 'Habilitar capacidad',     'Enable resource capability',             'low',    'resources.update',       false, NULL, true,  false, NULL,   NULL, 'enable_resource_capability',    'resource'),
('resource.capability.disable',  'resource', 'Deshabilitar capacidad',  'Disable resource capability',            'low',    'resources.update',       false, NULL, true,  false, NULL,   NULL, 'disable_resource_capability',   'resource'),
('resource.rsvp.submit',         'resource', 'Responder RSVP',          'RSVP self',                              'low',    'rsvp.submit',            false, NULL, false, false, NULL,   NULL, 'submit_rsvp',                   'resource'),
('resource.checkin.submit',      'resource', 'Check-in',                'Self check-in',                          'low',    'check_in.submit',        false, NULL, false, false, NULL,   NULL, 'submit_check_in',               'resource'),
('resource.series.create',       'resource', 'Crear serie',             'Resource series (ritual/cadence)',       'low',    'resources.create',       false, NULL, true,  false, NULL,   NULL, 'create_resource_series',        'group'),
('resource.series.update',       'resource', 'Editar serie',            'Update resource series',                 'low',    'resources.update',       false, NULL, true,  false, NULL,   NULL, 'update_resource_series',        'series');

-- 2.6 Money (16)
INSERT INTO public.action_catalog (action_key, domain, display_name, description, risk_level, default_required_permission, default_requires_decision, default_decision_template_key, founder_can_override, has_threshold, default_threshold_amount, default_threshold_unit, executable_rpc, target_kind) VALUES
('money.expense.record',           'money', 'Registrar gasto',             'Record expense con threshold',      'medium', 'expense.record',            false, 'decision.expense_approval', true,  true,  10000, 'MXN', 'record_expense',           'group'),
('money.settlement.record',        'money', 'Registrar pago',              'Settlement entre miembros',         'low',    'settlement.record',         false, NULL,                        true,  false, NULL,  NULL,  'record_settlement',        'group'),
('money.contribution.record',      'money', 'Registrar contribución',      'Record contribution',               'low',    'contribution.record',       false, NULL,                        true,  false, NULL,  NULL,  'record_contribution',      'group'),
('money.contribution.log',         'money', 'Log contribución',            'Log contribution (read-side)',      'low',    'contribution.record',       false, NULL,                        true,  false, NULL,  NULL,  'log_contribution',         'group'),
('money.contribution.verify',      'money', 'Verificar contribución',      'Verify/reject contribution',        'low',    'contribution.verify',       false, NULL,                        true,  false, NULL,  NULL,  'verify_contribution',      'contribution'),
('money.contribution.non_monetary','money', 'Contribución no monetaria',   'Record non-monetary contribution',  'low',    'contribution.record',       false, NULL,                        true,  false, NULL,  NULL,  'record_non_monetary_contribution', 'group'),
('money.pool_charge.create',       'money', 'Crear cuota/cobro',           'Pool charge con threshold',         'medium', 'pool_charge.record',        false, 'decision.expense_approval', true,  true,  5000,  'MXN', 'record_pool_charge',       'group'),
('money.pool_charge.batch',        'money', 'Cuotas masivas',              'Pool charge batch',                 'medium', 'pool_charge.record',        false, 'decision.expense_approval', true,  true,  5000,  'MXN', 'record_pool_charge_batch', 'group'),
('money.payout',                   'money', 'Payout grupal',               'Salida de capital — requiere decisión', 'high', 'payout.record',          true,  NULL,                        true,  true,  0,     'MXN', 'record_payout',            'group'),
('money.peer_obligation.record',   'money', 'Obligación peer',             'Record peer obligation',            'low',    NULL,                        false, NULL,                        true,  false, NULL,  NULL,  'record_peer_obligation',   'group'),
('money.transaction.reverse',      'money', 'Revertir transacción',        'Reverse transaction — alto riesgo', 'high',   'money.transaction.reverse', true,  NULL,                        true,  false, NULL,  NULL,  'reverse_transaction',      'transaction'),
('money.sanction.issue',           'money', 'Emitir sanción',              'Issue manual sanction',             'medium', 'sanctions.create',          false, NULL,                        true,  false, NULL,  NULL,  'issue_sanction',           'group'),
('money.sanction.pay',             'money', 'Pagar sanción',               'Pay sanction self',                 'low',    NULL,                        false, NULL,                        false, false, NULL,  NULL,  'pay_sanction',             'sanction'),
('money.sanction.update_status',   'money', 'Cambiar status sanción',      'Update sanction status',            'medium', 'sanctions.update',          false, NULL,                        true,  false, NULL,  NULL,  'update_sanction_status',   'sanction'),
('money.payment_plan.propose',     'money', 'Proponer plan de pago',       'Propose sanction payment plan',     'low',    NULL,                        false, NULL,                        true,  false, NULL,  NULL,  'propose_sanction_payment_plan', 'sanction'),
('money.payment_plan.cancel',      'money', 'Cancelar plan de pago',       'Cancel sanction payment plan',      'low',    NULL,                        false, NULL,                        true,  false, NULL,  NULL,  'cancel_sanction_payment_plan',  'payment_plan');

-- 2.7 Rule (6)
INSERT INTO public.action_catalog (action_key, domain, display_name, description, risk_level, default_required_permission, default_requires_decision, default_decision_template_key, founder_can_override, executable_rpc, target_kind, metadata) VALUES
('rule.propose',        'rule', 'Proponer regla',          'Propose rule (no version)',     'low',    'rules.create',  false, NULL, true,  'propose_rule',          'group', '{}'),
('rule.create_text',    'rule', 'Crear regla de texto',    'Text rule',                     'low',    'rules.create',  false, NULL, true,  'create_text_rule',      'group', '{}'),
('rule.create_engine',  'rule', 'Crear regla de motor',    'Engine rule (shape + cond)',    'medium', 'rules.create',  false, NULL, true,  'create_engine_rule',    'group', '{}'),
('rule.publish',        'rule', 'Publicar versión',        'Publish rule version',          'high',   'rules.publish', true,  'decision.rule_change', true, 'publish_rule_version',  'rule',  '{"action":"publish"}'),
('rule.archive',        'rule', 'Archivar regla',          'Archive rule',                  'medium', 'rules.archive', true,  'decision.rule_change', true, 'archive_rule',          'rule',  '{"action":"archive"}'),
('rule.activate',       'rule', 'Reactivar regla',         'Activate archived rule',        'medium', 'rules.archive', true,  'decision.rule_change', true, 'archive_rule',          'rule',  '{"action":"activate"}');

-- 2.8 Decision meta (7)
INSERT INTO public.action_catalog (action_key, domain, display_name, description, risk_level, default_required_permission, default_requires_decision, founder_can_override, executable_rpc, target_kind) VALUES
('decision.create',          'decision', 'Abrir decisión',     'Start vote',           'low',    'decisions.create',  false, false, 'start_vote',             'group'),
('decision.vote',            'decision', 'Votar',              'Cast vote',            'low',    'decisions.vote',    false, false, 'cast_vote',              'decision'),
('decision.vote.ranked',     'decision', 'Voto ranked',        'Cast ranked vote',     'low',    'decisions.vote',    false, false, 'cast_ranked_vote',       'decision'),
('decision.finalize',        'decision', 'Finalizar votación', 'Finalize vote',        'low',    'decisions.resolve', false, false, 'finalize_vote',          'decision'),
('decision.execute',         'decision', 'Ejecutar decisión',  'Execute passed decision','medium','decisions.execute', false, false, 'execute_decision',       'decision'),
('decision.cancel',          'decision', 'Cancelar decisión',  'Cancel vote',          'low',    'decisions.resolve', false, false, 'cancel_vote',            'decision'),
('decision.template.apply',  'decision', 'Aplicar template',   'Apply decision template','low',  'decisions.create',  false, false, 'apply_decision_template','decision');

-- 2.9 Dispute (5)
INSERT INTO public.action_catalog (action_key, domain, display_name, description, risk_level, default_required_permission, default_requires_decision, founder_can_override, executable_rpc, target_kind) VALUES
('dispute.open',              'dispute', 'Abrir disputa',         'Open dispute',                'low',    'disputes.open',    false, false, 'open_dispute',              'group'),
('dispute.event.append',      'dispute', 'Evento de disputa',     'Append dispute event',        'low',    NULL,               false, false, 'append_dispute_event',      'dispute'),
('dispute.mediator.assign',   'dispute', 'Asignar mediador',      'Assign mediator',             'low',    'disputes.mediate', false, true,  'assign_mediator',           'dispute'),
('dispute.resolve',           'dispute', 'Resolver disputa',      'Record dispute resolution',   'medium', 'disputes.resolve', false, true,  'record_dispute_resolution', 'dispute'),
('dispute.escalate_to_vote',  'dispute', 'Escalar a votación',    'Escalate dispute to vote',    'medium', NULL,               false, false, 'escalate_dispute_to_vote',  'dispute');

-- 2.10 Sanction-related (1 extra, already in money domain)
INSERT INTO public.action_catalog (action_key, domain, display_name, description, risk_level, default_required_permission, default_requires_decision, founder_can_override, executable_rpc, target_kind) VALUES
('sanction.dispute',  'sanction', 'Disputar sanción', 'Dispute issued sanction', 'medium', 'sanctions.dispute', false, false, 'dispute_sanction', 'sanction');

-- 2.11 Mandate (3)
INSERT INTO public.action_catalog (action_key, domain, display_name, description, risk_level, default_required_permission, default_requires_decision, default_decision_template_key, founder_can_override, executable_rpc, target_kind) VALUES
('mandate.grant',   'mandate', 'Otorgar mandato',     'Grant mandate — decisión',  'high',   'mandates.grant',  true,  NULL, true, 'grant_mandate',     'group'),
('mandate.revoke',  'mandate', 'Revocar mandato',     'Revoke mandate (dual)',     'medium', 'mandates.revoke', false, NULL, true, 'revoke_mandate',    'mandate'),
('mandate.report',  'mandate', 'Reportar sobre mandato','Mandate report',          'low',    NULL,              false, NULL, true, 'report_on_mandate', 'mandate');

-- 2.12 Role (4)
INSERT INTO public.action_catalog (action_key, domain, display_name, description, risk_level, is_constitutional, default_required_permission, default_requires_decision, default_decision_template_key, founder_can_override, executable_rpc, target_kind, metadata) VALUES
('role.create',              'role', 'Crear rol',                'Create custom role — META',                    'constitutional', true,  'roles.manage', true,  NULL, false, 'create_custom_role',       'group',  '{}'),
('role.update_permissions',  'role', 'Cambiar permisos de rol',  'Update role permissions — META',               'constitutional', true,  'roles.manage', true,  NULL, false, 'update_role_permissions',  'role',   '{}'),
('role.assign',              'role', 'Asignar rol',              'Assign role (tier-aware en resolver)',         'medium',         false, 'roles.manage', false, NULL, true,  'assign_role_to_member',    'membership', '{"tier_aware":true,"privileged_roles":["founder","admin"]}'),
('role.revoke',              'role', 'Revocar rol',              'Revoke role (tier-aware en resolver)',         'medium',         false, 'roles.manage', false, NULL, true,  'revoke_role_from_member',  'membership', '{"tier_aware":true,"privileged_roles":["founder","admin"]}');

-- 2.13 Norm (4)
INSERT INTO public.action_catalog (action_key, domain, display_name, description, risk_level, default_required_permission, default_requires_decision, default_decision_template_key, founder_can_override, executable_rpc, target_kind) VALUES
('norm.propose',          'norm', 'Proponer norma',         'Propose cultural norm',     'low',    'culture.propose', false, NULL, true, 'propose_cultural_norm', 'group'),
('norm.endorse',          'norm', 'Endorsar norma',         'Endorse norm',              'low',    'culture.endorse', false, NULL, true, 'endorse_cultural_norm', 'norm'),
('norm.retire',           'norm', 'Retirar norma',          'Retire cultural norm',      'low',    NULL,              false, NULL, true, 'retire_cultural_norm',  'norm'),
('norm.promote_to_rule',  'norm', 'Promover norma a regla', 'Norm → rule promotion',     'medium', 'rules.create',    true,  NULL, true, 'promote_norm_to_rule',  'norm');

-- 2.14 Reputation (2)
INSERT INTO public.action_catalog (action_key, domain, display_name, description, risk_level, default_required_permission, default_requires_decision, founder_can_override, executable_rpc, target_kind) VALUES
('reputation.event.record',   'reputation', 'Registrar reputación', 'Record reputation event',    'low', 'reputation.record', false, true, 'record_reputation_event',  'membership'),
('reputation.event.retract',  'reputation', 'Retractar reputación', 'Retract reputation event',   'low', NULL,                false, true, 'retract_reputation_event', 'reputation_event');

-- 2.15 Inbox / Notifications (4 · self-only)
INSERT INTO public.action_catalog (action_key, domain, display_name, description, risk_level, default_required_permission, default_requires_decision, founder_can_override, executable_rpc, metadata) VALUES
('inbox.mark_read',              'inbox',        'Marcar leído',             'Mark inbox item read',        'low', NULL, false, false, 'mark_inbox_read',              '{"self_only":true}'),
('inbox.mark_all_read',          'inbox',        'Marcar todo leído',        'Mark all inbox read',         'low', NULL, false, false, 'mark_all_inbox_read',          '{"self_only":true}'),
('notification.preference.set',  'notification', 'Editar preferencia notif', 'Set notification preference', 'low', NULL, false, false, 'set_notification_preference',  '{"self_only":true}'),
('notification.token.register',  'notification', 'Registrar token push',     'Register APNs/FCM token',     'low', NULL, false, false, 'register_my_notification_token','{"self_only":true}');
