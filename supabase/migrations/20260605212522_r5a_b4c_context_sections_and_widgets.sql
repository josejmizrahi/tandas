-- ============================================================================
-- R.5A.B.4C — CONTEXT sections + widgets (descriptor-driven UI foundation)
-- ============================================================================
-- Mirror de B.4R pero para Context. context_subtype = actors.actor_subtype
-- (plain text, no FK rigid -- preserva flexibilidad existente).
--
-- Crea 4 tablas:
--   context_section_catalog       (10 secciones canonicas founder)
--   context_subtype_sections      (matriz subtype -> section)
--   context_dashboard_widgets     (12 widgets canonicos)
--   context_subtype_widgets       (matriz subtype -> widget)
--
-- Subtypes seedeados (founder canon sec 9 del plan): family, company, trip,
-- project, community, trust, generic, friend_group (legacy).
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. context_section_catalog (10 secciones founder spec sec 11)
-- ----------------------------------------------------------------------------
create table public.context_section_catalog (
  section_key text primary key,
  display_name text not null,
  description text,
  icon text,
  default_sort_order int not null default 100,
  metadata jsonb not null default '{}',
  created_at timestamptz not null default now()
);

comment on table public.context_section_catalog is
  'R.5A.B.4C: catalogo universal de secciones UI de Context. Filtradas por descriptor (B.7).';

insert into public.context_section_catalog (section_key, display_name, icon, default_sort_order) values
  ('overview',     'Resumen',       'rectangle.grid.1x2',         1),
  ('people',       'Personas',      'person.2',                   2),
  ('resources',    'Recursos',      'cube',                       3),
  ('money',        'Dinero',        'banknote',                   4),
  ('calendar',     'Calendario',    'calendar',                  10),
  ('governance',   'Gobernanza',    'building.columns',          11),
  ('documents',    'Documentos',    'doc',                       12),
  ('obligations',  'Obligaciones',  'doc.text.below.ecg',        13),
  ('activity',     'Actividad',     'bolt',                     200),
  ('settings',     'Configuracion', 'gearshape',                900)
on conflict (section_key) do nothing;

alter table public.context_section_catalog enable row level security;
create policy "context_section_catalog_read_all"
  on public.context_section_catalog for select to authenticated using (true);
grant select on public.context_section_catalog to authenticated;

-- ----------------------------------------------------------------------------
-- 2. context_subtype_sections (matriz subtype -> section)
--    context_subtype = actors.actor_subtype (plain text, no FK).
-- ----------------------------------------------------------------------------
create table public.context_subtype_sections (
  context_subtype text not null,
  section_key text not null references public.context_section_catalog(section_key) on update cascade on delete cascade,
  sort_order int not null default 100,
  required_permission text,
  visible_when_status text[] not null default '{}',
  metadata jsonb not null default '{}',
  primary key (context_subtype, section_key)
);

comment on table public.context_subtype_sections is
  'R.5A.B.4C: secciones visibles por actor_subtype (context). Descriptor (B.7) las filtra por my_permissions del actor + status del context.';

create index idx_context_subtype_sections_section on public.context_subtype_sections(section_key);
create index idx_context_subtype_sections_subtype on public.context_subtype_sections(context_subtype);

alter table public.context_subtype_sections enable row level security;
create policy "context_subtype_sections_read_all"
  on public.context_subtype_sections for select to authenticated using (true);
grant select on public.context_subtype_sections to authenticated;

-- ----------------------------------------------------------------------------
-- 3. Seed: subtype -> section (founder spec sec 4.9 del plan)
-- ----------------------------------------------------------------------------
insert into public.context_subtype_sections (context_subtype, section_key, sort_order, required_permission) values
  -- family: todas las secciones
  ('family','overview',1,null), ('family','people',2,null), ('family','resources',3,null),
  ('family','money',4,null), ('family','calendar',10,null),
  ('family','governance',11,'decisions.view'), ('family','documents',12,null),
  ('family','obligations',13,null), ('family','activity',200,null),
  ('family','settings',900,'context.manage'),

  -- company: sin calendar/obligations explicit; mas governance focus
  ('company','overview',1,null), ('company','people',2,null), ('company','resources',3,null),
  ('company','money',4,null),
  ('company','governance',11,'decisions.view'), ('company','documents',12,null),
  ('company','activity',200,null),
  ('company','settings',900,'context.manage'),

  -- trip: foco en calendario, documentos, obligations; sin governance
  ('trip','overview',1,null), ('trip','people',2,null), ('trip','resources',3,null),
  ('trip','money',4,null), ('trip','calendar',10,null),
  ('trip','documents',12,null), ('trip','obligations',13,null),
  ('trip','activity',200,null),
  ('trip','settings',900,'context.manage'),

  -- project: sin money/obligations explicit; foco governance + calendar
  ('project','overview',1,null), ('project','people',2,null), ('project','resources',3,null),
  ('project','calendar',10,null),
  ('project','governance',11,'decisions.view'), ('project','documents',12,null),
  ('project','activity',200,null),
  ('project','settings',900,'context.manage'),

  -- community: full menos obligations
  ('community','overview',1,null), ('community','people',2,null), ('community','resources',3,null),
  ('community','money',4,null), ('community','calendar',10,null),
  ('community','governance',11,'decisions.view'), ('community','documents',12,null),
  ('community','activity',200,null),
  ('community','settings',900,'context.manage'),

  -- trust: foco governance + money + obligations; sin calendar
  ('trust','overview',1,null), ('trust','people',2,null), ('trust','resources',3,null),
  ('trust','money',4,null),
  ('trust','governance',11,'decisions.view'), ('trust','documents',12,null),
  ('trust','obligations',13,null),
  ('trust','activity',200,null),
  ('trust','settings',900,'context.manage'),

  -- friend_group (legacy): minimo casual
  ('friend_group','overview',1,null), ('friend_group','people',2,null),
  ('friend_group','money',4,null), ('friend_group','calendar',10,null),
  ('friend_group','activity',200,null),
  ('friend_group','settings',900,'context.manage'),

  -- generic (fallback): minimo universal para contextos sin subtype mapeado
  ('generic','overview',1,null), ('generic','people',2,null), ('generic','resources',3,null),
  ('generic','activity',200,null),
  ('generic','settings',900,'context.manage')
