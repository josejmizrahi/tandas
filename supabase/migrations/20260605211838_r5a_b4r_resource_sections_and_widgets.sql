-- ============================================================================
-- R.5A.B.4R — RESOURCE sections + widgets (descriptor-driven UI foundation)
-- ============================================================================
-- Crea 4 tablas:
--   resource_section_catalog       (47 secciones canonicas)
--   resource_subtype_sections      (matriz subtype -> section con sort + caps)
--   resource_dashboard_widgets     (17 widgets canonicos)
--   resource_subtype_widgets       (matriz subtype -> widget)
--
-- Las secciones declaran required_capability + required_rights[] + visible_when_status[]
-- para que el descriptor (B.6) filtre dinamicamente. Cero impacto runtime:
-- ningun RPC vivo lo consulta todavia.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. resource_section_catalog (47 secciones)
-- ----------------------------------------------------------------------------
create table public.resource_section_catalog (
  section_key text primary key,
  display_name text not null,
  description text,
  icon text,
  default_sort_order int not null default 100,
  metadata jsonb not null default '{}',
  created_at timestamptz not null default now()
);

comment on table public.resource_section_catalog is
  'R.5A.B.4R: catalogo universal de secciones UI de Resource. Filtradas por descriptor (B.6).';

insert into public.resource_section_catalog (section_key, display_name, icon, default_sort_order) values
  ('overview',             'Resumen',                 'rectangle.grid.1x2',           5),
  ('details',              'Detalles',                'info.circle',                  10),
  ('balance',              'Balance',                 'banknote',                     15),
  ('movements',            'Movimientos',             'arrow.up.arrow.down',          20),
  ('member_balances',      'Balances por miembro',    'person.2',                     25),
  ('expenses',             'Gastos',                  'creditcard',                   28),
  ('contributions',        'Aportaciones',            'arrow.down.circle',            29),
  ('fines',                'Multas',                  'exclamationmark.triangle',     30),
  ('ious',                 'IOUs',                    'arrow.left.arrow.right',       31),
  ('settlements',          'Liquidaciones',           'checkmark.seal',               32),
  ('attendees',            'Asistentes',              'person.3',                     35),
  ('rsvp',                 'RSVP',                    'envelope',                     37),
  ('host',                 'Anfitrion',               'person.crop.circle.badge.checkmark', 39),
  ('recurrence',           'Recurrencia',             'arrow.triangle.2.circlepath',  40),
  ('availability',         'Disponibilidad',          'calendar.badge.clock',         42),
  ('reservations',         'Reservaciones',           'calendar',                     43),
  ('calendar',             'Calendario',              'calendar.day.timeline.left',   44),
  ('access',               'Acceso',                  'key',                          46),
  ('rights',               'Derechos',                'person.badge.key',             48),
  ('rules',                'Reglas',                  'list.bullet.rectangle',        50),
  ('decisions',            'Decisiones',              'questionmark.circle',          52),
  ('obligations',          'Obligaciones',            'doc.text.below.ecg',           54),
  ('documents',            'Documentos',              'doc',                          56),
  ('versions',             'Versiones',               'clock.arrow.circlepath',       58),
  ('approvals',            'Aprobaciones',            'checkmark.circle',             60),
  ('signatures',           'Firmas',                  'signature',                    62),
  ('maintenance',          'Mantenimiento',           'wrench.and.screwdriver',       64),
  ('condition',            'Condicion',               'gauge.medium',                 66),
  ('usage_history',        'Historial de uso',        'clock',                        68),
  ('custody',              'Custodia',                'hand.raised',                  70),
  ('payments',             'Pagos',                   'creditcard.and.123',           72),
  ('disputes',             'Disputas',                'flag',                         74),
  ('itinerary',            'Itinerario',              'map',                          76),
  ('tasks',                'Tareas',                  'checklist',                    78),
  ('budget',               'Presupuesto',             'chart.pie',                    80),
  ('checklist',            'Checklist',               'checkmark.rectangle.stack',    82),
  ('stock',                'Stock',                   'shippingbox',                  84),
  ('inventory_movements',  'Movimientos de inventario','arrow.left.arrow.right.square',86),
  ('location',             'Ubicacion',               'mappin.and.ellipse',           88),
  ('insurance',            'Seguro',                  'shield',                       90),
  ('taxes',                'Impuestos',               'percent',                      92),
  ('valuation',            'Valuacion',               'chart.line.uptrend.xyaxis',    94),
  ('income',               'Ingresos',                'arrow.up.circle',              95),
  ('leases',               'Arrendamientos',          'key.viewfinder',               96),
  ('relations',            'Relaciones',              'link',                         98),
  ('activity',             'Actividad',               'bolt',                         200),
  ('settings',             'Configuracion',           'gearshape',                    900)
