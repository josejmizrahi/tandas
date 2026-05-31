# Resources Deep — Plan para sesión dedicada

> Prompt self-contained para arrancar Resources deep en sesión nueva.
> Backend + frontend, tipo por tipo, hasta dejar el dominio sólido.
> NO ejecutar en la sesión actual. Copiar el bloque del final como
> primer mensaje del próximo Claude.

---

## 0. Contexto que necesitas saber antes de empezar

### 0.1. Estado actual (lo que YA está)

**Backend (BD canónica post-V3 PARTE 13, 2026-05-30):**

- Tabla envelope `group_resources` con shape:
  `id, group_id, resource_type, name, description, status, visibility,
  ownership_kind, owner_membership_id, ownership_metadata, unit,
  metadata, series_id, created_by, created_at, updated_at, archived_at`
- CHECK `resource_type` ∈ 18 valores:
  `event, fund, slot, space, asset, right, money, time, points,
  document, data, access, other, vehicle, tool, inventory, real_estate,
  intellectual_property`
- CHECK `ownership_kind` ∈ `('group','individual','shared','custodial','external')`
- CHECK `status` ∈ `('draft','active','archived','deleted')`
- CHECK `visibility` ∈ `('private','members','public')`

**Subtipos especializados (5 tablas):**
- `group_resource_assets` — `asset_kind, serial_number, current_value,
  current_value_unit, condition, custodian_membership_id`
- `group_resource_asset_valuations` — histórico valor (`value, unit, basis`)
- `group_resource_funds` — `fund_kind, currency, is_shared_pool,
  is_in_kind, threshold_target, locked_at`
- `group_resource_spaces` — `address, geo, capacity, rules`
- `group_resource_rights` — `right_kind, holder_membership_id,
  granted_at, expires_at, expired_at, revoked_at, transferable, conditions`
- `group_resource_slots` — `slot_starts_at, slot_ends_at,
  assigned_membership_id, released_at, expired_at`
- `group_resource_events` — **NO es audit log; es subtipo calendar**
  (`starts_at, ends_at, location, capacity, host_membership_id,
  rsvp_deadline, check_in_window, cancelled_at, closed_at`)
- `group_resource_bookings` — reservas (`starts_at, ends_at,
  membership_id, status, reason, group_id`)
- `group_resource_capabilities` — capabilities opt-in por recurso
  (`capability_key, enabled, config, enabled_by`)
- `group_resource_transactions` — contable (group_id, …)
- `group_resource_series` — recurrencias/rituales

**RPCs vivas (14):**
`create_group_resource, create_resource, update_resource,
archive_resource, revert_archive_resource, set_resource_ownership,
group_resources_active, group_resource_detail, update_resource_value,
record_resource_lifecycle_event, book_resource,
enable_resource_capability, disable_resource_capability,
create_resource_series, update_resource_series,
list_group_resource_series, assert_resource_type` (trigger).

**Permissions (7):** `resources.read/.create/.update/.archive/.transfer/
.update_value/.record_event`

**Event types resource.* (12):**
- Ya emitidos por flows: `resource.created, resource.archived,
  resource_series.created, resource_series.updated`
- Lifecycle disponibles vía `record_resource_lifecycle_event`:
  `resource.value_updated, resource.status_changed,
  resource.transferred, resource.used, resource.damaged,
  resource.repaired, resource.assigned, resource.returned`

**Doctrina FIRMADA en PARTE 13:**
- Ownership singular (NO multi-role). Owner/custodian/holder/host son
  columnas singulares en envelope o subtype.
- Audit log = `group_events` polimórfico (entity_kind='resource',
  entity_id=resource_id). NO crear tablas paralelas de audit.
- Subtipos especializados intactos para los 5 con tabla dedicada.
- Los 9 envelope-only types (`money, time, points, document, data,
  access, other, vehicle, tool, inventory, real_estate,
  intellectual_property`) viven en `metadata` jsonb.
- `update_resource_value`: en asset escribe a `asset_valuations` +
  actualiza `assets.current_value`; en otros graba en envelope
  `metadata.last_value/_unit/_basis/_at`. Siempre emite
  `resource.value_updated`.

