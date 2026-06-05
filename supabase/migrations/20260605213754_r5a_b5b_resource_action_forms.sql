-- ============================================================================
-- R.5A.B.5b — RESOURCE_ACTION_FORMS (form_schema JSON for the 90 actions)
-- ============================================================================
-- Dialect simple (NO JSON Schema completo): {fields:[{key,label,type,required,...}],
-- submit_label}. Tipos: text, multiline, number, currency, date, datetime,
-- boolean, picker, actor_ref, resource_ref, file_url.
--
-- confirmation_required + dangerous: NULLABLE (override del catalog row).
-- coalesce(form.x, catalog.x) en B.6 descriptor.
--
-- Cero impacto runtime: nada lee resource_action_forms todavia. B.8 dispatcher
-- usara form_schema para validar payload.
-- ============================================================================

create table public.resource_action_forms (
  action_key text primary key references public.resource_action_catalog(action_key) on update cascade on delete cascade,
  form_schema jsonb not null default '{}',
  default_payload jsonb not null default '{}',
  confirmation_required boolean,
  dangerous boolean,
  metadata jsonb not null default '{}',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.resource_action_forms is
  'R.5A.B.5b: JSON Schema (simplificado) por action. confirmation_required+dangerous son NULLABLE override del catalog. coalesce(form, catalog) en descriptor.';

create trigger trg_resource_action_forms_touch
  before update on public.resource_action_forms
  for each row execute function public.touch_updated_at();

alter table public.resource_action_forms enable row level security;
create policy "resource_action_forms_read_all"
  on public.resource_action_forms for select to authenticated using (true);
grant select on public.resource_action_forms to authenticated;

-- ----------------------------------------------------------------------------
-- Seed: form_schema por action
-- ----------------------------------------------------------------------------
-- Convention: {"fields":[...],"submit_label":"..."}. No-payload actions get "{}".
insert into public.resource_action_forms (action_key, form_schema, default_payload) values

  -- reservations
  ('reserve_resource',
   '{"fields":[
     {"key":"starts_at","label":"Inicio","type":"datetime","required":true},
     {"key":"ends_at","label":"Fin","type":"datetime","required":true},
     {"key":"purpose","label":"Motivo","type":"multiline","required":false}
   ],"submit_label":"Reservar"}'::jsonb,
   '{"starts_at":null,"ends_at":null,"purpose":null}'::jsonb),
  ('create_reservation',
   '{"fields":[
     {"key":"starts_at","label":"Inicio","type":"datetime","required":true},
     {"key":"ends_at","label":"Fin","type":"datetime","required":true},
     {"key":"purpose","label":"Motivo","type":"multiline","required":false}
   ],"submit_label":"Crear reserva"}'::jsonb,
   '{}'::jsonb),
  ('approve_reservation', '{"fields":[]}'::jsonb, '{}'::jsonb),
  ('reject_reservation',
   '{"fields":[{"key":"reason","label":"Razon","type":"multiline","required":false}],"submit_label":"Rechazar"}'::jsonb,
   '{}'::jsonb),
  ('cancel_reservation',
   '{"fields":[{"key":"reason","label":"Razon","type":"multiline","required":false}],"submit_label":"Cancelar"}'::jsonb,
   '{}'::jsonb),
  ('complete_reservation', '{"fields":[]}'::jsonb, '{}'::jsonb),
  ('join_waitlist',
   '{"fields":[{"key":"starts_at","label":"Desde","type":"datetime","required":false},
               {"key":"ends_at","label":"Hasta","type":"datetime","required":false}]}'::jsonb,
   '{}'::jsonb),
  ('resolve_reservation_conflict',
   '{"fields":[{"key":"resolution_mode","label":"Modelo","type":"picker",
                "options":["winner","waitlist","sortear","partir","escalar_decision"],"required":true},
               {"key":"winner_request_id","label":"Solicitud ganadora","type":"text","required":false},
               {"key":"reason","label":"Razon","type":"multiline","required":false}]}'::jsonb,
   '{}'::jsonb),
  ('block_time',
   '{"fields":[{"key":"starts_at","label":"Inicio","type":"datetime","required":true},
               {"key":"ends_at","label":"Fin","type":"datetime","required":true},
               {"key":"reason","label":"Razon","type":"text","required":false}]}'::jsonb,
   '{}'::jsonb),
  ('unblock_time',
   '{"fields":[{"key":"block_id","label":"Bloque","type":"resource_ref","required":true}]}'::jsonb,
   '{}'::jsonb),
  ('view_reservations',    '{"fields":[]}'::jsonb, '{}'::jsonb),
  ('view_availability',    '{"fields":[]}'::jsonb, '{}'::jsonb),
  ('manage_reservations',  '{"fields":[]}'::jsonb, '{}'::jsonb),

  -- money
  ('record_expense',
   '{"fields":[
     {"key":"amount","label":"Monto","type":"currency","required":true},
     {"key":"currency","label":"Moneda","type":"picker","options":["MXN","USD","EUR"],"required":true},
     {"key":"description","label":"Descripcion","type":"multiline","required":false},
     {"key":"beneficiaries","label":"Beneficiarios","type":"actor_ref","multiple":true,"required":true},
     {"key":"split_method","label":"Como dividir","type":"picker","options":["equal","percent","custom"],"required":true}
   ],"submit_label":"Registrar gasto"}'::jsonb,
   '{"currency":"MXN","split_method":"equal"}'::jsonb),
  ('record_event_expense',
   '{"fields":[
     {"key":"amount","label":"Monto","type":"currency","required":true},
     {"key":"currency","label":"Moneda","type":"picker","options":["MXN","USD","EUR"],"required":true},
     {"key":"description","label":"Descripcion","type":"multiline","required":false},
     {"key":"split_method","label":"Como dividir","type":"picker","options":["equal","percent","custom"],"required":true}
   ]}'::jsonb,
   '{"currency":"MXN","split_method":"equal"}'::jsonb),
  ('record_property_expense',
   '{"fields":[
     {"key":"amount","label":"Monto","type":"currency","required":true},
     {"key":"currency","label":"Moneda","type":"picker","options":["MXN","USD","EUR"],"required":true},
     {"key":"category","label":"Categoria","type":"picker",
       "options":["maintenance","utility","tax","insurance","other"],"required":true},
     {"key":"description","label":"Descripcion","type":"multiline","required":false}
   ]}'::jsonb,
   '{"currency":"MXN"}'::jsonb),
  ('record_contribution',
   '{"fields":[
     {"key":"amount","label":"Monto","type":"currency","required":true},
     {"key":"currency","label":"Moneda","type":"picker","options":["MXN","USD","EUR"],"required":true},
     {"key":"description","label":"Descripcion","type":"text","required":false}
   ]}'::jsonb,
   '{"currency":"MXN"}'::jsonb),
  ('record_payment',
   '{"fields":[
     {"key":"amount","label":"Monto","type":"currency","required":true},
     {"key":"currency","label":"Moneda","type":"picker","options":["MXN","USD","EUR"],"required":true},
     {"key":"recipient_actor_id","label":"Para","type":"actor_ref","required":true},
     {"key":"description","label":"Descripcion","type":"text","required":false}
   ]}'::jsonb,
   '{"currency":"MXN"}'::jsonb),
  ('record_payout',
   '{"fields":[
     {"key":"amount","label":"Monto","type":"currency","required":true},
     {"key":"currency","label":"Moneda","type":"picker","options":["MXN","USD","EUR"],"required":true},
     {"key":"recipient_actor_id","label":"Para","type":"actor_ref","required":true}
   ]}'::jsonb,
   '{"currency":"MXN"}'::jsonb),
  ('record_charge',
   '{"fields":[
     {"key":"amount","label":"Monto","type":"currency","required":true},
     {"key":"currency","label":"Moneda","type":"picker","options":["MXN","USD","EUR"],"required":true},
     {"key":"payer_actor_id","label":"De","type":"actor_ref","required":true},
     {"key":"description","label":"Descripcion","type":"text","required":false}
   ]}'::jsonb,
   '{"currency":"MXN"}'::jsonb),
  ('record_iou',
   '{"fields":[
     {"key":"amount","label":"Monto","type":"currency","required":true},
     {"key":"currency","label":"Moneda","type":"picker","options":["MXN","USD","EUR"],"required":true},
     {"key":"debtor_actor_id","label":"Debe","type":"actor_ref","required":true},
     {"key":"creditor_actor_id","label":"A","type":"actor_ref","required":true},
     {"key":"due_at","label":"Fecha limite","type":"date","required":false},
     {"key":"description","label":"Descripcion","type":"text","required":false}
   ]}'::jsonb,
   '{"currency":"MXN"}'::jsonb),
  ('generate_settlement',
   '{"fields":[{"key":"as_of","label":"Al corte","type":"date","required":false}]}'::jsonb,
   '{}'::jsonb),
  ('finalize_settlement_batch',
   '{"fields":[{"key":"batch_id","label":"Lote","type":"text","required":true}]}'::jsonb,
   '{}'::jsonb),
  ('void_transaction',
   '{"fields":[{"key":"transaction_id","label":"Transaccion","type":"text","required":true},
               {"key":"reason","label":"Razon","type":"multiline","required":true}]}'::jsonb,
   '{}'::jsonb),
  ('export_statement',
   '{"fields":[{"key":"starts_at","label":"Desde","type":"date","required":true},
               {"key":"ends_at","label":"Hasta","type":"date","required":true},
               {"key":"format","label":"Formato","type":"picker","options":["pdf","csv"],"required":true}]}'::jsonb,
   '{"format":"pdf"}'::jsonb),
  ('view_transactions', '{"fields":[]}'::jsonb, '{}'::jsonb),

  -- rights / ownership
  ('grant_right',
   '{"fields":[
     {"key":"holder_actor_id","label":"Para","type":"actor_ref","required":true},
     {"key":"right_kind","label":"Tipo de derecho","type":"picker",
       "options":["OWN","USE","MANAGE","VIEW","SELL","TRANSFER","GOVERN","BENEFICIARY","LIEN","LEASE","APPROVE","AUDIT"],"required":true},
     {"key":"percent","label":"Porcentaje","type":"number","required":false},
     {"key":"scope","label":"Alcance","type":"text","required":false},
     {"key":"ends_at","label":"Vence","type":"datetime","required":false}
   ]}'::jsonb,
   '{}'::jsonb),
  ('revoke_right',
   '{"fields":[{"key":"right_id","label":"Derecho","type":"text","required":true}]}'::jsonb,
   '{}'::jsonb),
  ('transfer_interest',
   '{"fields":[{"key":"new_holder_actor_id","label":"Nuevo titular","type":"actor_ref","required":true},
               {"key":"percent","label":"Porcentaje","type":"number","required":true}]}'::jsonb,
   '{}'::jsonb),
  ('transfer_ownership',
   '{"fields":[{"key":"new_owner_actor_id","label":"Nuevo propietario","type":"actor_ref","required":true},
               {"key":"percent","label":"Porcentaje","type":"number","required":true},
               {"key":"reason","label":"Motivo","type":"multiline","required":true}]}'::jsonb,
   '{"percent":100}'::jsonb),
  ('request_transfer',
   '{"fields":[{"key":"new_owner_actor_id","label":"Nuevo propietario","type":"actor_ref","required":true},
               {"key":"percent","label":"Porcentaje","type":"number","required":true},
               {"key":"reason","label":"Motivo","type":"multiline","required":true}]}'::jsonb,
   '{"percent":100}'::jsonb),
  ('approve_transfer', '{"fields":[]}'::jsonb, '{}'::jsonb),
  ('transfer_resource',
   '{"fields":[{"key":"target_actor_id","label":"Destino","type":"actor_ref","required":true},
               {"key":"reason","label":"Motivo","type":"multiline","required":true}]}'::jsonb,
   '{}'::jsonb),
  ('view_ownership',      '{"fields":[]}'::jsonb, '{}'::jsonb),
  ('view_beneficiaries',  '{"fields":[]}'::jsonb, '{}'::jsonb),
  ('grant_beneficiary',
   '{"fields":[{"key":"beneficiary_actor_id","label":"Beneficiario","type":"actor_ref","required":true},
               {"key":"percent","label":"Porcentaje","type":"number","required":true}]}'::jsonb,
   '{}'::jsonb),

  -- custody
  ('transfer_custody',
   '{"fields":[{"key":"new_custodian_actor_id","label":"Nuevo custodio","type":"actor_ref","required":true},
               {"key":"reason","label":"Motivo","type":"text","required":false}]}'::jsonb,
   '{}'::jsonb),
  ('return_resource',
   '{"fields":[{"key":"condition_note","label":"Estado al devolver","type":"multiline","required":false}]}'::jsonb,
   '{}'::jsonb),

  -- condition / maintenance
  ('record_maintenance',
   '{"fields":[
     {"key":"description","label":"Descripcion","type":"multiline","required":true},
     {"key":"cost","label":"Costo","type":"currency","required":false},
     {"key":"currency","label":"Moneda","type":"picker","options":["MXN","USD","EUR"],"required":false},
     {"key":"performed_at","label":"Fecha","type":"date","required":true},
     {"key":"performed_by","label":"Realizado por","type":"text","required":false}
   ]}'::jsonb,
   '{"currency":"MXN"}'::jsonb),
  ('log_maintenance',
   '{"fields":[
     {"key":"description","label":"Descripcion","type":"multiline","required":true},
     {"key":"cost","label":"Costo","type":"currency","required":false},
     {"key":"performed_at","label":"Fecha","type":"date","required":true}
   ]}'::jsonb,
   '{}'::jsonb),
  ('update_condition',
   '{"fields":[{"key":"condition","label":"Condicion","type":"picker",
                "options":["excellent","good","fair","poor","damaged"],"required":true},
               {"key":"notes","label":"Notas","type":"multiline","required":false}]}'::jsonb,
   '{}'::jsonb),
  ('record_damage',
   '{"fields":[{"key":"description","label":"Descripcion","type":"multiline","required":true},
               {"key":"severity","label":"Severidad","type":"picker",
                "options":["minor","moderate","severe"],"required":true},
               {"key":"occurred_at","label":"Cuando","type":"datetime","required":true}]}'::jsonb,
   '{}'::jsonb),
  ('update_valuation',
   '{"fields":[{"key":"amount","label":"Valor","type":"currency","required":true},
               {"key":"currency","label":"Moneda","type":"picker","options":["MXN","USD","EUR"],"required":true},
               {"key":"valuation_date","label":"Fecha","type":"date","required":true},
               {"key":"source","label":"Fuente","type":"text","required":false}]}'::jsonb,
   '{"currency":"MXN"}'::jsonb),
  ('report_issue',
   '{"fields":[{"key":"description","label":"Que paso","type":"multiline","required":true},
               {"key":"severity","label":"Severidad","type":"picker",
                "options":["info","low","medium","high","critical"],"required":true}]}'::jsonb,
   '{}'::jsonb),
  ('view_maintenance', '{"fields":[]}'::jsonb, '{}'::jsonb),

  -- documents
  ('attach_document',
   '{"fields":[{"key":"file_url","label":"Archivo","type":"file_url","required":true},
               {"key":"name","label":"Nombre","type":"text","required":true},
               {"key":"kind","label":"Tipo","type":"picker",
                "options":["contract","receipt","statement","certificate","policy","other"],"required":false}]}'::jsonb,
   '{}'::jsonb),
  ('link_document',
   '{"fields":[{"key":"document_id","label":"Documento","type":"resource_ref","required":true}]}'::jsonb,
   '{}'::jsonb),
  ('upload_document',
   '{"fields":[{"key":"file_url","label":"Archivo","type":"file_url","required":true},
               {"key":"name","label":"Nombre","type":"text","required":true}]}'::jsonb,
   '{}'::jsonb),
  ('upload_new_version',
   '{"fields":[{"key":"file_url","label":"Archivo","type":"file_url","required":true},
               {"key":"version_notes","label":"Notas de version","type":"multiline","required":false}]}'::jsonb,
   '{}'::jsonb),
  ('request_approval',
   '{"fields":[{"key":"approver_actor_id","label":"Aprobador","type":"actor_ref","required":false},
               {"key":"note","label":"Nota","type":"multiline","required":false}]}'::jsonb,
   '{}'::jsonb),
  ('approve_document',
   '{"fields":[{"key":"note","label":"Comentario","type":"multiline","required":false}]}'::jsonb,
   '{}'::jsonb),
  ('reject_document',
   '{"fields":[{"key":"reason","label":"Razon","type":"multiline","required":true}]}'::jsonb,
   '{}'::jsonb),
  ('review_document',
   '{"fields":[{"key":"verdict","label":"Veredicto","type":"picker",
                "options":["approved","rejected","needs_changes"],"required":true},
               {"key":"comment","label":"Comentario","type":"multiline","required":false}]}'::jsonb,
   '{}'::jsonb),
  ('sign_document',
   '{"fields":[{"key":"signature_method","label":"Metodo","type":"picker",
                "options":["digital","wet"],"required":true}]}'::jsonb,
   '{"signature_method":"digital"}'::jsonb),
  ('archive_document', '{"fields":[{"key":"reason","label":"Razon","type":"text","required":false}]}'::jsonb, '{}'::jsonb),
  ('view_document',    '{"fields":[]}'::jsonb, '{}'::jsonb),

  -- events
  ('rsvp_event',
   '{"fields":[{"key":"response","label":"Respuesta","type":"picker",
                "options":["going","maybe","not_going"],"required":true}]}'::jsonb,
   '{}'::jsonb),
  ('invite_participant',
   '{"fields":[{"key":"actor_id","label":"Persona","type":"actor_ref","required":true}]}'::jsonb,
   '{}'::jsonb),
  ('check_in_participant',
   '{"fields":[{"key":"participant_actor_id","label":"Participante","type":"actor_ref","required":true}]}'::jsonb,
   '{}'::jsonb),
  ('mark_no_show',
   '{"fields":[{"key":"participant_actor_id","label":"Participante","type":"actor_ref","required":true}]}'::jsonb,
   '{}'::jsonb),
  ('change_host',
   '{"fields":[{"key":"new_host_actor_id","label":"Nuevo anfitrion","type":"actor_ref","required":true},
               {"key":"reason","label":"Razon","type":"text","required":false}]}'::jsonb,
   '{}'::jsonb),
  ('preview_next_host', '{"fields":[]}'::jsonb, '{}'::jsonb),
  ('set_next_host',
   '{"fields":[{"key":"host_actor_id","label":"Anfitrion","type":"actor_ref","required":true}]}'::jsonb,
   '{}'::jsonb),
  ('close_event',
   '{"fields":[{"key":"summary","label":"Resumen","type":"multiline","required":false}]}'::jsonb,
   '{}'::jsonb),
  ('cancel_event',
   '{"fields":[{"key":"reason","label":"Razon","type":"multiline","required":true}]}'::jsonb,
   '{}'::jsonb),
  ('reopen_event',
   '{"fields":[{"key":"reason","label":"Razon","type":"text","required":false}]}'::jsonb,
   '{}'::jsonb),

  -- obligations
  ('accept_obligation', '{"fields":[]}'::jsonb, '{}'::jsonb),
  ('complete_obligation', '{"fields":[]}'::jsonb, '{}'::jsonb),
  ('dispute_obligation',
   '{"fields":[{"key":"reason","label":"Razon","type":"multiline","required":true}]}'::jsonb,
   '{}'::jsonb),
  ('forgive_obligation',
   '{"fields":[{"key":"reason","label":"Razon","type":"multiline","required":true}]}'::jsonb,
   '{}'::jsonb),
  ('extend_due_date',
   '{"fields":[{"key":"new_due_at","label":"Nueva fecha","type":"date","required":true}]}'::jsonb,
   '{}'::jsonb),
  ('convert_to_settlement', '{"fields":[]}'::jsonb, '{}'::jsonb),
  ('cancel_obligation',
   '{"fields":[{"key":"reason","label":"Razon","type":"multiline","required":true}]}'::jsonb,
   '{}'::jsonb),

  -- real estate
  ('record_insurance',
   '{"fields":[
     {"key":"provider","label":"Proveedor","type":"text","required":true},
     {"key":"policy_number","label":"Numero de poliza","type":"text","required":false},
     {"key":"premium","label":"Prima","type":"currency","required":false},
     {"key":"currency","label":"Moneda","type":"picker","options":["MXN","USD","EUR"],"required":false},
     {"key":"starts_at","label":"Vigencia desde","type":"date","required":true},
     {"key":"ends_at","label":"Vigencia hasta","type":"date","required":true}
   ]}'::jsonb,
   '{"currency":"MXN"}'::jsonb),
  ('record_tax_payment',
   '{"fields":[
     {"key":"amount","label":"Monto","type":"currency","required":true},
     {"key":"currency","label":"Moneda","type":"picker","options":["MXN","USD","EUR"],"required":true},
     {"key":"period","label":"Periodo","type":"text","required":true},
     {"key":"description","label":"Descripcion","type":"text","required":false}
   ]}'::jsonb,
   '{"currency":"MXN"}'::jsonb),
  ('record_lease_income',
   '{"fields":[
     {"key":"amount","label":"Monto","type":"currency","required":true},
     {"key":"currency","label":"Moneda","type":"picker","options":["MXN","USD","EUR"],"required":true},
     {"key":"period","label":"Periodo","type":"text","required":true}
   ]}'::jsonb,
   '{"currency":"MXN"}'::jsonb),
  ('create_lease',
   '{"fields":[
     {"key":"lessee_actor_id","label":"Arrendatario","type":"actor_ref","required":true},
     {"key":"starts_at","label":"Inicio","type":"date","required":true},
     {"key":"ends_at","label":"Fin","type":"date","required":false},
     {"key":"monthly_rent","label":"Renta mensual","type":"currency","required":true},
     {"key":"currency","label":"Moneda","type":"picker","options":["MXN","USD","EUR"],"required":true}
   ]}'::jsonb,
   '{"currency":"MXN"}'::jsonb),
  ('terminate_lease',
   '{"fields":[{"key":"termination_date","label":"Fecha terminacion","type":"date","required":true},
               {"key":"reason","label":"Razon","type":"multiline","required":true}]}'::jsonb,
   '{}'::jsonb),

  -- inventory
  ('adjust_stock',
   '{"fields":[{"key":"delta","label":"Ajuste","type":"number","required":true},
               {"key":"reason","label":"Razon","type":"text","required":true}]}'::jsonb,
   '{}'::jsonb),
  ('transfer_stock',
   '{"fields":[{"key":"target_resource_id","label":"Destino","type":"resource_ref","required":true},
               {"key":"quantity","label":"Cantidad","type":"number","required":true}]}'::jsonb,
   '{}'::jsonb),
  ('consume_item',
   '{"fields":[{"key":"quantity","label":"Cantidad","type":"number","required":true}]}'::jsonb,
   '{"quantity":1}'::jsonb),
  ('record_purchase',
   '{"fields":[{"key":"quantity","label":"Cantidad","type":"number","required":true},
               {"key":"unit_cost","label":"Costo unitario","type":"currency","required":true},
               {"key":"currency","label":"Moneda","type":"picker","options":["MXN","USD","EUR"],"required":true}]}'::jsonb,
   '{"currency":"MXN"}'::jsonb),

  -- resource ops base
  ('edit_resource',
   '{"fields":[{"key":"display_name","label":"Nombre","type":"text","required":false},
               {"key":"description","label":"Descripcion","type":"multiline","required":false},
               {"key":"estimated_value","label":"Valor","type":"currency","required":false},
               {"key":"currency","label":"Moneda","type":"picker","options":["MXN","USD","EUR"],"required":false},
               {"key":"location_text","label":"Ubicacion","type":"text","required":false}]}'::jsonb,
   '{}'::jsonb),
  ('update_resource',
   '{"fields":[{"key":"display_name","label":"Nombre","type":"text","required":false},
               {"key":"description","label":"Descripcion","type":"multiline","required":false}]}'::jsonb,
   '{}'::jsonb),
  ('archive_resource',
   '{"fields":[{"key":"reason","label":"Razon","type":"text","required":false}]}'::jsonb,
   '{}'::jsonb),
  ('restore_resource', '{"fields":[]}'::jsonb, '{}'::jsonb),
  ('view_activity',    '{"fields":[]}'::jsonb, '{}'::jsonb),
  ('view_audit',       '{"fields":[]}'::jsonb, '{}'::jsonb),
  ('link_existing_resource',
   '{"fields":[{"key":"other_resource_id","label":"Recurso","type":"resource_ref","required":true},
               {"key":"relation_type","label":"Relacion","type":"picker",
                "options":["contains","uses","depends_on","documents","secures","scheduled_for",
                           "owns","leases","insures","guarantees","references"],"required":true}]}'::jsonb,
   '{}'::jsonb),
  ('unlink_resource',
   '{"fields":[{"key":"relation_id","label":"Relacion","type":"text","required":true}]}'::jsonb,
   '{}'::jsonb)
on conflict (action_key) do nothing;
