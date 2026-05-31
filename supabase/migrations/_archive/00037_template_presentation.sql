-- 00037 — Template presentation + defaultCategory.
--
-- Audit doc § 5.3 item 7c. Folds the data that previously lived on the
-- legacy `GroupType` Swift enum (displayName, symbolName, copy/description,
-- defaultEventLabel) into `templates.config.presentation` jsonb. Also
-- adds `templates.config.defaultCategory` so groups created from a
-- template inherit the correct `GroupCategory` (which drives the avatar
-- color ramp per DS v3 §4.7).
--
-- Why now: Vision principle "templates as configuration, not code". Two
-- parallel taxonomies (GroupType enum + Template registry) were drifting.
-- One source of truth = the templates table.
--
-- iOS impact: Swift `Template` exposes `effectiveDisplayName`,
-- `effectiveSymbolName`, etc. accessors that read from `presentation`
-- with fallback to top-level `Template.name`/`icon`/`description`. Old
-- DB rows decode unchanged.
--
-- Cohabitation: this migration ONLY adds. The legacy `groups.group_type`
-- column and the `GroupType` Swift enum stay alive until a follow-up
-- migration drops them once all consumers migrate (tracked in
-- Plans/GroupTypeRemoval.md).

update public.templates
set config = jsonb_set(
  config,
  '{presentation}',
  jsonb_build_object(
    'displayName',       'Cena recurrente',
    'symbolName',        'fork.knife',
    'description',       'Cena semanal o mensual con anfitrión rotativo',
    'bullets',           jsonb_build_array(
      'Anfitrión rota turno a turno',
      'Multa automática por llegar tarde',
      'RSVP obligatorio antes del cierre',
      'Apelación de multas con voto anónimo'
    ),
    'defaultEventLabel', 'Cena'
  )
) || jsonb_build_object('defaultCategory', 'socialRecurring')
where id = 'recurring_dinner';

update public.templates
set config = jsonb_set(
  config,
  '{presentation}',
  jsonb_build_object(
    'displayName',       'Recurso compartido',
    'symbolName',        'square.stack.3d.up.fill',
    'description',       'Boletos, cupos o activos que rotan entre miembros',
    'bullets',           jsonb_build_array(
      'Calendario de turnos asignados',
      'Petición de cambio entre miembros',
      'Multa por declinar turno aceptado'
    ),
    'defaultEventLabel', 'Turno'
  )
) || jsonb_build_object('defaultCategory', 'sharedResource')
where id = 'shared_resource';

update public.templates
set config = jsonb_set(
  config,
  '{presentation}',
  jsonb_build_object(
    'displayName',       'Tanda de ahorro',
    'symbolName',        'circle.grid.cross.fill',
    'description',       'Aportes periódicos rotativos (tandas, susu, hui, comités)',
    'bullets',           jsonb_build_array(
      'Calendario de aportes y cobros',
      'Rotación configurable por sorteo o consenso',
      'Manejo de defaulters con votación grupal'
    ),
    'defaultEventLabel', 'Tanda'
  )
) || jsonb_build_object('defaultCategory', 'rotatingSavings')
where id = 'rotating_savings';

update public.templates
set config = jsonb_set(
  config,
  '{presentation}',
  jsonb_build_object(
    'displayName',       'A medida',
    'symbolName',        'wand.and.stars',
    'description',       'Construye tus propias reglas (Fase 4)',
    'bullets',           jsonb_build_array(
      'Editor visual de reglas',
      'Importar/exportar configuraciones',
      'Marketplace de reglas comunitarias'
    ),
    'defaultEventLabel', 'Evento'
  )
) || jsonb_build_object('defaultCategory', 'commitmentPact')
where id = 'custom';
