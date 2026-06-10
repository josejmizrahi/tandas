
-- =============================================================================
-- R.4B · decision_templates_catalog + decisions.template_key
-- =============================================================================
-- Additive. No rename. No contract break.
--   - New catalog table with 12 seeded templates.
--   - decisions gets an optional template_key (FK to catalog).
--   - RLS: catalog readable by authenticated; mutated only via migrations
--     or future SECDEF RPCs.
--   - Index on template_key (partial).
--   - GRANT EXECUTE not applicable (table, not function); SELECT to authenticated.
-- =============================================================================

create table if not exists public.decision_templates_catalog (
  template_key                text primary key,
  decision_type               text not null,
  display_name                text not null,
  description                 text,
  default_voting_model        text not null default 'yes_no_abstain'
    check (default_voting_model in ('yes_no_abstain','single_choice','multiple_choice','ranked','approval','numeric','consent')),
  default_quorum              numeric check (default_quorum is null or (default_quorum >= 0 and default_quorum <= 1)),
  default_approval_threshold  numeric check (default_approval_threshold is null or (default_approval_threshold >= 0 and default_approval_threshold <= 1)),
  payload_schema              jsonb not null default '{}'::jsonb,
  -- execution_kind drives execute_decision() dispatch. New values can be
  -- added without altering this column; execute_decision raises
  -- feature_not_supported (errcode 0A000) for unknown kinds.
  execution_kind              text not null,
  metadata                    jsonb not null default '{}'::jsonb,
  created_at                  timestamptz not null default now(),
  updated_at                  timestamptz not null default now()
);

comment on table public.decision_templates_catalog is
  'R.4B: canonical templates for decisions. payload_schema is documental (not enforced). execute_decision() dispatches by execution_kind when decisions.template_key is set.';

drop trigger if exists decision_templates_catalog_set_updated_at on public.decision_templates_catalog;
create trigger decision_templates_catalog_set_updated_at
  before update on public.decision_templates_catalog
  for each row execute function public.touch_updated_at();

alter table public.decisions
  add column if not exists template_key text
    references public.decision_templates_catalog(template_key)
    on delete set null;

create index if not exists idx_decisions_template
  on public.decisions(template_key)
  where template_key is not null;

-- RLS: read-only for any authenticated session.
alter table public.decision_templates_catalog enable row level security;

drop policy if exists "decision_templates_catalog_read" on public.decision_templates_catalog;
create policy "decision_templates_catalog_read"
  on public.decision_templates_catalog
  for select
  to authenticated, service_role
  using (true);

revoke all on public.decision_templates_catalog from anon;
grant select on public.decision_templates_catalog to authenticated, service_role;

-- =============================================================================
-- Seed: 12 canonical templates
-- =============================================================================
insert into public.decision_templates_catalog
  (template_key, decision_type, display_name, description, default_voting_model,
   default_quorum, default_approval_threshold, payload_schema, execution_kind)