on conflict (section_key) do nothing;

alter table public.resource_section_catalog enable row level security;
create policy "resource_section_catalog_read_all"
  on public.resource_section_catalog for select to authenticated using (true);
grant select on public.resource_section_catalog to authenticated;

-- ----------------------------------------------------------------------------
-- 2. resource_subtype_sections (matriz subtype -> section)
-- ----------------------------------------------------------------------------
create table public.resource_subtype_sections (
  subtype_key text not null references public.resource_subtypes(subtype_key) on update cascade on delete cascade,
  section_key text not null references public.resource_section_catalog(section_key) on update cascade on delete cascade,
  sort_order int not null default 100,
  required_capability text references public.resource_capabilities_catalog(capability_key) on update cascade on delete restrict,
  required_rights text[] not null default '{}',
  visible_when_status text[] not null default '{}',
  metadata jsonb not null default '{}',
  primary key (subtype_key, section_key)
);

comment on table public.resource_subtype_sections is
  'R.5A.B.4R: secciones visibles por subtype. Descriptor (B.6) las filtra por effective_capabilities, rights del actor y status del resource.';

create index idx_subtype_sections_section on public.resource_subtype_sections(section_key);

alter table public.resource_subtype_sections enable row level security;
create policy "resource_subtype_sections_read_all"
  on public.resource_subtype_sections for select to authenticated using (true);
grant select on public.resource_subtype_sections to authenticated;

