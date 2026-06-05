-- ============================================================================
-- R.5A.B.5a — RESOURCE_ACTION_CATALOG expanded (additive, ~70 nuevas acciones)
-- ============================================================================
-- 1. Agrega cols: execution_mode (execute|request_decision), decision_template_key,
--    metadata jsonb, dangerous, confirmation_required.
-- 2. Seedea ~70 acciones nuevas alineadas con founder spec sec 15.
-- 3. Cero impacto runtime: ningun RPC vivo lee execution_mode todavia (B.8 dispatcher
--    sera el primer consumer). Las 20 acciones existentes mantienen comportamiento.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. ALTER: cols nuevas con defaults seguros
-- ----------------------------------------------------------------------------
alter table public.resource_action_catalog
  add column execution_mode text not null default 'execute'
    check (execution_mode in ('execute', 'request_decision'));

alter table public.resource_action_catalog
  add column decision_template_key text;

alter table public.resource_action_catalog
  add column metadata jsonb not null default '{}';

alter table public.resource_action_catalog
  add column dangerous boolean not null default false;

alter table public.resource_action_catalog
  add column confirmation_required boolean not null default false;

comment on column public.resource_action_catalog.execution_mode is
  'R.5A.B.5a: execute = ejecuta directo via dispatcher (B.8). request_decision = crea decision con decision_template_key, ejecuta al cerrar.';
comment on column public.resource_action_catalog.decision_template_key is
  'R.5A.B.5a: si execution_mode=request_decision, identifica el template a usar en create_decision.';
comment on column public.resource_action_catalog.dangerous is
  'R.5A.B.5a: marca acciones destructivas (archivar/transferir/cancelar). iOS pinta rojo / agrupa en danger zone.';
comment on column public.resource_action_catalog.confirmation_required is
  'R.5A.B.5a: iOS DEBE pedir confirmacion antes de ejecutar.';