**Frontend (lo que YA está):**
- `Features/Resources/`:
  - `CreateResourceView.swift`
  - `ResourceDetailView.swift`
  - `ResourcesListView.swift`
  - `ResourceRowView.swift`
  - `TransferOwnershipSheet.swift`
  - `ResourcePreviewData.swift`
- `Domain/Resource*` en RuulCore (envelope DTO + repository).
- iOS expone: lista resources_active, create envelope, archive,
  transfer ownership. **NO expone aún**: subtype-specific fields,
  lifecycle events, value updates, capability toggles, bookings,
  per-type create flows, per-type detail layered scroll.

---

### 0.2. Doctrina relevante (NO violar)

- **`doctrine_resource_detail_v2`** — cada resource = situación viva.
  Detail = layered scroll de 6 bloques: Identity / Context /
  Participation / Coordination / Activity / Actions.
  PresenceBlock universal. MoneyBlock social siempre. Activity feed
  obligatoria. Vocabulary purge.
- **`ruul_universal_detail_layered_doctrine`** — NO tabs segmentados.
  Stack vertical. Coordination = stack de bloques universales
  (Money/Schedule/Access/Responsibility/Rules/Usage).
- **`ruul_identity_context_doctrine`** — tap a persona →
  participación contextual PRIMERO, identidad completa SEGUNDO.
- **`ruul_canonical_ux_doctrine`** — Ruul = coordinación, no eventos.
  Tabs = verbos, no superficies técnicas. Mismo shell UX para cada
  tipo de resource.
- **`feedback_verify_before_implement`** — auditar BD vía
  `mcp__supabase__execute_sql` ANTES de tocar nada. Doctrina
  documentada puede tener drift; la BD es la verdad.
- **`feedback_dont_touch_ruului_base`** — RuulUI en DELETE mode.
  Compón al feature layer con tokens + primitivas sobrevivientes.
  Zero nuevas primitivas, zero hardcoded values.
- **`doctrine_button_styles`** — `.glassProminent` (primary) /
  `.glass` (secondary). BAN `.borderedProminent` y `.bordered`.
- **`doctrine_card_styles`** — `.ruulCardSurface(.solid)` siempre.
- **`vocab_gobernanza_decision`** — "Decisiones del grupo", nunca
  "gobernanza".
- **`doctrine_shared_money`** — grupo tiene UN pool compartido por
  default. Funds protegidos son excepción. Cualquier resource con
  movimientos económicos linkea a money via `source_resource_id`.

---

## 1. Objetivo de la sesión

Cerrar Resources deep: **cada resource type debe estar 100% wired
backend + frontend** con todo lo que necesita para vivir solo en la
app sin que el founder tenga que tocar SQL. "Vivir solo" significa:

- Crear desde iOS con todos los campos relevantes del tipo
- Ver detail layered con los bloques aplicables
- Editar campos editables
- Operaciones de ciclo de vida (asignar, transferir, marcar dañado,
  valuar, archivar) desde iOS
- Audit feed visible
- Money integration cuando aplica (peer money + pool charges
  linkeados a `source_resource_id`)
- Rules integration: el atom catalog de reglas debe poder filtrar/
  apuntar a este resource_type
- Empty states + error states + permission gates en UI

---

## 2. Alcance por resource type

Cada tipo necesita un análisis del par BE+FE. **Antes de implementar
cada tipo, auditar con SQL real qué falta**. Lo siguiente es el
target deseado por tipo, no la lista exacta de qué falta:

### 2.1. `asset` (físico durable, custodia singular)
**Casos**: herramienta cara compartida, equipo de oficina, instrumento.
**Backend faltante posible**:
- RPC `assign_asset_custodian(p_resource_id, p_membership_id,
  p_reason, p_client_id)` que update `assets.custodian_membership_id`
  + emite `resource.assigned`.
- RPC `release_asset_custodian(p_resource_id, p_reason, p_client_id)`
  → NULL + `resource.returned`.
- RPC `mark_asset_condition(p_resource_id, p_condition, p_reason,
  p_client_id)` (`damaged`/`repaired`/`good`) → update `condition`
  + emite event apropiado.