-- ----------------------------------------------------------------------------
-- 3. Seed: subtype -> section + required_capability hints
-- ----------------------------------------------------------------------------
insert into public.resource_subtype_sections (subtype_key, section_key, sort_order, required_capability) values
  -- real_estate
  ('primary_residence','overview',5,null), ('primary_residence','details',10,null),
  ('primary_residence','location',15,'location_bound'), ('primary_residence','documents',20,'documentable'),
  ('primary_residence','maintenance',25,'maintainable'), ('primary_residence','insurance',30,'insurable'),
  ('primary_residence','taxes',35,'taxable'), ('primary_residence','valuation',40,null),
  ('primary_residence','rights',45,'ownable'), ('primary_residence','relations',90,null),
  ('primary_residence','activity',200,null), ('primary_residence','settings',900,null),

  ('vacation_home','overview',5,null), ('vacation_home','details',10,null),
  ('vacation_home','location',15,'location_bound'), ('vacation_home','availability',20,'reservable'),
  ('vacation_home','reservations',22,'reservable'), ('vacation_home','calendar',24,'reservable'),
  ('vacation_home','documents',30,'documentable'), ('vacation_home','maintenance',35,'maintainable'),
  ('vacation_home','insurance',40,'insurable'), ('vacation_home','taxes',45,'taxable'),
  ('vacation_home','valuation',50,null), ('vacation_home','rights',55,'ownable'),
  ('vacation_home','relations',90,null), ('vacation_home','activity',200,null), ('vacation_home','settings',900,null),

  ('apartment','overview',5,null), ('apartment','details',10,null),
  ('apartment','location',15,'location_bound'), ('apartment','reservations',20,'reservable'),
  ('apartment','documents',30,'documentable'), ('apartment','maintenance',35,'maintainable'),
  ('apartment','insurance',40,'insurable'), ('apartment','taxes',45,'taxable'),
  ('apartment','rights',50,'ownable'), ('apartment','relations',90,null),
  ('apartment','activity',200,null), ('apartment','settings',900,null),

  ('office','overview',5,null), ('office','details',10,null),
  ('office','location',15,'location_bound'), ('office','access',20,'access_controlled'),
  ('office','reservations',25,'reservable'), ('office','leases',30,'leasable'),
  ('office','documents',35,'documentable'), ('office','maintenance',40,'maintainable'),
  ('office','insurance',45,'insurable'), ('office','taxes',50,'taxable'),
  ('office','rights',55,'ownable'), ('office','relations',90,null),
  ('office','activity',200,null), ('office','settings',900,null),

  ('warehouse','overview',5,null), ('warehouse','details',10,null),
  ('warehouse','location',15,'location_bound'), ('warehouse','access',18,'access_controlled'),
  ('warehouse','leases',20,'leasable'), ('warehouse','income',22,'income_generating'),
  ('warehouse','documents',30,'documentable'), ('warehouse','maintenance',35,'maintainable'),
  ('warehouse','insurance',40,'insurable'), ('warehouse','taxes',45,'taxable'),
  ('warehouse','valuation',50,null), ('warehouse','rights',55,'ownable'),
  ('warehouse','relations',90,null), ('warehouse','activity',200,null), ('warehouse','settings',900,null),

  ('land','overview',5,null), ('land','details',10,null),
  ('land','location',15,'location_bound'), ('land','documents',20,'documentable'),
  ('land','insurance',30,'insurable'), ('land','taxes',35,'taxable'),
  ('land','valuation',40,null), ('land','rights',45,'ownable'),
  ('land','relations',90,null), ('land','activity',200,null), ('land','settings',900,null),

  ('rental_property','overview',5,null), ('rental_property','details',10,null),
  ('rental_property','location',15,'location_bound'), ('rental_property','leases',20,'leasable'),
  ('rental_property','income',22,'income_generating'), ('rental_property','payments',25,'payable'),
  ('rental_property','documents',30,'documentable'), ('rental_property','maintenance',35,'maintainable'),
  ('rental_property','insurance',40,'insurable'), ('rental_property','taxes',45,'taxable'),
  ('rental_property','valuation',50,null), ('rental_property','rights',55,'ownable'),
  ('rental_property','relations',90,null), ('rental_property','activity',200,null), ('rental_property','settings',900,null),

  ('industrial_property','overview',5,null), ('industrial_property','details',10,null),
  ('industrial_property','location',15,'location_bound'), ('industrial_property','access',18,'access_controlled'),
  ('industrial_property','leases',20,'leasable'), ('industrial_property','income',22,'income_generating'),
  ('industrial_property','documents',30,'documentable'), ('industrial_property','maintenance',35,'maintainable'),
  ('industrial_property','insurance',40,'insurable'), ('industrial_property','taxes',45,'taxable'),
  ('industrial_property','valuation',50,null), ('industrial_property','rights',55,'ownable'),
  ('industrial_property','relations',90,null), ('industrial_property','activity',200,null), ('industrial_property','settings',900,null),

  -- financial
  ('money_pool','overview',5,null), ('money_pool','balance',10,null),
  ('money_pool','movements',15,null), ('money_pool','member_balances',20,'splittable'),
  ('money_pool','expenses',22,'payable'), ('money_pool','contributions',24,'payable'),
  ('money_pool','fines',26,null), ('money_pool','ious',28,null),
  ('money_pool','settlements',30,'settleable'), ('money_pool','documents',35,'documentable'),
  ('money_pool','decisions',40,'governable'), ('money_pool','rights',50,'ownable'),
  ('money_pool','relations',90,null), ('money_pool','activity',200,null), ('money_pool','settings',900,null),

  ('bank_account','overview',5,null), ('bank_account','balance',10,null),
  ('bank_account','movements',15,null), ('bank_account','payments',20,'payable'),
  ('bank_account','documents',30,'documentable'), ('bank_account','rights',40,'ownership_trackable'),
  ('bank_account','relations',90,null), ('bank_account','activity',200,null), ('bank_account','settings',900,null),

  ('investment_account','overview',5,null), ('investment_account','balance',10,null),
  ('investment_account','movements',15,null), ('investment_account','valuation',20,null),
  ('investment_account','income',25,null), ('investment_account','documents',30,'documentable'),
  ('investment_account','rights',40,'ownership_trackable'), ('investment_account','relations',90,null),
  ('investment_account','activity',200,null), ('investment_account','settings',900,null),

  ('crypto_wallet','overview',5,null), ('crypto_wallet','balance',10,null),
  ('crypto_wallet','movements',15,null), ('crypto_wallet','access',18,'access_controlled'),
  ('crypto_wallet','custody',20,'custodiable'), ('crypto_wallet','documents',30,'documentable'),
  ('crypto_wallet','rights',40,'ownership_trackable'), ('crypto_wallet','relations',90,null),
  ('crypto_wallet','activity',200,null), ('crypto_wallet','settings',900,null),

  ('trust_fund','overview',5,null), ('trust_fund','balance',10,null),
  ('trust_fund','movements',15,null), ('trust_fund','valuation',20,null),
  ('trust_fund','income',25,null), ('trust_fund','documents',30,'documentable'),
  ('trust_fund','decisions',35,'governable'), ('trust_fund','rights',40,'ownership_trackable'),
  ('trust_fund','relations',90,null), ('trust_fund','activity',200,null), ('trust_fund','settings',900,null),

  -- vehicle
  ('car','overview',5,null), ('car','details',10,null),
  ('car','location',15,'location_bound'), ('car','reservations',20,'reservable'),
  ('car','custody',25,'custodiable'), ('car','condition',30,'condition_trackable'),
  ('car','maintenance',35,'maintainable'), ('car','usage_history',40,null),
  ('car','documents',45,'documentable'), ('car','insurance',50,'insurable'),
  ('car','rights',55,'ownable'), ('car','relations',90,null),
  ('car','activity',200,null), ('car','settings',900,null),

  ('truck','overview',5,null), ('truck','details',10,null),
  ('truck','reservations',20,'reservable'), ('truck','custody',25,'custodiable'),
  ('truck','condition',30,'condition_trackable'), ('truck','maintenance',35,'maintainable'),
  ('truck','usage_history',40,null), ('truck','leases',45,'leasable'),
  ('truck','documents',50,'documentable'), ('truck','insurance',55,'insurable'),
  ('truck','rights',60,'ownable'), ('truck','relations',90,null),
  ('truck','activity',200,null), ('truck','settings',900,null),

  ('machine','overview',5,null), ('machine','details',10,null),
  ('machine','custody',20,'custodiable'), ('machine','condition',25,'condition_trackable'),
  ('machine','maintenance',30,'maintainable'), ('machine','usage_history',35,null),
  ('machine','documents',45,'documentable'), ('machine','insurance',50,'insurable'),
  ('machine','rights',55,'ownable'), ('machine','relations',90,null),
  ('machine','activity',200,null), ('machine','settings',900,null),

  ('tool','overview',5,null), ('tool','details',10,null),
  ('tool','reservations',20,'reservable'), ('tool','custody',25,'custodiable'),
  ('tool','condition',30,'condition_trackable'), ('tool','maintenance',35,'maintainable'),
  ('tool','documents',45,'documentable'), ('tool','rights',55,'ownable'),
  ('tool','relations',90,null), ('tool','activity',200,null), ('tool','settings',900,null),

  -- document
  ('contract','overview',5,null), ('contract','details',10,null),
  ('contract','versions',20,'versionable'), ('contract','approvals',25,'approvable'),
  ('contract','signatures',30,'signable'), ('contract','documents',35,'documentable'),
  ('contract','relations',90,null), ('contract','activity',200,null), ('contract','settings',900,null),

  ('receipt','overview',5,null), ('receipt','details',10,null),
  ('receipt','documents',30,'documentable'), ('receipt','relations',90,null),
  ('receipt','activity',200,null), ('receipt','settings',900,null),

  ('statement','overview',5,null), ('statement','details',10,null),
  ('statement','versions',20,'versionable'), ('statement','documents',30,'documentable'),
  ('statement','relations',90,null), ('statement','activity',200,null), ('statement','settings',900,null),

  ('certificate','overview',5,null), ('certificate','details',10,null),
  ('certificate','versions',20,'versionable'), ('certificate','documents',30,'documentable'),
  ('certificate','relations',90,null), ('certificate','activity',200,null), ('certificate','settings',900,null),

  ('policy','overview',5,null), ('policy','details',10,null),
  ('policy','versions',20,'versionable'), ('policy','insurance',25,'insurable'),
  ('policy','documents',30,'documentable'), ('policy','relations',90,null),
  ('policy','activity',200,null), ('policy','settings',900,null),

  -- event
  ('recurring_event','overview',5,null), ('recurring_event','details',10,null),
  ('recurring_event','recurrence',15,'recurring'), ('recurring_event','attendees',20,null),
  ('recurring_event','rsvp',22,null), ('recurring_event','host',24,null),
  ('recurring_event','reservations',30,'reservable'), ('recurring_event','expenses',35,'payable'),
  ('recurring_event','rules',40,'rule_bound'), ('recurring_event','decisions',45,'votable'),
  ('recurring_event','relations',90,null), ('recurring_event','activity',200,null), ('recurring_event','settings',900,null),

  ('meeting','overview',5,null), ('meeting','details',10,null),
  ('meeting','attendees',20,null), ('meeting','rsvp',22,null),
  ('meeting','host',24,null), ('meeting','reservations',30,'reservable'),
  ('meeting','relations',90,null), ('meeting','activity',200,null), ('meeting','settings',900,null),

  ('dinner','overview',5,null), ('dinner','details',10,null),
  ('dinner','attendees',20,null), ('dinner','host',22,null),
  ('dinner','expenses',30,'payable'), ('dinner','relations',90,null),
  ('dinner','activity',200,null), ('dinner','settings',900,null),

  ('community_event','overview',5,null), ('community_event','details',10,null),
  ('community_event','attendees',20,null), ('community_event','rsvp',22,null),
  ('community_event','reservations',30,'reservable'), ('community_event','expenses',35,'payable'),
  ('community_event','relations',90,null), ('community_event','activity',200,null), ('community_event','settings',900,null),

  -- obligation
  ('iou','overview',5,null), ('iou','details',10,null),
  ('iou','payments',20,'payable'), ('iou','disputes',25,'disputable'),
  ('iou','settlements',30,'settleable'), ('iou','relations',90,null),
  ('iou','activity',200,null), ('iou','settings',900,null),

  ('fine','overview',5,null), ('fine','details',10,null),
  ('fine','payments',20,'payable'), ('fine','disputes',25,'disputable'),
  ('fine','settlements',30,'settleable'), ('fine','relations',90,null),
  ('fine','activity',200,null), ('fine','settings',900,null),

  ('loan','overview',5,null), ('loan','details',10,null),
  ('loan','payments',20,'payable'), ('loan','documents',25,'documentable'),
  ('loan','disputes',30,'disputable'), ('loan','settlements',35,'settleable'),
  ('loan','relations',90,null), ('loan','activity',200,null), ('loan','settings',900,null),

  ('contribution','overview',5,null), ('contribution','details',10,null),
  ('contribution','payments',20,'payable'), ('contribution','settlements',30,'settleable'),
  ('contribution','relations',90,null), ('contribution','activity',200,null), ('contribution','settings',900,null),

  ('dues','overview',5,null), ('dues','details',10,null),
  ('dues','recurrence',15,'recurring'), ('dues','payments',20,'payable'),
  ('dues','settlements',30,'settleable'), ('dues','relations',90,null),
  ('dues','activity',200,null), ('dues','settings',900,null),

  -- right / inventory / project / trip / space / digital_asset / service / membership / equipment / agreement / generic
  ('generic_right','overview',5,null), ('generic_right','details',10,null),
  ('generic_right','rights',20,null), ('generic_right','relations',90,null),
  ('generic_right','activity',200,null), ('generic_right','settings',900,null),

  ('inventory_item','overview',5,null), ('inventory_item','details',10,null),
  ('inventory_item','location',15,null), ('inventory_item','stock',20,'inventory_tracked'),
  ('inventory_item','inventory_movements',25,'inventory_tracked'), ('inventory_item','documents',30,'documentable'),
  ('inventory_item','relations',90,null), ('inventory_item','activity',200,null), ('inventory_item','settings',900,null),

  ('internal_project','overview',5,null), ('internal_project','details',10,null),
  ('internal_project','tasks',20,null), ('internal_project','checklist',25,null),
  ('internal_project','budget',30,null), ('internal_project','decisions',35,'governable'),
  ('internal_project','rules',40,'rule_bound'), ('internal_project','documents',45,'documentable'),
  ('internal_project','relations',90,null), ('internal_project','activity',200,null), ('internal_project','settings',900,null),

  ('group_trip','overview',5,null), ('group_trip','details',10,null),
  ('group_trip','itinerary',15,null), ('group_trip','attendees',20,null),
  ('group_trip','budget',25,null), ('group_trip','expenses',30,'payable'),
  ('group_trip','reservations',35,'reservable'), ('group_trip','documents',40,'documentable'),
  ('group_trip','relations',90,null), ('group_trip','activity',200,null), ('group_trip','settings',900,null),

  ('generic_space','overview',5,null), ('generic_space','details',10,null),
  ('generic_space','location',15,'location_bound'), ('generic_space','availability',20,'reservable'),
  ('generic_space','reservations',25,'reservable'), ('generic_space','calendar',30,null),
  ('generic_space','access',35,'access_controlled'), ('generic_space','relations',90,null),
  ('generic_space','activity',200,null), ('generic_space','settings',900,null),

  ('generic_digital_asset','overview',5,null), ('generic_digital_asset','details',10,null),
  ('generic_digital_asset','custody',20,'custodiable'), ('generic_digital_asset','valuation',25,null),
  ('generic_digital_asset','documents',30,'documentable'), ('generic_digital_asset','rights',40,'ownable'),
  ('generic_digital_asset','relations',90,null), ('generic_digital_asset','activity',200,null), ('generic_digital_asset','settings',900,null),

  ('generic_service','overview',5,null), ('generic_service','details',10,null),
  ('generic_service','recurrence',15,'recurring'), ('generic_service','payments',20,'payable'),
  ('generic_service','documents',30,'documentable'), ('generic_service','relations',90,null),
  ('generic_service','activity',200,null), ('generic_service','settings',900,null),

  ('generic_membership','overview',5,null), ('generic_membership','details',10,null),
  ('generic_membership','payments',20,'payable'), ('generic_membership','documents',30,'documentable'),
  ('generic_membership','relations',90,null), ('generic_membership','activity',200,null), ('generic_membership','settings',900,null),

  ('generic_equipment','overview',5,null), ('generic_equipment','details',10,null),
  ('generic_equipment','location',15,null), ('generic_equipment','reservations',20,'reservable'),
  ('generic_equipment','custody',25,'custodiable'), ('generic_equipment','condition',30,'condition_trackable'),
  ('generic_equipment','maintenance',35,'maintainable'), ('generic_equipment','documents',45,'documentable'),
  ('generic_equipment','rights',55,'ownable'), ('generic_equipment','relations',90,null),
  ('generic_equipment','activity',200,null), ('generic_equipment','settings',900,null),

  ('generic_agreement','overview',5,null), ('generic_agreement','details',10,null),
  ('generic_agreement','versions',20,'versionable'), ('generic_agreement','approvals',25,'approvable'),
  ('generic_agreement','signatures',30,'signable'), ('generic_agreement','documents',35,'documentable'),
  ('generic_agreement','relations',90,null), ('generic_agreement','activity',200,null), ('generic_agreement','settings',900,null),

  ('generic_resource','overview',5,null), ('generic_resource','details',10,null),
  ('generic_resource','relations',90,null), ('generic_resource','activity',200,null), ('generic_resource','settings',900,null)