-- ----------------------------------------------------------------------------
-- 2. Seed: 70 acciones nuevas (founder spec sec 15)
-- ----------------------------------------------------------------------------
insert into public.resource_action_catalog
  (action_key, display_name, required_capability, required_rights, ui_section, sort_order,
   execution_mode, decision_template_key, dangerous, confirmation_required) values
  -- resource ops (15)
  ('edit_resource',            'Editar',                       null,                    array['MANAGE','OWN'],                       'settings',     1,   'execute', null, false, false),
  ('archive_resource',         'Archivar',                     null,                    array['MANAGE','OWN'],                       'settings',     950, 'execute', null, true,  true),
  ('restore_resource',         'Restaurar',                    null,                    array['MANAGE','OWN'],                       'settings',     951, 'execute', null, false, true),
  ('view_activity',            'Ver actividad',                'auditable',             array['VIEW','USE','MANAGE','OWN','GOVERN'], 'activity',     200, 'execute', null, false, false),
  ('transfer_resource',        'Transferir',                   'transferable',          array['OWN'],                                'settings',     920, 'execute', null, true,  true),
  ('link_document',            'Vincular documento',           'documentable',          array['MANAGE','OWN'],                       'documents',    55,  'execute', null, false, false),
  ('upload_document',          'Subir documento',              'documentable',          array['MANAGE','OWN'],                       'documents',    56,  'execute', null, false, false),
  ('link_existing_resource',   'Vincular recurso',             null,                    array['MANAGE','OWN'],                       'relations',    91,  'execute', null, false, false),
  ('unlink_resource',          'Desvincular recurso',          null,                    array['MANAGE','OWN'],                       'relations',    92,  'execute', null, true,  true),
  ('request_transfer',         'Solicitar transferencia',      'transferable',          array['USE','OWN'],                          'settings',     921, 'request_decision', 'resource_transfer', false, false),
  ('approve_transfer',         'Aprobar transferencia',        'transferable',          array['OWN'],                                'settings',     922, 'execute', null, false, true),
  ('transfer_ownership',       'Transferir propiedad',         'ownership_trackable',   array['OWN'],                                'settings',     923, 'request_decision', 'resource_transfer', true, true),
  ('transfer_custody',         'Transferir custodia',          'custodiable',           array['MANAGE','OWN'],                       'custody',      71,  'execute', null, false, true),
  ('return_resource',          'Devolver',                     'custodiable',           array['USE','MANAGE','OWN'],                 'custody',      72,  'execute', null, false, false),
  ('report_issue',             'Reportar problema',            null,                    array['VIEW','USE','MANAGE','OWN'],          'condition',    67,  'execute', null, false, false),

  -- maintenance / condition / valuation (4)
  ('record_maintenance',       'Registrar mantenimiento',      'maintainable',          array['MANAGE','OWN'],                       'maintenance',  65,  'execute', null, false, false),
  ('update_condition',         'Actualizar condicion',         'condition_trackable',   array['MANAGE','OWN'],                       'condition',    66,  'execute', null, false, false),
  ('update_valuation',         'Actualizar valuacion',         null,                    array['MANAGE','OWN'],                       'valuation',    93,  'execute', null, false, false),
  ('record_damage',            'Registrar dano',               'condition_trackable',   array['MANAGE','OWN'],                       'condition',    68,  'execute', null, true,  true),

  -- rights (1 nueva, grant_right existente)
  ('revoke_right',             'Revocar derecho',              null,                    array['MANAGE','OWN'],                       'rights',       91,  'execute', null, true,  true),

  -- reservations (10)
  ('view_availability',        'Ver disponibilidad',           'reservable',            array['VIEW','USE','MANAGE','OWN','GOVERN'], 'reservations', 9,   'execute', null, false, false),
  ('create_reservation',       'Crear reserva',                'reservable',            array['USE','MANAGE','OWN'],                 'reservations', 13,  'execute', null, false, false),
  ('approve_reservation',      'Aprobar reserva',              'reservable',            array['MANAGE','OWN','GOVERN'],              'reservations', 14,  'execute', null, false, false),
  ('reject_reservation',       'Rechazar reserva',             'reservable',            array['MANAGE','OWN','GOVERN'],              'reservations', 15,  'execute', null, true,  true),
  ('cancel_reservation',       'Cancelar reserva',             'reservable',            array['USE','MANAGE','OWN'],                 'reservations', 16,  'execute', null, true,  true),
  ('complete_reservation',     'Completar reserva',            'reservable',            array['MANAGE','OWN'],                       'reservations', 17,  'execute', null, false, false),
  ('join_waitlist',            'Unirse a lista de espera',     'reservable',            array['USE'],                                'reservations', 18,  'execute', null, false, false),
  ('resolve_reservation_conflict','Resolver conflicto',        'reservable',            array['MANAGE','OWN','GOVERN'],              'reservations', 19,  'execute', null, false, true),
  ('block_time',               'Bloquear horario',             'reservable',            array['MANAGE','OWN'],                       'availability', 8,   'execute', null, false, false),
  ('unblock_time',             'Desbloquear horario',          'reservable',            array['MANAGE','OWN'],                       'availability', 9,   'execute', null, false, false),

  -- money (7)
  ('record_payment',           'Registrar pago',               'payable',               array['MANAGE','OWN'],                       'payments',     73,  'execute', null, false, false),
  ('record_iou',               'Registrar IOU',                'payable',               array['MANAGE','OWN'],                       'ious',         32,  'execute', null, false, false),
  ('record_charge',            'Registrar cargo',              'chargeable',            array['MANAGE','OWN'],                       'movements',    21,  'execute', null, false, false),
  ('record_payout',            'Registrar pago de salida',     'payable',               array['MANAGE','OWN'],                       'payments',     74,  'execute', null, false, true),
  ('finalize_settlement_batch','Finalizar liquidacion',        'settleable',            array['MANAGE','OWN','GOVERN'],              'settlements',  33,  'execute', null, false, true),
  ('void_transaction',         'Anular transaccion',           'auditable',             array['MANAGE','OWN','GOVERN'],              'movements',    24,  'execute', null, true,  true),
  ('export_statement',         'Exportar estado de cuenta',    'auditable',             array['VIEW','MANAGE','OWN','GOVERN'],       'movements',    25,  'execute', null, false, false),

  -- events (11)
  ('rsvp_event',               'RSVP',                         'schedulable',           array['VIEW','USE','MANAGE','OWN'],          'rsvp',         38,  'execute', null, false, false),
  ('invite_participant',       'Invitar participante',         'schedulable',           array['MANAGE','OWN','GOVERN'],              'attendees',    36,  'execute', null, false, false),
  ('check_in_participant',     'Check-in participante',        'schedulable',           array['MANAGE','OWN'],                       'attendees',    37,  'execute', null, false, false),
  ('mark_no_show',             'Marcar como no asistio',       'schedulable',           array['MANAGE','OWN'],                       'attendees',    38,  'execute', null, false, true),
  ('change_host',              'Cambiar anfitrion',            'schedulable',           array['MANAGE','OWN'],                       'host',         39,  'execute', null, false, true),
  ('preview_next_host',        'Preview siguiente anfitrion',  'recurring',             array['VIEW','MANAGE','OWN'],                'host',         40,  'execute', null, false, false),
  ('set_next_host',            'Fijar siguiente anfitrion',    'recurring',             array['MANAGE','OWN'],                       'host',         41,  'execute', null, false, true),
  ('close_event',              'Cerrar evento',                'closeable',             array['MANAGE','OWN'],                       'settings',     953, 'execute', null, false, true),
  ('cancel_event',             'Cancelar evento',              'schedulable',           array['MANAGE','OWN','GOVERN'],              'settings',     954, 'execute', null, true,  true),
  ('reopen_event',             'Reabrir evento',               'closeable',             array['MANAGE','OWN','GOVERN'],              'settings',     955, 'execute', null, false, true),
  ('record_event_expense',     'Registrar gasto del evento',   'payable',               array['MANAGE','OWN'],                       'expenses',     29,  'execute', null, false, false),

  -- documents (5)
  ('upload_new_version',       'Subir nueva version',          'versionable',           array['MANAGE','OWN'],                       'versions',     59,  'execute', null, false, false),
  ('request_approval',         'Solicitar aprobacion',         'approvable',            array['USE','MANAGE','OWN'],                 'approvals',    61,  'execute', null, false, false),
  ('reject_document',          'Rechazar documento',           'approvable',            array['MANAGE','OWN','GOVERN'],              'approvals',    62,  'execute', null, true,  true),
  ('sign_document',            'Firmar documento',             'signable',              array['MANAGE','OWN'],                       'signatures',   63,  'execute', null, false, true),
  ('archive_document',         'Archivar documento',           'documentable',          array['MANAGE','OWN'],                       'documents',    57,  'execute', null, true,  true),

  -- obligations (7)
  ('accept_obligation',        'Aceptar obligacion',           'payable',               array['MANAGE','OWN'],                       'obligations',  54,  'execute', null, false, false),
  ('complete_obligation',      'Completar obligacion',         'payable',               array['MANAGE','OWN'],                       'obligations',  55,  'execute', null, false, true),
  ('dispute_obligation',       'Disputar',                     'disputable',            array['VIEW','USE','MANAGE','OWN'],          'disputes',     75,  'execute', null, false, true),
  ('forgive_obligation',       'Condonar',                     'payable',               array['MANAGE','OWN'],                       'obligations',  56,  'execute', null, true,  true),
  ('extend_due_date',          'Extender fecha limite',        'expirable',             array['MANAGE','OWN'],                       'obligations',  57,  'execute', null, false, false),
  ('convert_to_settlement',    'Convertir a liquidacion',      'settleable',            array['MANAGE','OWN','GOVERN'],              'settlements',  34,  'execute', null, false, true),
  ('cancel_obligation',        'Cancelar obligacion',          'payable',               array['MANAGE','OWN','GOVERN'],              'obligations',  58,  'execute', null, true,  true),

  -- real estate (6)
  ('record_property_expense',  'Registrar gasto inmueble',     'payable',               array['MANAGE','OWN'],                       'expenses',     30,  'execute', null, false, false),
  ('record_insurance',         'Registrar seguro',             'insurable',             array['MANAGE','OWN'],                       'insurance',    89,  'execute', null, false, false),
  ('record_tax_payment',       'Registrar pago impuestos',     'taxable',               array['MANAGE','OWN'],                       'taxes',        91,  'execute', null, false, false),
  ('record_lease_income',      'Registrar ingreso renta',      'income_generating',     array['MANAGE','OWN'],                       'income',       95,  'execute', null, false, false),
  ('create_lease',             'Crear arrendamiento',          'leasable',              array['MANAGE','OWN'],                       'leases',       97,  'execute', null, false, false),
  ('terminate_lease',          'Terminar arrendamiento',       'leasable',              array['MANAGE','OWN'],                       'leases',       98,  'execute', null, true,  true),

  -- inventory (4)
  ('adjust_stock',             'Ajustar stock',                'inventory_tracked',     array['MANAGE','OWN'],                       'stock',        85,  'execute', null, false, false),
  ('transfer_stock',           'Transferir stock',             'inventory_tracked',     array['MANAGE','OWN'],                       'inventory_movements', 86, 'execute', null, false, true),
  ('consume_item',             'Consumir item',                'inventory_tracked',     array['USE','MANAGE','OWN'],                 'inventory_movements', 87, 'execute', null, false, false),
  ('record_purchase',          'Registrar compra',             'inventory_tracked',     array['MANAGE','OWN'],                       'inventory_movements', 88, 'execute', null, false, false)
on conflict (action_key) do nothing;

-- ----------------------------------------------------------------------------
-- 3. Backfill: marcar acciones EXISTENTES dangerous donde aplica
-- ----------------------------------------------------------------------------
update public.resource_action_catalog
   set dangerous = true, confirmation_required = true
 where action_key in ('transfer_interest')
   and not dangerous;