values
  ('admit_member', 'governance', 'Admitir miembro',
   'Aprobar el ingreso de un actor como miembro del contexto.',
   'yes_no_abstain', 0.5, 0.5,
   jsonb_build_object(
     'fields', jsonb_build_array(
       jsonb_build_object('name','member_actor_id','type','uuid','required',true),
       jsonb_build_object('name','membership_type','type','text','required',false))),
   'activate_membership'),

  ('remove_member', 'governance', 'Remover miembro',
   'Quitar a un miembro del contexto.',
   'yes_no_abstain', 0.5, 0.6,
   jsonb_build_object(
     'fields', jsonb_build_array(
       jsonb_build_object('name','member_actor_id','type','uuid','required',true),
       jsonb_build_object('name','reason','type','text','required',false))),
   'set_membership_removed'),

  ('ban_member', 'governance', 'Banear miembro',
   'Bloquear permanentemente a un miembro del contexto.',
   'yes_no_abstain', 0.6, 0.75,
   jsonb_build_object(
     'fields', jsonb_build_array(
       jsonb_build_object('name','member_actor_id','type','uuid','required',true),
       jsonb_build_object('name','reason','type','text','required',true))),
   'set_membership_banned'),

  ('approve_expense', 'money', 'Aprobar gasto',
   'Autorizar un gasto y crear la transacción + obligaciones.',
   'yes_no_abstain', 0.5, 0.5,
   jsonb_build_object(
     'fields', jsonb_build_array(
       jsonb_build_object('name','paid_by_actor_id','type','uuid','required',true),
       jsonb_build_object('name','amount','type','numeric','required',true),
       jsonb_build_object('name','currency','type','text','required',true),
       jsonb_build_object('name','description','type','text','required',false),
       jsonb_build_object('name','beneficiaries','type','array','required',true))),
   'create_expense'),

  ('approve_resource_purchase', 'money', 'Aprobar compra de recurso',
   'Autorizar la adquisición de un recurso.',
   'yes_no_abstain', 0.5, 0.5,
   jsonb_build_object(
     'fields', jsonb_build_array(
       jsonb_build_object('name','description','type','text','required',true),
       jsonb_build_object('name','estimated_value','type','numeric','required',false),
       jsonb_build_object('name','currency','type','text','required',false))),
   'mark_resource_approved'),

  ('change_rule', 'governance', 'Cambiar regla',
   'Crear o modificar una regla del contexto.',
   'yes_no_abstain', 0.5, 0.5,
   jsonb_build_object(
     'fields', jsonb_build_array(
       jsonb_build_object('name','rule_id','type','uuid','required',false),
       jsonb_build_object('name','trigger_event_type','type','text','required',true),
       jsonb_build_object('name','condition_tree','type','jsonb','required',false),
       jsonb_build_object('name','consequences','type','jsonb','required',true))),
   'upsert_rule'),

  ('archive_rule', 'governance', 'Archivar regla',
   'Desactivar una regla del contexto.',
   'yes_no_abstain', 0.5, 0.5,
   jsonb_build_object(
     'fields', jsonb_build_array(
       jsonb_build_object('name','rule_id','type','uuid','required',true))),
   'archive_rule'),

  ('grant_resource_right', 'resources', 'Otorgar derecho sobre recurso',
   'Crear un right activo (OWN/USE/MANAGE/VIEW/BENEFICIARY) sobre un recurso.',
   'yes_no_abstain', 0.5, 0.5,
   jsonb_build_object(
     'fields', jsonb_build_array(
       jsonb_build_object('name','resource_id','type','uuid','required',true),
       jsonb_build_object('name','holder_actor_id','type','uuid','required',true),
       jsonb_build_object('name','right_kind','type','text','required',true),
       jsonb_build_object('name','percent','type','numeric','required',false),
       jsonb_build_object('name','scope','type','text','required',false))),
   'grant_resource_right'),

  ('archive_resource', 'resources', 'Archivar recurso',
   'Marcar un recurso como archivado (soft delete).',
   'yes_no_abstain', 0.5, 0.5,
   jsonb_build_object(
     'fields', jsonb_build_array(
       jsonb_build_object('name','resource_id','type','uuid','required',true),
       jsonb_build_object('name','reason','type','text','required',false))),
   'archive_resource'),

  ('resolve_reservation_conflict', 'reservations', 'Resolver conflicto de reservación',
   'Decidir el ganador (u otra resolución) de un conflicto entre reservaciones.',
   'single_choice', 0.5, null,
   jsonb_build_object(
     'fields', jsonb_build_array(
       jsonb_build_object('name','conflict_id','type','uuid','required',true)),
     'notes','Las opciones llevan payload.action y payload.winner_reservation_id.'),
   'reservation_award'),

  ('approve_payout', 'money', 'Aprobar payout',
   'Autorizar una distribución de dinero a un actor.',
   'yes_no_abstain', 0.5, 0.5,
   jsonb_build_object(
     'fields', jsonb_build_array(
       jsonb_build_object('name','to_actor_id','type','uuid','required',true),
       jsonb_build_object('name','amount','type','numeric','required',true),
       jsonb_build_object('name','currency','type','text','required',true),
       jsonb_build_object('name','description','type','text','required',false))),
   'create_payout'),

  ('generic', 'generic', 'Decisión genérica',
   'Decisión sin efecto secundario en el backend; sólo registra el resultado.',
   'yes_no_abstain', 0.5, 0.5,
   '{}'::jsonb,
   'noop')
on conflict (template_key) do update
  set decision_type              = excluded.decision_type,
      display_name               = excluded.display_name,
      description                = excluded.description,
      default_voting_model       = excluded.default_voting_model,
      default_quorum             = excluded.default_quorum,
      default_approval_threshold = excluded.default_approval_threshold,
      payload_schema             = excluded.payload_schema,
      execution_kind             = excluded.execution_kind,
      updated_at                 = now();