on conflict (subtype_key, section_key) do nothing;

-- ----------------------------------------------------------------------------
-- 4. resource_dashboard_widgets (17 widgets)
-- ----------------------------------------------------------------------------
create table public.resource_dashboard_widgets (
  widget_key text primary key,
  display_name text not null,
  description text,
  icon text,
  data_source_key text,
  metadata jsonb not null default '{}',
  created_at timestamptz not null default now()
);

comment on table public.resource_dashboard_widgets is
  'R.5A.B.4R: catalogo de widgets de hero del ResourceDetail. data_source_key identifica la fuente; iOS los renderiza con su componente.';

insert into public.resource_dashboard_widgets (widget_key, display_name, icon, data_source_key) values
  ('balance_summary',         'Balance',              'banknote.fill',                'resource.balance'),
  ('open_obligations',        'Obligaciones',         'doc.text.below.ecg.fill',      'resource.open_obligations'),
  ('upcoming_reservations',   'Proximas reservas',    'calendar.badge.clock',         'resource.upcoming_reservations'),
  ('next_event',              'Proximo evento',       'calendar.circle',              'resource.next_event'),
  ('recent_activity',         'Actividad reciente',   'bolt.circle',                  'resource.recent_activity'),
  ('resource_value',          'Valor',                'chart.line.uptrend.xyaxis',    'resource.value'),
  ('insurance_status',        'Seguro',               'shield.fill',                  'resource.insurance_status'),
  ('tax_status',              'Impuestos',            'percent',                      'resource.tax_status'),
  ('maintenance_status',      'Mantenimiento',        'wrench.and.screwdriver.fill',  'resource.maintenance_status'),
  ('document_status',         'Documentos',           'doc.fill',                     'resource.document_status'),
  ('reservation_status',      'Reservas',             'calendar',                     'resource.reservation_status'),
  ('member_balance_summary',  'Balances por miembro', 'person.2.fill',                'resource.member_balance_summary'),
  ('settlement_status',       'Liquidacion',          'checkmark.seal.fill',          'resource.settlement_status'),
  ('condition_status',        'Condicion',            'gauge.medium',                 'resource.condition_status'),
  ('custody_status',          'Custodia',             'hand.raised.fill',             'resource.custody_status'),
  ('income_summary',          'Ingresos',             'arrow.up.circle.fill',         'resource.income_summary'),
  ('lease_status',            'Arrendamiento',        'key.fill',                     'resource.lease_status')
