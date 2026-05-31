-- 00021 — Platform V2: templates as serializable configuration
--
-- Phase1 Bloque 1 (Plans/Phase1.md). Per prompt §"Templates como
-- configuración, no como código": a template is a jsonb config the app
-- reads at runtime, NOT compiled Swift. This makes templates extensible
-- without touching core (Fase 2 just inserts a new row).
--
-- V1 ships one template: recurring_dinner. The config holds metadata,
-- module list, governance defaults, settings defaults, default rules,
-- suggested tabs, and onboarding flow.

create table if not exists public.templates (
  id          text primary key,
  version     int  not null default 1,
  name        text not null,
  description text not null,
  icon        text not null,           -- SF Symbol name
  config      jsonb not null,          -- full Template struct serialized
  available   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

comment on table public.templates is
  'Serializable templates. App registry reads from here. New templates = new row.';
comment on column public.templates.config is
  'Full Template struct: defaultModules, defaultGovernance, defaultSettings, defaultRules, suggestedTabs, onboardingFlow.';

create trigger templates_set_updated_at
  before update on public.templates
  for each row execute function public.set_updated_at();

-- =============================================================================
-- RLS — readable by anyone, writable only by service role
-- =============================================================================

alter table public.templates enable row level security;

drop policy if exists templates_select_all on public.templates;
create policy templates_select_all on public.templates
  for select using (true);

-- INSERT/UPDATE/DELETE: no policy → only service role can mutate.

-- =============================================================================
-- Seed: recurring_dinner template
-- =============================================================================

insert into public.templates (id, version, name, description, icon, config, available)
values (
  'recurring_dinner',
  1,
  'Cena recurrente',
  'Cenas que rotan host con multas automáticas por no avisar, llegar tarde, no ir.',
  'fork.knife',
  jsonb_build_object(
    'id',                  'recurring_dinner',
    'availableInVersion',  1,

    -- Modules active by default for this template
    'defaultModules', jsonb_build_array(
      'basic_fines',
      'rotating_host',
      'rsvp',
      'check_in',
      'appeal_voting'
    ),

    -- Governance: founder edits, host closes, any member proposes votes
    'defaultGovernance', jsonb_build_object(
      'whoCanModifyRules',       'founder',
      'whoCanInviteMembers',     'founder',
      'whoCanRemoveMembers',     'majorityVote',
      'whoCanCloseEvents',       'host',
      'whoCanCreateVotes',       'anyMember',
      'whoCanModifyGovernance',  'founder',
      'votingQuorumPercent',     50,
      'votingThresholdPercent',  50,
      'votingDurationHours',     72,
      'votesAreAnonymous',       true
    ),

    -- Template-specific settings
    'defaultSettings', jsonb_build_object(
      'eventVocabulary',        'cena',
      'frequencyType',          'weekly',
      'rotationMode',           'manual',
      'finesEnabled',           true,
      'gracePeriodEvents',      3,
      'noShowGraceMinutes',     60,
      'autoGenerateEvents',     false,
      'blockUnpaidAttendance',  false
    ),

    -- 5 default rules. Each rule is created in the rules table at group
    -- creation time. Body matches DinnerRecurringTemplate.defaultRules in
    -- Swift. When the app reads templates from this table (Bloque 5),
    -- this becomes the canonical source.
    'defaultRules', jsonb_build_array(
      jsonb_build_object(
        'name',          'Llegada tardía',
        'description',   'Multa escalada por minuto de retraso al check-in.',
        'module',        'basic_fines',
        'isActive',      true,
        'trigger',       jsonb_build_object('eventType', 'checkInRecorded'),
        'conditions',    jsonb_build_array(
          jsonb_build_object(
            'type', 'checkInMinutesLate',
            'config', jsonb_build_object('thresholdMinutes', 0)
          )
        ),
        'consequences',  jsonb_build_array(
          jsonb_build_object(
            'type', 'fine',
            'config', jsonb_build_object(
              'baseAmount',  200,
              'stepAmount',  50,
              'stepMinutes', 30
            )
          )
        )
      ),
      jsonb_build_object(
        'name',          'No confirmó a tiempo',
        'description',   'Multa por no responder RSVP antes del cierre del evento.',
        'module',        'basic_fines',
        'isActive',      true,
        'trigger',       jsonb_build_object('eventType', 'eventClosed'),
        'conditions',    jsonb_build_array(
          jsonb_build_object(
            'type', 'responseStatusIs',
            'config', jsonb_build_object('status', 'pending')
          )
        ),
        'consequences',  jsonb_build_array(
          jsonb_build_object(
            'type', 'fine',
            'config', jsonb_build_object('amount', 200)
          )
        )
      ),
      jsonb_build_object(
        'name',          'Cancelación mismo día',
        'description',   'Multa por cambiar a "no voy" el día del evento.',
        'module',        'basic_fines',
        'isActive',      true,
        'trigger',       jsonb_build_object('eventType', 'rsvpChangedSameDay'),
        'conditions',    jsonb_build_array(
          jsonb_build_object('type', 'alwaysTrue', 'config', jsonb_build_object())
        ),
        'consequences',  jsonb_build_array(
          jsonb_build_object(
            'type', 'fine',
            'config', jsonb_build_object('amount', 200)
          )
        )
      ),
      jsonb_build_object(
        'name',          'No se presentó',
        'description',   'Multa por confirmar y no llegar (sin check-in).',
        'module',        'basic_fines',
        'isActive',      true,
        'trigger',       jsonb_build_object('eventType', 'eventClosed'),
        'conditions',    jsonb_build_array(
          jsonb_build_object(
            'type', 'responseStatusIs',
            'config', jsonb_build_object('status', 'going')
          ),
          jsonb_build_object(
            'type', 'checkInExists',
            'config', jsonb_build_object('exists', false)
          )
        ),
        'consequences',  jsonb_build_array(
          jsonb_build_object(
            'type', 'fine',
            'config', jsonb_build_object('amount', 500)
          )
        )
      ),
      jsonb_build_object(
        'name',          'Anfitrión sin descripción',
        'description',   'Multa al host si no propuso menú/lugar 24h antes.',
        'module',        'basic_fines',
        'isActive',      true,
        'trigger',       jsonb_build_object(
          'eventType', 'hoursBeforeEvent',
          'config',    jsonb_build_object('hours', 24)
        ),
        'conditions',    jsonb_build_array(
          jsonb_build_object('type', 'memberIsHost', 'config', jsonb_build_object()),
          jsonb_build_object('type', 'eventDescriptionMissing', 'config', jsonb_build_object())
        ),
        'consequences',  jsonb_build_array(
          jsonb_build_object(
            'type', 'fine',
            'config', jsonb_build_object('amount', 100)
          )
        )
      )
    ),

    -- 4 tabs the template renders in MainTabView
    'suggestedTabs', jsonb_build_array(
      jsonb_build_object('id', 'home',  'title', 'Inicio', 'icon', 'house.fill',
                         'order', 1, 'viewType', 'dinner_home', 'isUniversal', false),
      jsonb_build_object('id', 'inbox', 'title', 'Inbox',  'icon', 'tray.fill',
                         'order', 2, 'viewType', 'inbox',       'isUniversal', true),
      jsonb_build_object('id', 'rules', 'title', 'Reglas', 'icon', 'list.bullet.clipboard.fill',
                         'order', 3, 'viewType', 'rules',       'isUniversal', true),
      jsonb_build_object('id', 'me',    'title', 'Yo',     'icon', 'person.crop.circle.fill',
                         'order', 4, 'viewType', 'profile',     'isUniversal', true)
    ),

    -- Onboarding flow steps. Used by the founder coordinator to render
    -- the right view per step. V1 = 8 steps + 1 confirmation.
    'onboardingFlow', jsonb_build_array(
      jsonb_build_object('step', 'welcome',         'order', 0, 'skippable', false),
      jsonb_build_object('step', 'identity',        'order', 1, 'skippable', true),
      jsonb_build_object('step', 'templateSelect',  'order', 2, 'skippable', false),
      jsonb_build_object('step', 'group',           'order', 3, 'skippable', false),
      jsonb_build_object('step', 'vocabulary',      'order', 4, 'skippable', true),
      jsonb_build_object('step', 'rules',           'order', 5, 'skippable', true),
      jsonb_build_object('step', 'governance',      'order', 6, 'skippable', true),
      jsonb_build_object('step', 'invite',          'order', 7, 'skippable', true),
      jsonb_build_object('step', 'phoneVerify',     'order', 8, 'skippable', false),
      jsonb_build_object('step', 'otp',             'order', 9, 'skippable', false),
      jsonb_build_object('step', 'confirm',         'order', 10,'skippable', false)
    )
  ),
  true
)
on conflict (id) do update
  set version     = excluded.version,
      name        = excluded.name,
      description = excluded.description,
      icon        = excluded.icon,
      config      = excluded.config,
      available   = excluded.available,
      updated_at  = now();

-- =============================================================================
-- Placeholder rows for future templates (visible in selector, not selectable)
-- =============================================================================

insert into public.templates (id, version, name, description, icon, config, available)
values
  ('shared_resource', 1, 'Recurso compartido',
   'Boletos, cupos o activos que rotan entre miembros.', 'square.stack.3d.up.fill',
   jsonb_build_object('id', 'shared_resource', 'availableInVersion', 2),
   false),
  ('rotating_savings', 1, 'Tanda de ahorro',
   'Aportes periódicos rotativos (sistema de tandas).', 'circle.grid.cross.fill',
   jsonb_build_object('id', 'rotating_savings', 'availableInVersion', 3),
   false),
  ('custom', 1, 'A medida',
   'Construye tus propias reglas (Fase 4).', 'wand.and.stars',
   jsonb_build_object('id', 'custom', 'availableInVersion', 4),
   false)
on conflict (id) do nothing;