on conflict (context_subtype, section_key) do nothing;

-- ----------------------------------------------------------------------------
-- 4. context_dashboard_widgets (12 widgets founder canon)
-- ----------------------------------------------------------------------------
create table public.context_dashboard_widgets (
  widget_key text primary key,
  display_name text not null,
  description text,
  icon text,
  data_source_key text,
  metadata jsonb not null default '{}',
  created_at timestamptz not null default now()
);

comment on table public.context_dashboard_widgets is
  'R.5A.B.4C: catalogo de widgets de hero del ContextDetail. data_source_key apunta al endpoint de datos.';

insert into public.context_dashboard_widgets (widget_key, display_name, icon, data_source_key) values
  ('next_event',             'Proximo evento',       'calendar.circle',              'context.next_event'),
  ('open_decisions',         'Decisiones abiertas',  'questionmark.circle',          'context.open_decisions'),
  ('open_obligations',       'Obligaciones',         'doc.text.below.ecg',           'context.open_obligations'),
  ('cash_balance',           'Balance',              'banknote.fill',                'context.cash_balance'),
  ('member_count_summary',   'Miembros',             'person.3.fill',                'context.member_count_summary'),
  ('active_projects',        'Proyectos activos',    'rectangle.stack.fill',         'context.active_projects'),
  ('recent_activity',        'Actividad reciente',   'bolt.circle',                  'context.recent_activity'),
  ('critical_resources',     'Recursos criticos',    'cube.fill',                    'context.critical_resources'),
  ('pending_invitations',    'Invitaciones',         'envelope.badge',               'context.pending_invitations'),
  ('upcoming_reservations',  'Proximas reservas',    'calendar.badge.clock',         'context.upcoming_reservations'),
  ('budget_progress',        'Presupuesto',          'chart.pie.fill',               'context.budget_progress'),
  ('settlement_status',      'Liquidacion',          'checkmark.seal.fill',          'context.settlement_status')
on conflict (widget_key) do nothing;

alter table public.context_dashboard_widgets enable row level security;
create policy "context_dashboard_widgets_read_all"
  on public.context_dashboard_widgets for select to authenticated using (true);
grant select on public.context_dashboard_widgets to authenticated;

-- ----------------------------------------------------------------------------
-- 5. context_subtype_widgets (matriz subtype -> widget)
-- ----------------------------------------------------------------------------
create table public.context_subtype_widgets (
  context_subtype text not null,
  widget_key text not null references public.context_dashboard_widgets(widget_key) on update cascade on delete cascade,
  sort_order int not null default 100,
  required_permission text,
  metadata jsonb not null default '{}',
  primary key (context_subtype, widget_key)
);

comment on table public.context_subtype_widgets is
  'R.5A.B.4C: widgets por actor_subtype (context). Descriptor (B.7) filtra por permisos.';

create index idx_context_subtype_widgets_widget on public.context_subtype_widgets(widget_key);
create index idx_context_subtype_widgets_subtype on public.context_subtype_widgets(context_subtype);

alter table public.context_subtype_widgets enable row level security;
create policy "context_subtype_widgets_read_all"
  on public.context_subtype_widgets for select to authenticated using (true);
grant select on public.context_subtype_widgets to authenticated;

-- ----------------------------------------------------------------------------
-- 6. Seed: subtype -> widget (founder spec sec 4.9)
-- ----------------------------------------------------------------------------
insert into public.context_subtype_widgets (context_subtype, widget_key, sort_order) values
  ('family','next_event',1), ('family','cash_balance',2),
  ('family','open_obligations',3), ('family','recent_activity',4),

  ('company','cash_balance',1), ('company','open_decisions',2),
  ('company','active_projects',3), ('company','critical_resources',4),

  ('trip','budget_progress',1), ('trip','upcoming_reservations',2),
  ('trip','member_count_summary',3), ('trip','recent_activity',4),

  ('project','active_projects',1), ('project','open_decisions',2),
  ('project','critical_resources',3), ('project','recent_activity',4),

  ('community','next_event',1), ('community','member_count_summary',2),
  ('community','pending_invitations',3), ('community','recent_activity',4),

  ('trust','cash_balance',1), ('trust','critical_resources',2),
  ('trust','open_decisions',3), ('trust','recent_activity',4),

  ('friend_group','next_event',1), ('friend_group','cash_balance',2),
  ('friend_group','open_obligations',3), ('friend_group','recent_activity',4),

  ('generic','recent_activity',1)
on conflict (context_subtype, widget_key) do nothing;