on conflict (widget_key) do nothing;

alter table public.resource_dashboard_widgets enable row level security;
create policy "resource_dashboard_widgets_read_all"
  on public.resource_dashboard_widgets for select to authenticated using (true);
grant select on public.resource_dashboard_widgets to authenticated;

-- ----------------------------------------------------------------------------
-- 5. resource_subtype_widgets (matriz subtype -> widget)
-- ----------------------------------------------------------------------------
create table public.resource_subtype_widgets (
  subtype_key text not null references public.resource_subtypes(subtype_key) on update cascade on delete cascade,
  widget_key text not null references public.resource_dashboard_widgets(widget_key) on update cascade on delete cascade,
  sort_order int not null default 100,
  required_capability text references public.resource_capabilities_catalog(capability_key) on update cascade on delete restrict,
  metadata jsonb not null default '{}',
  primary key (subtype_key, widget_key)
);

comment on table public.resource_subtype_widgets is
  'R.5A.B.4R: widgets por subtype. Descriptor (B.6) filtra por effective_capabilities + permisos.';

create index idx_subtype_widgets_widget on public.resource_subtype_widgets(widget_key);

alter table public.resource_subtype_widgets enable row level security;
create policy "resource_subtype_widgets_read_all"
  on public.resource_subtype_widgets for select to authenticated using (true);