**Frontend faltante**:
- `AssetSubtypeSection` en ResourceDetailView con: asset_kind, serial,
  condition badge, custodian actual, current_value.
- `RecordValuationSheet` (call `update_resource_value`).
- Action strip: Asignar custodio · Marcar dañado · Reparar · Valuar ·
  Transferir.
- Activity feed filtrado a events del recurso.

### 2.2. `fund` (dinero etiquetado)
**Casos**: fondo común, fondo de cumpleaños, ahorro para X.
**Doctrina**: `doctrine_shared_money` + `doctrine_fund_per_event_deprecation`.
Pool default no es resource; funds dedicados sí.
**Backend faltante posible**:
- RPC `lock_fund(p_resource_id, p_reason)` → `funds.locked_at = now()`.
- RPC `unlock_fund(p_resource_id, p_reason)` → NULL + event.
- RPC `set_fund_threshold(p_resource_id, p_threshold_target, p_unit)`.
- Verify: `record_expense` / `record_settlement` aceptan
  `p_resource_id` para linkear a fund? Auditar.
**Frontend faltante**:
- `FundSubtypeSection`: fund_kind, currency, balance actual
  (via group_pool_balance si is_shared_pool, sino aggregate de
  obligations linkeadas), threshold progress, locked status.
- Action strip: Aportar al fondo · Cobrar al fondo · Bloquear ·
  Cambiar meta · Ver movimientos.
- "Ver movimientos" filtrado por `source_resource_id`.

### 2.3. `space` (lugar físico bookeable)
**Casos**: oficina, salón, cancha compartida.
**Backend faltante posible**:
- RPC `book_resource` ya existe — verificar shape.
- RPC `cancel_booking(p_booking_id, p_reason)`.
- RPC `list_bookings(p_resource_id, p_starts_after, p_ends_before)`.
- Conflict guard server-side: dos bookings overlapping bloqueados.
**Frontend faltante**:
- `SpaceSubtypeSection`: address, geo, capacity, rules.
- `BookSpaceSheet` con date pickers + duration + reason.
- `BookingsCalendarView` o lista cronológica.
- Action strip: Reservar · Ver reservas · Editar reglas.

### 2.4. `right` (acceso o derecho transferible)
**Casos**: derecho de uso de algo, membresía, acceso a servicio
externo.
**Backend faltante posible**:
- RPC `grant_right(p_resource_id, p_holder_membership_id,
  p_expires_at, p_conditions)` → set holder, emit `resource.assigned`.
- RPC `transfer_right(p_resource_id, p_new_holder_membership_id,
  p_reason)` — solo si `transferable=true` → emit
  `resource.transferred`.
- RPC `revoke_right(p_resource_id, p_reason)` → `revoked_at = now()`.
- RPC `expire_right(p_resource_id)` (puede ser cron).
**Frontend faltante**:
- `RightSubtypeSection`: holder, expires_at countdown, transferable,
  conditions text, revoked/expired state.
- Action strip: Transferir · Revocar · Extender vigencia.

### 2.5. `slot` (espacio temporal asignable a un member)
**Casos**: turno de host, turno de limpieza, slot de cobro en tanda.
**Backend faltante posible**:
- RPC `assign_slot(p_resource_id, p_membership_id, p_reason,
  p_client_id)` → set `assigned_membership_id`.
- RPC `release_slot(p_resource_id, p_reason)`.
- RPC `expire_slot(p_resource_id)` (cron o explícito).
- RPC `list_slots_for_series(p_series_id)` (linkear a series).
**Frontend faltante**:
- `SlotSubtypeSection`: slot window, assigned member avatar, status
  (asignado/libre/liberado/expirado).
- Linkable a Rituals (un ritual recurrente puede generar slots).
- Action strip: Asignar a mí · Asignar a otro · Liberar · Editar
  ventana.

### 2.6. `event` (calendar con RSVPs + check-ins)
**Estado**: el subtipo `group_resource_events` tiene RSVPs y
check-ins. Probablemente ya hay backend completo de evento heredado
del feature Events. **VERIFICAR** qué RPCs existen
(`set_rsvp`, `check_in_attendee`, `close_event`).
**Frontend faltante**:
- Migrar `Features/Events/` (si existe) hacia el surface
  `Resources/EventDetailView` o composable bloque. Decidir si
  Events queda como tab separado o se mergea.
