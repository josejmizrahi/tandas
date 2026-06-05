-- ============================================================================
-- R.5A.B.0 — RESOURCE CLASSES + SUBTYPES CATALOGS (additive, zero runtime impact)
-- ============================================================================
-- Foundation Lock 2026-06-05: Resource -> Class -> Subtype -> Capabilities ...
-- Esta slice introduce los catalogos base. NO modifica resources, NO toca
-- resource_type, NO cambia comportamiento de RPCs vivos.
--
-- Plan: Plans/Active/R5A_DetailArchitecture.md (sec 3.1 + 4.1 + 4.2).
-- Doctrina: Plans/Doctrine fundamental lock + foundation memory.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. resource_classes
-- ----------------------------------------------------------------------------
create table public.resource_classes (
  class_key text primary key,
  display_name text not null,
  description text,
  icon text,
  metadata jsonb not null default '{}',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.resource_classes is
  'R.5A.B.0: clases canonicas de recurso. Pieza superior de la jerarquia Class->Subtype->Capabilities. resource_type queda como legacy compat.';

create trigger trg_resource_classes_touch
  before update on public.resource_classes
  for each row execute function public.touch_updated_at();

-- ----------------------------------------------------------------------------
-- 2. resource_subtypes
-- ----------------------------------------------------------------------------
create table public.resource_subtypes (
  subtype_key text primary key,
  class_key text not null references public.resource_classes(class_key) on update cascade on delete restrict,
  display_name text not null,
  description text,
  icon text,
  metadata jsonb not null default '{}',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.resource_subtypes is
  'R.5A.B.0: subtipos canonicos por clase. Los subtipos clasifican; el comportamiento sigue viniendo de capabilities + rights.';

create index idx_resource_subtypes_class_key on public.resource_subtypes(class_key);

create trigger trg_resource_subtypes_touch
  before update on public.resource_subtypes
  for each row execute function public.touch_updated_at();

-- ----------------------------------------------------------------------------
-- 3. Seed: 17 clases canonicas (lock founder 2026-06-05)
-- ----------------------------------------------------------------------------
insert into public.resource_classes (class_key, display_name, description, icon) values
  ('real_estate',   'Inmuebles',          'Casas, terrenos, propiedades comerciales',     'house.fill'),
  ('financial',     'Financiero',         'Fondos, cuentas, inversiones',                  'banknote.fill'),
  ('vehicle',       'Vehiculos',          'Autos, camionetas, maquinaria',                 'car.fill'),
  ('equipment',     'Equipo',             'Herramientas y equipos compartidos',            'wrench.and.screwdriver.fill'),
  ('document',      'Documentos',         'Contratos, recibos, certificados',              'doc.fill'),
  ('event',         'Eventos',            'Eventos recurrentes o unicos del grupo',        'calendar'),
  ('obligation',    'Obligaciones',       'IOUs, multas, prestamos, contribuciones',       'creditcard.fill'),
  ('right',         'Derechos',           'Derechos de uso, paso, etc.',                   'key.fill'),
  ('inventory',     'Inventario',         'Stock e inventario rastreable',                 'shippingbox.fill'),
  ('project',       'Proyectos',          'Proyectos internos del contexto',               'rectangle.stack.fill'),
  ('trip',          'Viajes',             'Viajes grupales',                               'airplane'),
  ('space',         'Espacios',           'Espacios fisicos compartidos',                  'building.2.fill'),
  ('digital_asset', 'Activo digital',     'Criptos, dominios, propiedad intelectual',      'externaldrive.fill.badge.icloud'),
  ('service',       'Servicios',          'Servicios contratados o provistos',             'gearshape.fill'),
  ('membership',    'Membresias',         'Membresias y suscripciones',                    'person.badge.key.fill'),
  ('agreement',     'Acuerdos',           'Acuerdos y compromisos',                        'doc.text.fill'),
  ('generic',       'Generico',           'Cualquier recurso sin clase especifica',        'tag.fill')
on conflict (class_key) do nothing;

-- ----------------------------------------------------------------------------
-- 4. Seed: 42 subtipos canonicos (al menos 1 por clase, granular en clases hot)
-- ----------------------------------------------------------------------------
insert into public.resource_subtypes (subtype_key, class_key, display_name, description, icon) values
  -- real_estate (8)
  ('primary_residence',    'real_estate', 'Residencia principal',  'Vivienda principal del actor o familia',         'house.fill'),
  ('vacation_home',        'real_estate', 'Casa vacacional',       'Casa de uso vacacional / reservable',            'sun.max.fill'),
  ('apartment',            'real_estate', 'Departamento',          'Departamento residencial',                       'building.fill'),
  ('office',               'real_estate', 'Oficina',               'Espacio de oficina',                             'building.2.fill'),
  ('warehouse',            'real_estate', 'Bodega',                'Bodega o nave industrial',                       'building.2.crop.circle.fill'),
  ('land',                 'real_estate', 'Terreno',               'Terreno sin construccion',                       'mountain.2.fill'),
  ('rental_property',      'real_estate', 'Propiedad de renta',    'Inmueble dedicado a renta',                      'key.fill'),
  ('industrial_property',  'real_estate', 'Propiedad industrial',  'Inmueble de uso industrial',                     'gearshape.2.fill'),
  -- financial (5)
  ('money_pool',           'financial',   'Fondo comun',           'Pool de dinero compartido del contexto',         'banknote.fill'),
  ('bank_account',         'financial',   'Cuenta bancaria',       'Cuenta bancaria',                                'building.columns.fill'),
  ('investment_account',   'financial',   'Cuenta de inversion',   'Brokerage o cuenta de inversion',                'chart.line.uptrend.xyaxis'),
  ('crypto_wallet',        'financial',   'Wallet de cripto',      'Wallet de criptomonedas',                        'bitcoinsign.circle.fill'),
  ('trust_fund',           'financial',   'Trust fund',            'Trust o vehiculo legal',                         'building.columns.fill'),
  -- vehicle (4)
  ('car',                  'vehicle',     'Auto',                  'Automovil',                                      'car.fill'),
  ('truck',                'vehicle',     'Camioneta',             'Camioneta o pickup',                             'truck.box.fill'),
  ('machine',              'vehicle',     'Maquinaria',            'Maquinaria pesada o de produccion',              'gear.badge'),
  ('tool',                 'vehicle',     'Herramienta',           'Herramienta motorizada o de trabajo',            'wrench.adjustable.fill'),
  -- document (5)
  ('contract',             'document',    'Contrato',              'Contrato legal',                                 'doc.text.fill'),
  ('receipt',              'document',    'Recibo',                'Recibo o comprobante',                           'receipt'),
  ('statement',            'document',    'Estado de cuenta',      'Estado de cuenta o reporte financiero',          'doc.plaintext.fill'),
  ('certificate',          'document',    'Certificado',           'Certificado o constancia',                       'rosette'),
  ('policy',               'document',    'Poliza',                'Poliza de seguro u otra',                        'shield.fill'),
  -- event (4)
  ('recurring_event',      'event',       'Evento recurrente',     'Evento que se repite (cena semanal, junta mensual)', 'calendar.badge.clock'),
  ('meeting',              'event',       'Junta',                 'Junta o reunion puntual',                        'person.3.fill'),
  ('dinner',               'event',       'Cena',                  'Cena del grupo',                                 'fork.knife'),
  ('community_event',      'event',       'Evento comunitario',    'Evento abierto a la comunidad',                  'figure.2.and.child.holdinghands'),
  -- obligation (5)
  ('iou',                  'obligation',  'IOU',                   'I owe you - deuda informal',                     'arrow.left.arrow.right.circle.fill'),
  ('fine',                 'obligation',  'Multa',                 'Multa impuesta por regla',                       'exclamationmark.triangle.fill'),
  ('loan',                 'obligation',  'Prestamo',              'Prestamo formal entre actores',                  'dollarsign.arrow.circlepath'),
  ('contribution',         'obligation',  'Aportacion',            'Aportacion esperada al fondo',                   'arrow.down.circle.fill'),
  ('dues',                 'obligation',  'Cuotas',                'Cuotas recurrentes',                             'calendar.badge.exclamationmark'),
  -- catch-all subtypes (1 por clase restante)
  ('inventory_item',       'inventory',    'Item de inventario',    'Pieza individual rastreada en stock',           'shippingbox.fill'),
  ('internal_project',     'project',      'Proyecto interno',      'Proyecto interno del contexto',                 'rectangle.stack.fill'),
  ('group_trip',           'trip',         'Viaje grupal',          'Viaje organizado por el contexto',              'airplane.departure'),
  ('generic_equipment',    'equipment',    'Equipo generico',       'Equipo sin subtipo especifico',                 'wrench.and.screwdriver.fill'),
  ('generic_space',        'space',        'Espacio generico',      'Espacio fisico compartido',                     'square.split.bottomrightquarter.fill'),
  ('generic_right',        'right',        'Derecho generico',      'Derecho de uso o paso',                         'key.fill'),
  ('generic_digital_asset','digital_asset','Activo digital generico','Activo digital sin subtipo especifico',        'externaldrive.fill.badge.icloud'),
  ('generic_service',      'service',      'Servicio generico',     'Servicio contratado o provisto',                'gearshape.fill'),
  ('generic_membership',   'membership',   'Membresia generica',    'Membresia o suscripcion',                       'person.badge.key.fill'),
  ('generic_agreement',    'agreement',    'Acuerdo generico',      'Acuerdo o compromiso',                          'doc.text.fill'),
  ('generic_resource',     'generic',      'Recurso generico',      'Recurso sin clase especifica',                  'tag.fill')
on conflict (subtype_key) do nothing;

-- ----------------------------------------------------------------------------
-- 5. RLS read-only para authenticated; catalogos son globales
-- ----------------------------------------------------------------------------
alter table public.resource_classes enable row level security;
alter table public.resource_subtypes enable row level security;

create policy "resource_classes_read_all"
  on public.resource_classes for select
  to authenticated using (true);

create policy "resource_subtypes_read_all"
  on public.resource_subtypes for select
  to authenticated using (true);

grant select on public.resource_classes to authenticated;
grant select on public.resource_subtypes to authenticated;