grant select on public.resource_subtype_widgets to authenticated;

-- ----------------------------------------------------------------------------
-- 6. Seed: subtype -> widget
-- ----------------------------------------------------------------------------
insert into public.resource_subtype_widgets (subtype_key, widget_key, sort_order, required_capability) values
  -- real_estate
  ('primary_residence','resource_value',1,null), ('primary_residence','maintenance_status',2,'maintainable'),
  ('primary_residence','insurance_status',3,'insurable'), ('primary_residence','tax_status',4,'taxable'),
  ('primary_residence','document_status',5,'documentable'), ('primary_residence','recent_activity',6,null),

  ('vacation_home','upcoming_reservations',1,'reservable'), ('vacation_home','resource_value',2,null),
  ('vacation_home','maintenance_status',3,'maintainable'), ('vacation_home','insurance_status',4,'insurable'),
  ('vacation_home','income_summary',5,'income_generating'), ('vacation_home','recent_activity',6,null),

  ('apartment','resource_value',1,null), ('apartment','upcoming_reservations',2,'reservable'),
  ('apartment','maintenance_status',3,'maintainable'), ('apartment','insurance_status',4,'insurable'),
  ('apartment','document_status',5,'documentable'), ('apartment','recent_activity',6,null),

  ('office','resource_value',1,null), ('office','lease_status',2,'leasable'),
  ('office','maintenance_status',3,'maintainable'), ('office','insurance_status',4,'insurable'),
  ('office','document_status',5,'documentable'), ('office','recent_activity',6,null),

  ('warehouse','resource_value',1,null), ('warehouse','lease_status',2,'leasable'),
  ('warehouse','income_summary',3,'income_generating'), ('warehouse','maintenance_status',4,'maintainable'),
  ('warehouse','insurance_status',5,'insurable'), ('warehouse','recent_activity',6,null),

  ('land','resource_value',1,null), ('land','tax_status',2,'taxable'),
  ('land','document_status',3,'documentable'), ('land','insurance_status',4,'insurable'),
  ('land','recent_activity',6,null),

  ('rental_property','income_summary',1,'income_generating'), ('rental_property','lease_status',2,'leasable'),
  ('rental_property','resource_value',3,null), ('rental_property','maintenance_status',4,'maintainable'),
  ('rental_property','insurance_status',5,'insurable'), ('rental_property','recent_activity',6,null),

  ('industrial_property','income_summary',1,'income_generating'), ('industrial_property','lease_status',2,'leasable'),
  ('industrial_property','resource_value',3,null), ('industrial_property','maintenance_status',4,'maintainable'),
  ('industrial_property','insurance_status',5,'insurable'), ('industrial_property','recent_activity',6,null),

  -- financial
  ('money_pool','balance_summary',1,null), ('money_pool','recent_activity',2,null),
  ('money_pool','open_obligations',3,null), ('money_pool','member_balance_summary',4,'splittable'),
  ('money_pool','settlement_status',5,'settleable'),

  ('bank_account','balance_summary',1,null), ('bank_account','recent_activity',2,null),
  ('bank_account','document_status',3,'documentable'),

  ('investment_account','balance_summary',1,null), ('investment_account','resource_value',2,null),
  ('investment_account','income_summary',3,null), ('investment_account','document_status',4,'documentable'),

  ('crypto_wallet','balance_summary',1,null), ('crypto_wallet','resource_value',2,null),
  ('crypto_wallet','custody_status',3,'custodiable'), ('crypto_wallet','document_status',4,'documentable'),

  ('trust_fund','balance_summary',1,null), ('trust_fund','resource_value',2,null),
  ('trust_fund','income_summary',3,null), ('trust_fund','member_balance_summary',4,'beneficiary_supported'),
  ('trust_fund','document_status',5,'documentable'),

  -- vehicle
  ('car','resource_value',1,null), ('car','maintenance_status',2,'maintainable'),
  ('car','condition_status',3,'condition_trackable'), ('car','custody_status',4,'custodiable'),
  ('car','insurance_status',5,'insurable'),

  ('truck','resource_value',1,null), ('truck','lease_status',2,'leasable'),
  ('truck','maintenance_status',3,'maintainable'), ('truck','condition_status',4,'condition_trackable'),
  ('truck','insurance_status',5,'insurable'),

  ('machine','resource_value',1,null), ('machine','maintenance_status',2,'maintainable'),
  ('machine','condition_status',3,'condition_trackable'), ('machine','insurance_status',4,'insurable'),

  ('tool','maintenance_status',1,'maintainable'), ('tool','condition_status',2,'condition_trackable'),
  ('tool','custody_status',3,'custodiable'),

  -- document
  ('contract','document_status',1,'documentable'), ('contract','recent_activity',2,null),
  ('receipt','document_status',1,'documentable'), ('receipt','recent_activity',2,null),
  ('statement','document_status',1,'documentable'), ('statement','recent_activity',2,null),
  ('certificate','document_status',1,'documentable'), ('certificate','recent_activity',2,null),
  ('policy','document_status',1,'documentable'), ('policy','insurance_status',2,'insurable'),

  -- event
  ('recurring_event','next_event',1,null), ('recurring_event','upcoming_reservations',2,'reservable'),
  ('recurring_event','recent_activity',3,null),
  ('meeting','next_event',1,null), ('meeting','recent_activity',2,null),
  ('dinner','next_event',1,null), ('dinner','recent_activity',2,null),
  ('community_event','next_event',1,null), ('community_event','recent_activity',2,null),

  -- obligation
  ('iou','next_event',1,null), ('iou','recent_activity',2,null),
  ('fine','next_event',1,null), ('fine','recent_activity',2,null),
  ('loan','balance_summary',1,null), ('loan','next_event',2,null),
  ('contribution','next_event',1,null), ('contribution','recent_activity',2,null),
  ('dues','next_event',1,null), ('dues','recent_activity',2,null),

  -- catch-all
  ('generic_right','recent_activity',1,null),
  ('inventory_item','resource_value',1,null), ('inventory_item','recent_activity',2,null),
  ('internal_project','next_event',1,null), ('internal_project','open_obligations',2,null), ('internal_project','recent_activity',3,null),
  ('group_trip','next_event',1,null), ('group_trip','upcoming_reservations',2,'reservable'), ('group_trip','recent_activity',3,null),
  ('generic_space','upcoming_reservations',1,'reservable'), ('generic_space','reservation_status',2,'reservable'), ('generic_space','recent_activity',3,null),
  ('generic_digital_asset','resource_value',1,null), ('generic_digital_asset','custody_status',2,'custodiable'),
  ('generic_service','next_event',1,null), ('generic_service','document_status',2,'documentable'),
  ('generic_membership','document_status',1,'documentable'), ('generic_membership','recent_activity',2,null),
  ('generic_equipment','maintenance_status',1,'maintainable'), ('generic_equipment','condition_status',2,'condition_trackable'),
  ('generic_agreement','document_status',1,'documentable'), ('generic_agreement','recent_activity',2,null),
  ('generic_resource','recent_activity',1,null)
on conflict (subtype_key, widget_key) do nothing;