- En este plan: dejar Events tal cual si ya está sano. Solo confirmar
  que el envelope se ve también en ResourcesListView.

### 2.7. `vehicle` (envelope-only, NUEVO en PARTE 13)
**Casos**: auto compartido, moto, bicicleta del grupo.
**Backend disponible**: envelope + `metadata` + `record_resource_lifecycle_event`
+ `update_resource_value`.
**Frontend faltante**:
- `VehicleSubtypeSection` LEYENDO `metadata`: marca/modelo (de
  metadata), placas, kilometraje (metadata), última valuación,
  custodio actual (de `owner_membership_id` o metadata).
- Acceptable storing campos en `metadata` jsonb editables vía
  `update_resource`.
- Action strip: Reportar uso · Reportar daño · Reparar · Valuar ·
  Transferir.
- `RecordVehicleUseSheet` → `record_resource_lifecycle_event` con
  `resource.used` + payload (km, motivo, membership).

### 2.8. `tool` (envelope-only, NUEVO)
**Casos**: herramienta puntual sin custodia formal (taladro casero
prestado).
**Frontend**: similar a vehicle pero más simple. Use/damage/repair.

### 2.9. `inventory` (envelope-only, NUEVO)
**Casos**: stock fungible (cajas de algo, insumos).
**Frontend faltante**:
- `InventorySubtypeSection`: quantity en `metadata`, threshold mínimo,
  last_value.
- Action strip: Reportar consumo · Reponer · Ajustar inventario ·
  Valuar.
- `AdjustInventorySheet` → update_resource (delta sobre metadata.qty)
  + lifecycle event `resource.used` con qty_delta.

### 2.10. `real_estate` (envelope-only, NUEVO)
**Casos**: casa, terreno, depto del grupo.
**Frontend faltante**:
- `RealEstateSubtypeSection`: address (metadata), valor último,
  ownership_kind = shared/custodial display.
- Action strip: Valuar · Marcar daño · Transferir.

### 2.11. `intellectual_property` (envelope-only, NUEVO)
**Casos**: marca registrada, patente, copyright compartido del grupo.
**Frontend faltante**:
- `IntellectualPropertySubtypeSection`: tipo (marca/patente/copyright
  en metadata), número registro, fecha vigencia.
- Action strip: Valuar · Transferir · Renovar (registro).

