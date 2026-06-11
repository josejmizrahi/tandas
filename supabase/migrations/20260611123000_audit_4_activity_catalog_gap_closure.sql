-- ============================================================================
-- AUDIT.4 — Cierre del gap del activity_event_catalog (2026-06-11)
-- ============================================================================
-- Origen: Plans/Active/SupabaseArchitectureAudit.md §11.2. 20 event_types
-- emitidos en producción (activity_events) no estaban registrados en
-- activity_event_catalog, rompiendo la promesa "el catálogo es el contrato".
-- Este migration los cataloga; _smoke_mvp2_audit_baseline (audit_5) vuelve
-- invariante que lo emitido ⊆ catálogo.
-- is_system_generated=true para los emitidos por detectores pg_cron / motores
-- (no por una acción humana directa).
-- Rollback: DELETE de estos 20 event_type.
-- ============================================================================

insert into public.activity_event_catalog
  (event_type, domain, description, expected_subject_type, is_system_generated)
values
  ('context.child.created',          'context',     'Se creó un subcontexto dentro del contexto',              'actor',       false),
  ('context.child.linked',           'context',     'Se vinculó un contexto existente como hijo',              'actor',       false),
  ('context.child.unlinked',         'context',     'Se desvinculó un subcontexto',                            'actor',       false),
  ('context.parent.linked',          'context',     'El contexto se vinculó a un padre',                       'actor',       false),
  ('context.parent.unlinked',        'context',     'El contexto se desvinculó de su padre',                   'actor',       false),
  ('context.merged',                 'context',     'El contexto se fusionó con otro',                         'actor',       false),
  ('context.unmerged',               'context',     'Se revirtió una fusión de contextos',                     'actor',       false),
  ('decision.updated',               'decision',    'Se editó una decisión abierta',                           'decision',    false),
  ('document.expiring',              'document',    'Documento próximo a vencer (detector R6.C)',              'document',    true),
  ('event.updated',                  'event',       'Se editó un evento del calendario',                       'event',       false),
  ('event.host_rotation_set',        'event',       'Se configuró la rotación de anfitriones',                 'event',       false),
  ('event.next_host_overridden',     'event',       'Se forzó manualmente el siguiente anfitrión',             'event',       false),
  ('event.next_occurrence_created',  'event',       'El motor creó la siguiente ocurrencia de la serie',       'event',       true),
  ('governance.approved',            'governance',  'Acción de gobernanza aprobada por decisión',              'governance_action', true),
  ('governance.executed',            'governance',  'Acción de gobernanza ejecutada post-aprobación',          'governance_action', true),
  ('obligation.overdue',             'obligation',  'Obligación vencida (detector R6.C)',                      'obligation',  true),
  ('obligation.updated',             'obligation',  'Se editó una obligación',                                 'obligation',  false),
  ('reservation.starting_soon',      'reservation', 'Reserva por comenzar (detector R6.C)',                    'reservation', true),
  ('resource.action_executed',       'resource',    'Se ejecutó una acción del catálogo sobre el recurso',     'resource',    false),
  ('rule.updated',                   'rule',        'Se editó una regla',                                      'rule',        false)
on conflict (event_type) do nothing;