### 2.12-2.17. Envelope-only restantes (`money, time, points,
document, data, access, other`)
Estos son envelope puro con metadata custom. Pueden compartir
`GenericEnvelopeSubtypeSection` que renderiza key/values de metadata
con un schema declarado por type.

---

## 3. Patrones reutilizables a establecer

Antes de implementar tipo por tipo, **diseñar y commitear primero**
los siguientes building blocks que cada tipo usará:

### 3.1. `ResourceTypeRegistry` (RuulCore)
Swift enum + metadata por tipo:
```swift
struct ResourceTypeDescriptor {
    let raw: String                  // "vehicle"
    let displayName: String          // "Vehículo"
    let icon: String                 // SF Symbol
    let subtypeTable: String?        // nil si envelope-only
    let supportsValuation: Bool
    let supportsCustody: Bool
    let supportsBooking: Bool
    let supportsAssignment: Bool
    let lifecycleEvents: [String]    // ["resource.used", "resource.damaged"]
    let metadataSchema: [MetadataField]
}
```
Esta es la fuente única para FE — cada View consulta el descriptor en
vez de hardcodear.

### 3.2. `ResourceDetailView` layered scroll
6 bloques:
- **Identity**: nombre, tipo, ownership_kind, owner avatar
- **Context**: descripción, visibility, status badges
- **Participation**: PresenceBlock (quién está involucrado)
- **Coordination**: stack de bloques aplicables:
  - `MoneyBlock` (siempre, social: balance + obligations linkeadas)
  - `ScheduleBlock` (si event/slot/space con bookings)
  - `AccessBlock` (si right)
  - `ResponsibilityBlock` (custodian/host/holder)
  - `RulesBlock` (rules con `scope=resource:<type>` o `scope=resource:<id>`)
  - `UsageBlock` (último uso, condition, valuación reciente)
- **Activity**: feed de `group_events` filtrado por entity_id
- **Actions**: action strip permission-gated

Cada bloque es composable y solo se renderiza si tiene datos
relevantes para el tipo (descriptor.supports*).

### 3.3. `CreateResourceFlow`
Flow de 2-3 steps:
1. Picker de tipo (icon + display)
2. Campos comunes (nombre, descripción, visibility, ownership)
3. Campos type-specific (de `descriptor.metadataSchema`)

### 3.4. `LifecycleEventSheet`
Sheet genérico para `record_resource_lifecycle_event` que toma:
- `resource: GroupResource`
- `eventType: String` (de whitelist disponible)
- Render dinámico de payload fields según event type

### 3.5. `RecordValuationSheet`
Sheet específico para `update_resource_value`. Solo visible si
`descriptor.supportsValuation`.

### 3.6. `TransferOwnershipSheet` (ya existe)
Verificar que cubre todos los tipos con singular owner.

### 3.7. `ResourceRowView` per-type
Mostrar icono del descriptor + name + sub-row con info clave
(condition para asset, balance para fund, próximo booking para space,
holder para right, slot window para slot).

---

## 4. Audit-first protocol antes de cada tipo

Para cada resource type, ANTES de implementar:

1. Query SQL real:
```sql
-- ¿Qué RPCs existen para este tipo?
SELECT proname, pg_get_function_arguments(p.oid)
FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='public' AND (
  proname ILIKE '%<type>%' OR
  proname ILIKE 'book%' OR proname ILIKE 'assign%' OR
  proname ILIKE 'transfer%' OR proname ILIKE 'value%'
);

-- ¿Qué columnas tiene el subtype?
SELECT column_name, data_type FROM information_schema.columns
WHERE table_schema='public' AND table_name='group_resource_<type>s';

-- ¿Qué event types ya se emiten para este tipo?
SELECT DISTINCT event_type FROM group_events
WHERE entity_kind='resource'
  AND entity_id IN (SELECT id FROM group_resources WHERE resource_type='<type>');
```

2. Mapear vs lo deseado.
3. Reportar GAPS antes de aplicar mig.

**Nunca asumir que el plan documentado coincide con BD.** Doctrina
`feedback_verify_before_implement`.

---

## 5. Orden de implementación recomendado

### Fase A — Cimientos compartidos (1 sesión)
1. `ResourceTypeRegistry` en RuulCore con los 18 descriptors.
2. `ResourceDetailView` refactorizado a layered scroll con 6 bloques
   composables (cada bloque inicialmente puede ser stub).
3. `CreateResourceFlow` con picker de tipo.
4. `ResourceRowView` per-type usando descriptor.
5. Smoke iOS: build + UI test que cada tipo aparece en picker.

### Fase B — Subtipos con tabla dedicada (1-2 sesiones)
6. `asset` — BE: 3 RPCs (assign/release/condition) + FE: AssetSubtypeSection + Actions.
7. `fund` — BE: 3 RPCs (lock/unlock/threshold) + FE: FundSubtypeSection + balance.
8. `space` — BE: cancel_booking + list_bookings + FE: bookings UI.
9. `right` — BE: grant/transfer/revoke/expire + FE: RightSubtypeSection.
10. `slot` — BE: assign/release/expire + FE: SlotSubtypeSection.

### Fase C — Envelope-only types (1 sesión)
11. `vehicle`, `tool`, `inventory`, `real_estate`,
    `intellectual_property` — metadata schemas + lifecycle sheets.
12. `money, time, points, document, data, access, other` —
    GenericEnvelopeSubtypeSection.

### Fase D — Integración cross-primitive (1 sesión)
13. Money integration: cuando record_expense o record_pool_charge se
    emite con `p_resource_id`, mostrarlo en MoneyBlock del recurso.
14. Rules integration: extender atom catalog para que filtros y
    consequence pueda apuntar a resource_type y resource_id.
15. Activity feed: render polimórfico de los 12 event types.
16. Permission gates correctos en cada action strip.

### Fase E — QA + polish (1 sesión)
17. Smoke `_smoke_resources_extended` cubriendo 1 happy-path por tipo
    (~18 asserts adicionales).
18. Empty states + error states + a11y review.
19. Doctrina `doctrine_resource_detail_v2` audit final (vocabulary
    purge, presence block universal, money block social).
20. Device install + manual QA.

---

## 6. Riesgo a evitar

- **NO crear multi-role.** Si en algún tipo aparece el deseo de "varios
  custodios" o "varios holders", parar y reabrir doctrina con
  founder. Ya quedó fijado en PARTE 13.
- **NO crear nuevos audit tables.** Todo lifecycle event va a
  `group_events` via `record_system_event` o
  `record_resource_lifecycle_event`.
- **NO duplicar RPCs.** Antes de crear `update_<type>` verificar si
  `update_resource` ya cubre.
- **NO hardcodear vocab por tipo en views.** Todo viene de
  `ResourceTypeDescriptor.displayName`.
- **NO usar tabs segmentados en detail.** Layered scroll obligatorio
  (`ruul_universal_detail_layered_doctrine`).
- **NO tocar RuulUI base.** Compose at feature layer.
- **NO confiar en el plan vs BD.** Audit-first protocol en cada tipo.

---

## 7. DoD por fase

- Compila sin warnings (`mcp__xcode-tools__BuildProject`).
- `swift test` verde (sin nuevas regresiones).
- Codegen Swift↔TS sin diff (lefthook enforce).
- Smoke BE `_smoke_resources_extended` 100% verde post-Fase E.
- Device install OK en iPhone de JJ
  (`E63668BF-3B28-5F51-B678-519B203E48CC`).
- Memory append: `project_v3_resources_deep_<fase>.md` por fase.

---

# 📋 Copy-paste para próxima sesión

```
Resources Deep — sesión dedicada.

CONTEXTO:
- Estás trabajando en /Users/jj/code/tandas/ios (SwiftUI iOS 26+) +
  Supabase backend (proyecto canónico: wyvkqveienzixinonhum aka "ruul").
- V3 PARTE 13 acaba de cerrar (2026-05-30): Resources canonical
  extend backend. Ver memoria `project_v3_parte13_resources_extend`
  + plan `Plans/Active/ResourcesDeep.md`.
- Lee primero `Plans/Active/ResourcesDeep.md` completo antes de tocar
  nada. Es el plan completo de la sesión.
- Lee también `Plans/Active/RitualsDeep.md` y
  `Plans/Active/ResourcesPolish.md` por contexto adyacente.

OBJETIVO DE LA SESIÓN:
Implementar Resources Deep — cada uno de los 18 resource_types con
todo lo que necesita backend y frontend para vivir solo en la app:
crear, detail layered, lifecycle events, money integration, rules
integration, permission gates, empty states.

REGLAS DURAS (de Plans/Active/ResourcesDeep.md):
1. AUDIT-FIRST: antes de cada tipo, query BD vía
   mcp__supabase__execute_sql para ver qué existe. NUNCA asumir
   doctrina = realidad. (doctrine `feedback_verify_before_implement`)
2. NO multi-role. Ownership singular. Si surge necesidad real,
   parar y reabrir con founder.
3. NO audit tables nuevas. Todo va a group_events polimórfico.
4. NO duplicar RPCs existentes. Verificar primero.
5. NO tocar RuulUI base. Compose at feature layer.
6. NO tabs en detail. Layered scroll obligatorio.
7. Doctrina UI: .glassProminent/.glass, .ruulCardSurface(.solid),
   "Decisiones del grupo" vocab.
8. NO commit hasta confirmar con founder al final de cada Fase.

EMPEZAR POR:
Fase A (cimientos compartidos): ResourceTypeRegistry + layered
ResourceDetailView refactorizado + CreateResourceFlow + per-type
ResourceRowView. Auditar primero qué hay en Features/Resources/ y
qué falta. Reportar gaps antes de codear.

Si en cualquier momento aparece ambigüedad doctrinal: PARAR y
preguntar al founder. No improvisar.
```
