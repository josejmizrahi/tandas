# Open Platform Architecture — Phase 0

**Fecha:** 2026-05-10
**Status:** Documento foundational. Sin breaking changes. Pre-implementation.
**Trigger:** Founder directive — "Ruul no debe depender de que nosotros programemos cada vertical manualmente."

---

## TL;DR (1 pantalla)

Ruul hoy: ~70% capability-driven, 30% recurring-dinner-leaked. Toggle `basic_fines` ya lifecycles correctamente (post Phase A). Pero quedan tres deudas:

1. **Vertical leakage** — `recurring_dinner` hardcoded en 8 sitios (Swift + SQL); `groups` tiene scheduling (`frequency_*`, `default_*`) que pertenece a ResourceSeries.
2. **Capability-as-implicit** — Modules existen y togglean, pero **no hay `CapabilityBlock` formal**. UI gates en module ids específicos en vez de en capabilities composables. ResourceSeries no existe.
3. **Atom/Projection split incompleto** — `system_events` y `vote_ballots` son atoms ✓. Pero `votes.status`, `fines.status`, `event_attendance` son mutables. `groups.fund_balance` está stored (drift). No hay `ledger_entries`.

Ruta segura: 5 fases incrementales, ninguna rompe Beta 1.

---

## A. Arquitectura Final Propuesta

### A.1 Modelo conceptual (capa lógica)

```
Identity
  → Membership (per-group)
    → Group (bare community: id, name, members, governance, roles, active_modules)
      → Templates (presets, no cárceles)
      → ModuleRegistry (catálogo de capabilities)
        → CapabilityBlocks (composables: rsvp, recurrence, money, …)
          → Resources (polimorphic: event, slot, fund, asset, …)
            → ResourceSeries (recurrencia opcional)
              → Occurrences
            → ScopedRules (group | module | series | resource | occurrence | membership)
              → Atoms (ledger_entry, vote_ballot, rsvp_action, system_event, …)
                → Projections (balance, attendance, history, reputation, …)
                  → UI (capability-driven render)
```

### A.2 Database (schema final, ver §F para deltas)

```
public.groups          (bare: id, name, governance, roles, active_modules)
public.group_members   (membership)
public.modules         (catálogo + provided_capability_blocks new)
public.capability_blocks       NEW — declarative catalog
public.templates       (presets — config jsonb con suggestedModules + suggestedCapabilities + suggestedRules)
public.resources       (polimorphic: id, group_id, resource_type, status, metadata jsonb, series_id?)
public.resource_series NEW — recurrence + pattern
public.resource_capabilities   NEW — per-resource capability config jsonb
public.rules           (scoped: group_id, module_key?, series_id? NEW, resource_id?, occurrence_id? NEW, membership_id? NEW)
public.ledger_entries  NEW — money atoms
public.rsvp_actions    NEW — RSVP append-only
public.system_events   (atoms, ya existe)
public.vote_ballots    (atoms, ya existe)
public.votes           (projection — status/result derivados)
public.fines           (projection — status derivado de ledger_entries de tipo fineIssued/finePaid)
```

### A.3 Swift types (RuulCore)

```swift
// Existente (mantener):
Group, GroupMember, Profile, Resource (protocol), Event,
Module, ModuleRegistry, CapabilityResolver (extender),
Rule, GroupRule, RuleTrigger/Condition/Consequence

// Nuevo (Phase 1+):
protocol CapabilityBlock { … }              // §C
struct ResourceSeries { … }                  // §F
struct LedgerEntry { … }                     // §F
struct ResourceBuilder { … }                 // §B
extension CapabilityResolver { canCreateResource, canEnableCapability, canViewSection, … }
```

### A.4 Edge functions (server-side)

```
process-system-events/        (existe — extender para rebuild projections)
dispatch-notifications/       (existe)
finalize-votes/               (existe — projection rebuild de votes.status)
finalize-fine-reviews/        (existe — projection rebuild de fines.status)

NEW:
rebuild-projections/          — idempotent rebuild from atoms (balance, attendance, etc.)
add-resource/                 — unified resource creation pipeline (orchestrator)
```

### A.5 Rule engine (server-only, `_shared/ruleEngine.ts`)

Cambios incrementales:
- Hoy: `phase_target` mapping + slug filter por module.
- Phase 1: añadir resolución de scope (`series_id`, `occurrence_id`, `membership_id`) — **rule más específico gana**.
- Phase 2: rule engine emite atoms (no mutaciones), siempre.

### A.6 UI composition

`GroupHomeView` se vuelve dinámico:
```
sections = capabilityResolver.availableSections(group)
// returns: ["upcoming", "money", "assets", "bookings", "votes", "rules", "history", "members"]
// según active_modules + active resource_types + permissions
```

`ResourceDetailView` es polimorphic:
```
view = ResourceDetailView(resource)
  └─ switch resource.resource_type
     ├─ .event       → EventCapabilitiesView(rsvp, checkIn, money, …)
     ├─ .slot        → SlotCapabilitiesView(booking, rotation, …)
     ├─ .fund        → FundCapabilitiesView(contributions, payouts, …)
     ├─ .asset       → AssetCapabilitiesView(owners, slots, fund, …)
     └─ .unknown(t)  → UnknownResourceView(t)  // forward-compat
```

---

## B. ResourceBuilder Design

Protocol que orquesta creación de un Resource. Soporta **simple mode** (30s) y **advanced options** (capabilities composables).

### B.1 Protocol

```swift
public protocol ResourceBuilder {
    /// What resource_type does this builder produce? (one builder per type)
    var resourceType: ResourceType { get }

    /// Required fields for simple mode. UI shows ONLY these by default.
    var requiredFields: [BuilderField] { get }

    /// Optional capabilities the user can opt into mid-flow.
    var optionalCapabilities: [CapabilityBlock] { get }

    /// Build the resource. Returns the created Resource id + cascaded atoms.
    func build(_ draft: ResourceDraft) async throws -> ResourceCreationResult
}

public struct ResourceDraft {
    let groupId: UUID
    let resourceType: ResourceType
    let basicFields: [BuilderFieldKey: AnyValue]
    let enabledCapabilities: [CapabilityBlock.Id]
    let capabilityConfigs: [CapabilityBlock.Id: AnyValue]
    let optionalSeriesPattern: SeriesPattern?  // if recurrence enabled
    let optionalRules: [RuleDraft]             // if rules enabled
}

public struct ResourceCreationResult {
    let resourceId: UUID
    let seriesId: UUID?
    let createdRuleIds: [UUID]
    let enabledModules: [String]   // any modules that got cascade-enabled
}
```

### B.2 Flow (UI)

```
Step 1 — Pick resource type
  ↓
Step 2 — Required fields only ("Crear así" CTA visible aquí)
  ↓
Step 3 — [opcional] "Add more options" panel
   ├─ Recurrence?       (capability: recurrence)
   ├─ RSVP?             (capability: rsvp)
   ├─ Rotation?         (capability: rotation)
   ├─ Money?            (capability: money)
   ├─ Booking?          (capability: booking)
   ├─ Guests?           (capability: guest_access)
   ├─ Rules?            (capability: rules → opens rule subwizard)
   └─ Notifications?    (capability: notifications)
  ↓
Step 4 — Review screen (resumen de lo que se va a crear)
  ↓
Step 5 — Create → ResourceCreationResult
```

### B.3 Servidor

Un solo RPC `add_resource(p_group_id, p_type, p_draft jsonb)` que:
1. Inserta en `resources`.
2. Si draft tiene `seriesPattern`: inserta en `resource_series` + linkea via `series_id`.
3. Por cada capability enabled: inserta en `resource_capabilities`.
4. Por cada rule en draft: inserta vía `seed_module_rules` o `create_initial_rule` (con scope correcto).
5. Si capabilities requieren modules no activos: cascada via `set_group_module(true)` (que ya existe post Phase A).
6. Emite atoms relevantes (`resourceCreated`, `seriesCreated`, etc.).

---

## C. CapabilityBlocks Design

Cada CapabilityBlock declara su contrato. Modules ofrecen capabilities; resources las consumen.

### C.1 Protocol

```swift
public protocol CapabilityBlock: Sendable {
    var id: String { get }                          // "rsvp", "recurrence", "money", …
    var displayName: String { get }
    var description: String { get }

    /// Resource types that can enable this capability.
    var enabledResourceTypes: [ResourceType] { get }

    /// Required config fields when enabling (e.g. recurrence requires pattern).
    var requiredFields: [BuilderField] { get }
    var optionalFields: [BuilderField] { get }

    /// Suggested rules (templates) the user can pick from.
    var suggestedRules: [RuleTemplate] { get }

    /// Actions this capability exposes (e.g. money → "registrar gasto").
    var actions: [CapabilityAction] { get }

    /// UI routes/sections this capability surfaces.
    var routes: [CapabilityRoute] { get }

    /// Permission ids this capability checks.
    var permissions: [Permission] { get }

    /// Projections this capability produces (e.g. money → balance).
    var projections: [ProjectionDescriptor] { get }

    /// Dependencies on other capabilities.
    var dependencies: [String] { get }

    /// Conflicts with other capabilities (e.g. rotation_host vs assignment_manual).
    var conflicts: [String] { get }
}
```

### C.2 V1 catalog (los que ya existen como módulos)

| Block id | Display | Resource Types | Provided By Module |
|---|---|---|---|
| `rsvp` | RSVP | event | rsvp |
| `check_in` | Check-in | event | check_in (deps: rsvp) |
| `recurrence` | Recurrencia | event, slot, fund | (NEW: recurrence module) |
| `rotation` | Rotación | event, slot | rotating_host |
| `money` | Dinero | event, trip, fund, asset, group | basic_fines (parcial) |
| `voting` | Votaciones | proposal, fine | appeal_voting |
| `rules` | Reglas | (todas) | (core, no módulo) |

### C.3 Phase 2-4 catalog

| Block id | Display | Phase |
|---|---|---|
| `booking` | Reservas | 2 |
| `slot` | Slots | 2 |
| `assignment` | Assignments | 2 |
| `guest_access` | Invitados | 2 |
| `fund` | Fondos | 3 |
| `contribution` | Aportaciones | 3 |
| `payout` | Payouts | 3 |
| `settlement` | Liquidación | 3 |
| `ownership` | Ownership | 4 |
| `notifications` | Notificaciones | 4 |
| `reputation` | Reputación | 5 |

### C.4 Storage

Por ahora **declarative en código** (Swift + duplicado en SQL seed), idéntico al patrón de `modules`. Phase 1 podría introducir `public.capability_blocks` table si surge necesidad de evolucionar capabilities sin redeploy.

---

## D. ModuleRegistry Design

Modules permanecen como bundles de capabilities + rules + system_events + tabs + resource_types. Phase 1 añade un campo:

```sql
alter table public.modules
  add column provided_capability_blocks text[] not null default '{}';
```

iOS `GroupModule` gana `providedCapabilityBlocks: [String]`.

Nuevos modules a crear en Phase 2-4:
- `recurrence` — provee capability `recurrence`. Sin deps. Resource types: event, slot, fund.
- `slot_assignment` — provee `slot`, `booking`, `assignment`. Conflicts: `rotating_host` (en algunos contextos).
- `common_fund` — provee `fund`, `contribution`, `payout`. Resource types: fund.
- `expense_tracking` — provee `money` (ledger). Replaces partial `basic_fines` money concern.

### D.1 Module declaration final (post Phase 1)

```sql
public.modules:
  id, name, description,
  provided_capability_blocks text[],   -- NEW
  provided_rules text[],                -- (slugs ya existente)
  provided_rules_def jsonb,             -- (post Phase A)
  provided_resource_types text[],
  provided_system_event_types text[],
  provided_tabs text[],
  dependencies text[],
  conflicts_with text[]
```

### D.2 Validation

`ModuleRegistry.validate()` post Phase 1 verifica:
- No duplicate module ids
- All deps exist
- No mutual conflicts
- All `provided_capability_blocks` exist en CapabilityBlock catalog
- All `provided_resource_types` exist en ResourceType enum
- Capability dependencies se cumplen via module deps (e.g. rsvp module → check_in module valid only if rsvp capability ready)

---

## E. CapabilityResolver Design

Hoy: 6 métodos module-level (`finesEnabled`, `rsvpEnabled`, …). Phase 1 lo expande.

### E.1 Métodos finales

```swift
public actor CapabilityResolver {
    // Resource gating
    func canCreateResource(_ type: ResourceType, in group: Group) async -> Bool
    func availableResourceTypes(in group: Group) async -> [ResourceType]

    // Capability gating
    func canEnableCapability(_ block: CapabilityBlock.Id, on resource: Resource) async -> Bool
    func availableCapabilities(for resourceType: ResourceType, in group: Group) async -> [CapabilityBlock.Id]
    func isCapabilityActive(_ block: CapabilityBlock.Id, on resource: Resource) async -> Bool

    // UI section gating
    func canViewSection(_ section: GroupSection, in group: Group, as member: GroupMember) async -> Bool
    func availableSections(in group: Group, as member: GroupMember) async -> [GroupSection]

    // Action gating
    func canPerformAction(_ action: CapabilityAction, on resource: Resource, as member: GroupMember) async -> Bool

    // Rule gating
    func canManageRule(_ rule: Rule, in group: Group, as member: GroupMember) async -> Bool

    // Atomic queries (forward-friendly de la list de la directive)
    func canInviteGuest(to resource: Resource, as member: GroupMember) async -> Bool
    func canAssignSlot(_ resource: Resource, as member: GroupMember) async -> Bool
    func canRecordExpense(on resource: Resource, as member: GroupMember) async -> Bool
    func canSettleBalance(in group: Group, as member: GroupMember) async -> Bool
    func canVote(on proposal: Resource, as member: GroupMember) async -> Bool
}
```

### E.2 Server-side mirror

Nuevas RPCs:
- `can_create_resource(p_group, p_type)` → boolean
- `can_perform_action(p_group, p_resource, p_action)` → boolean
- `can_view_section(p_group, p_section)` → boolean

Estas RPCs componen `has_permission` (que ya existe) + `groups.active_modules` + `resource.metadata` para devolver el verdict.

### E.3 Resolution algorithm

```
canPerformAction(action, resource, member):
    1. block = capabilityBlock(of: action)
    2. if !group.active_modules.contains(block.providedByModule) → false
    3. if !resource_capabilities[resource.id].includes(block.id) → false
    4. for each permission in block.permissions:
         if !has_permission(group, member.userId, permission) → false
    5. return true
```

---

## F. Database Direction

### F.1 Schema deltas (Phase 1+)

```sql
-- Phase 1
alter table public.modules
  add column provided_capability_blocks text[] not null default '{}';

create table public.resource_series (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.groups(id) on delete cascade,
  resource_type text not null,
  pattern jsonb not null default '{}',  -- {frequency, dayOfWeek, startTime, …}
  metadata jsonb not null default '{}',
  active boolean not null default true,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.resources
  add column series_id uuid null references public.resource_series(id) on delete set null;

create table public.resource_capabilities (
  resource_id uuid not null references public.resources(id) on delete cascade,
  capability_block_id text not null,
  config jsonb not null default '{}',
  enabled boolean not null default true,
  enabled_at timestamptz not null default now(),
  primary key (resource_id, capability_block_id)
);

-- Phase 2: extend rules scope
alter table public.rules
  add column series_id uuid null references public.resource_series(id) on delete cascade,
  add column occurrence_id uuid null,  -- references resources.id when resource is occurrence
  add column membership_id uuid null references public.group_members(id) on delete cascade;

-- Phase 3: ledger atoms
create table public.ledger_entries (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.groups(id) on delete cascade,
  resource_id uuid null references public.resources(id) on delete cascade,
  type text not null,         -- expense | contribution | payout | fine_issued | fine_paid | settlement | …
  amount_cents bigint not null,
  currency text not null default 'MXN',
  from_member_id uuid null references public.group_members(id),
  to_member_id uuid null references public.group_members(id),
  metadata jsonb not null default '{}',
  occurred_at timestamptz not null default now(),
  recorded_at timestamptz not null default now(),
  recorded_by uuid references auth.users(id)
);
create index idx_ledger_group on public.ledger_entries(group_id, occurred_at);
create index idx_ledger_resource on public.ledger_entries(resource_id) where resource_id is not null;
create index idx_ledger_type on public.ledger_entries(type);

-- Replace stored fund_balance with view
drop column groups.fund_balance;  -- (Phase 3, después de migración)

create view public.group_fund_balances as
select group_id,
       sum(case when type='contribution' then amount_cents
                when type='payout'       then -amount_cents
                else 0 end)::bigint as fund_balance_cents
  from public.ledger_entries
 group by group_id;

-- Phase 2: RSVP atoms
create table public.rsvp_actions (
  id uuid primary key default gen_random_uuid(),
  resource_id uuid not null references public.resources(id) on delete cascade,
  member_id uuid not null references public.group_members(id) on delete cascade,
  status text not null,         -- going | maybe | declined | pending
  recorded_at timestamptz not null default now(),
  metadata jsonb not null default '{}'
);

-- event_attendance se vuelve projection vista (latest action per member)
create view public.event_attendance_projection as
select distinct on (resource_id, member_id)
  resource_id, member_id, status, recorded_at
from public.rsvp_actions
order by resource_id, member_id, recorded_at desc;
```

### F.2 Deprecaciones (timeline en §I)

| Columna / artifact | Migración | Cuándo |
|---|---|---|
| `groups.event_label` | → `groups.settings.eventVocabulary` (paridad ya expirada 2026-05-26) | Phase 0 cleanup migration |
| `groups.frequency_type`, `frequency_config` | → `resource_series.pattern` | Phase 2 (post-resourceSeries) |
| `groups.default_day_of_week`, `default_start_time`, `default_location` | → `resource_series.pattern` + `event.metadata` | Phase 2 |
| `groups.rotation_mode` | → `module.config` | Phase 2 |
| `groups.fund_balance` (stored) | → `group_fund_balances` view | Phase 3 |
| `seed_dinner_template_rules(uuid)` legacy wrapper | → `seed_template_rules(template, group)` | Phase 5 (after all clients update) |
| Rule mock guard `templateId == "recurring_dinner"` | → parametric mock catalog | Phase 1 |
| `Group.init(baseTemplate: "recurring_dinner")` default | → require explicit | Phase 5 |
| `events` table (post resources dual-write) | → drop after EventRepository fully via resources | Phase 2 (after read-path verified) |

### F.3 Lo que NO cambia

- `public.groups` mantiene: id, name, description, invite_code, created_by, base_template, active_modules, governance, roles, settings (jsonb).
- `public.system_events` permanece como atom log canonical.
- `public.vote_ballots` permanece como atom.
- `public.rules` mantiene esquema post-Phase-A; solo se añaden columnas de scope.

---

## G. UI Direction

### G.1 GroupHomeView (capability-driven)

```swift
GroupHomeView(group):
  let sections = await capabilityResolver.availableSections(group, as: currentMember)
  ForEach(sections) { section in
    switch section {
      case .upcoming   → UpcomingResourcesSection(filter: .future)
      case .money      → MoneySection (balance projection + recent ledger)
      case .assets     → AssetsSection
      case .bookings   → BookingsSection
      case .trips      → TripsSection
      case .votes      → VotesSection
      case .rules      → RulesSection
      case .history    → HistorySection (system_events feed)
      case .members    → MembersSection
    }
  }
  if sections.isEmpty {
    EmptyGroupState(actions: ["Agregar recurso", "Invitar miembros"])
  }
```

### G.2 ResourceDetailView (polimorphic)

Misma idea, switch por `resource.resource_type` + capability gating per section.

### G.3 Empty states

Todos los grupos nuevos arrancan vacíos. **Cada section tiene empty state que ofrece la acción de creación correspondiente.**

---

## H. Creation Flow Final

### H.1 Crear Group

```
1. Name (required)
2. Invite members (optional — skippable, can do later)
3. Choose starting preset (optional — "Empezar de cero" CTA visible)
   ├─ Preset "Cena recurrente" → activa rsvp + check_in + basic_fines + rotating_host, crea ResourceSeries event recurrente
   ├─ Preset "Tanda de ahorro" → activa fund + contribution, crea Fund resource
   ├─ Preset "Activo compartido" → activa slot + booking + ownership, crea Asset resource
   └─ "Empezar de cero" → active_modules = []
4. Create first resource (optional — "Después" CTA visible, pasa direct al group home vacío)
5. Open group
```

### H.2 Crear Resource

```
1. Choose type (event | slot | fund | asset | …)
2. Required fields per type (e.g. event: title, date)
3. "Crear así" CTA O "Add more options"
4. Optional capabilities panel (con dependencias auto-resueltas)
5. Optional rules (subwizard que ofrece suggestedRules)
6. Review screen
7. Create → ResourceCreationResult
```

---

## I. Backward Compatibility

**Reglas inviolables:**
- Beta 1 NO se rompe. Cenas siguen funcionando.
- No big bang rewrite.
- No eliminar GroupType / event_id de golpe (ya está dropped pero no se vuelve a tocar).
- Coexistencia temporal aceptable.

**Estrategia por capa:**

| Capa | Coexistencia |
|---|---|
| `events` table | Mantener mientras EventRepository lo lea. Phase 2 redirige reads a `resources` polimorphic. Phase 4-5 drop. |
| `seed_dinner_template_rules` wrapper | Mantener Phase 1-4. Drop Phase 5 con deprecation notice 30 días antes. |
| `groups.frequency_*` columnas | Phase 2 backfill a `resource_series` + dual-read window 30 días. Phase 3 drop columns. |
| `recurring_dinner` defaults | Phase 1 introduce explicit `null`-as-blank-group; Phase 5 elimina default. |
| `RuleRepository.seedTemplateRules` | Comportamiento sigue + nuevo `seedModuleRules` ya disponible (post Phase A). |
| Onboarding "TemplateSelectorView" | Phase 1 fix visual (no mostrar templates sin hooked impl). Phase 2 expone "Empezar de cero" + presets reales. |

**Migration deprecation pattern:**
```sql
-- ✗ NO HACER:
drop column groups.frequency_type;

-- ✓ HACER:
-- Phase N:   create new (resource_series), backfill
-- Phase N+1: dual-read window, mark column deprecated in comments
-- Phase N+2: ensure no client reads, drop in cleanup migration
```

---

## J. Phased Rollout

### Phase 0 — DOCUMENT (esta semana)
- ✓ L1 audit (`L1_Audit_2026-05-10.md`)
- ✓ Phase A rules architecture (committed `3adb9f4`)
- ✓ Open Platform Phase 0 doc (este archivo)
- 🔲 Cleanup migration: drop `groups.event_label` flat column (paridad expired 2026-05-26)
- 🔲 Cleanup: deprecation comments en `seed_dinner_template_rules`, `Group.baseTemplate` default
- **No breaking changes.**

### Phase 1 — FORMALIZE PROTOCOLS (~1 semana)
- 🔲 `CapabilityBlock` protocol en RuulCore
- 🔲 V1 capability catalog (rsvp, check_in, money, voting, rules, recurrence, rotation)
- 🔲 `provided_capability_blocks` column en modules + iOS GroupModule
- 🔲 `ResourceBuilder` protocol + `ResourceDraft` types
- 🔲 `ModuleRegistry.validate()` revisar capabilities
- 🔲 Rule mock catalog parametrizado por module slug
- 🔲 CapabilityResolver expand: añadir 8 nuevos métodos (`canCreateResource`, `canEnableCapability`, etc.)

### Phase 2 — RESOURCE FOUNDATION (~2 semanas)
- 🔲 `resource_series` table + RLS
- 🔲 `resource_capabilities` table + RLS
- 🔲 `rules.series_id`, `rules.occurrence_id`, `rules.membership_id` columns
- 🔲 `add_resource(group, type, draft)` unified RPC
- 🔲 `recurrence` capability + new `recurrence` module
- 🔲 ResourceBuilder impls: Event, Slot (preview), Fund (preview)
- 🔲 GroupHomeView migra a sections capability-driven
- 🔲 EventRepository redirige reads a `resources` polimórfico (mantiene `events` write dual-write)
- 🔲 Onboarding rediseñado: "Empezar de cero" + presets reales
- 🔲 ResourceWizard UI (simple/advanced toggle)
- ✅ Acceptance: simple event sin reglas, recurring dinner sin rotation, recurring dinner con rotation, agregar reglas post-creation.

### Phase 3 — MONEY (~2 semanas)
- 🔲 `ledger_entries` table + RLS
- 🔲 `expense`, `contribution`, `payout`, `fine_issued`, `fine_paid`, `settlement` ledger types
- 🔲 `group_fund_balances` view (replaces `groups.fund_balance` stored col)
- 🔲 `expense_tracking` capability block + module
- 🔲 `common_fund` capability block + module
- 🔲 Money UI section + ResourceDetailView extension
- 🔲 Rebuild balance projection on every ledger insert (atomic)
- 🔲 Settlement flow (pairwise reconciliation)
- ✅ Acceptance: agregar gastos a evento, group con events + fund simultáneo.

### Phase 4 — ASSET / SLOT / BOOKING (~3 semanas)
- 🔲 Asset resource type + iOS model
- 🔲 Slot resource type + lifecycle (post Phase 2 Slice 2.x ya hay base)
- 🔲 Booking resource type + lifecycle
- 🔲 `slot_assignment`, `booking`, `ownership` capability blocks
- 🔲 GuestPass resource + `guest_access` capability
- 🔲 Rotation generalizado (no solo host) → `rotation` capability composable sobre slots/positions/bookings
- ✅ Acceptance: asset con owners only, agregar slots después, agregar booking + rotation + money después, group con events + asset + fund simultáneo.

### Phase 5 — CLEANUP (~1 semana)
- 🔲 Drop `groups.frequency_*` (post 30-day dual-read)
- 🔲 Drop `groups.default_*` columnas
- 🔲 Drop `seed_dinner_template_rules` wrapper
- 🔲 Drop `events` table (post EventRepository totalmente migrado)
- 🔲 Eliminar `recurring_dinner` defaults restantes
- 🔲 Drop `groups.fund_balance` (post Phase 3 view migration)
- 🔲 Auditoría final de "vertical leakage" — score target 0/10.

---

## K. Acceptance Criteria

Validable via tests (Swift Testing en RuulCore + RuulFeatures + edge function tests):

- ✅ User crea evento simple sin reglas
- ✅ User crea cena recurrente sin host rotation
- ✅ User crea cena recurrente con host rotation
- ✅ User agrega reglas a recurso ya creado (vía `set_group_module(true)` + `seed_module_rules`)
- ✅ User agrega gastos a evento (Phase 3)
- ✅ User crea asset con owners only (Phase 4)
- ✅ User agrega slots a asset después (Phase 4)
- ✅ User agrega booking + rotation + money a asset después (Phase 4)
- ✅ Un grupo tiene events + expenses + asset + fund simultáneamente
- ✅ Cero clases de app vertical-specific (`DinnerGroup`, `TravelGroup`, `PalcoGroup`, …)
- ✅ Cero `GroupType` dependencies (post Phase 5)
- ✅ Cero recurrencia group-level (post Phase 5)
- ✅ Resource-specific rules funcionan (vía `rules.resource_id`, scope precedence)
- ✅ Projections rebuildable from atoms (rebuild script idempotente)

---

## Audit Findings (Source)

Tres audits paralelos sintetizados aquí. Reports completos disponibles en transcript del 2026-05-10.

**Vertical leakage (8 sitios críticos):**
1. `GroupDraft.template = "recurring_dinner"` default
2. `Group.baseTemplate ?? "recurring_dinner"` fallback
3. `create_group_with_admin(p_base_template default 'recurring_dinner')`
4. `seed_dinner_template_rules` legacy wrapper
5. `RuleRepository` mock `guard templateId == "recurring_dinner"`
6. `TemplateRepository` fixture solo `recurring_dinner`
7. `FounderOnboardingCoordinator` "V1 only ships recurring_dinner" comment
8. `groups.event_label` flat column (paridad expired)

**Capability gaps:**
- Cero `CapabilityBlock` protocol/struct
- `CapabilityResolver` solo module-level (no capability-level)
- ResourceSeries no existe (recurrence implícita en `events.parentEventId`)
- Rules scope falta `series_id`, `occurrence_id`, `membership_id`

**Atom/Projection gaps:**
- `system_events` ✓, `vote_ballots` ✓ (atoms ok)
- `votes.status`, `fines.status`, `event_attendance` mutables (deberían ser projections)
- `groups.fund_balance` stored (drift risk)
- No `ledger_entries` (money no atomizado)
- No `rsvp_actions` (RSVP no atomizado)

---

## Decisión inmediata

**Empezar Phase 0 cleanup** (esta semana, no rompe nada):

1. Cleanup migration: drop `groups.event_label` (paridad expired)
2. Deprecation comments: `seed_dinner_template_rules`, `Group.baseTemplate` default, `RuleRepository` dinner guard, `TemplateRepository` fixture
3. README updates: marcar áreas como "legacy V1 — see OpenPlatform_Phase0"

Después del cleanup, **Phase 1: formalize protocols** (`CapabilityBlock`, `ResourceBuilder`, expand `CapabilityResolver`). Sin tocar UI ni RPCs todavía.

¿Empiezo con Phase 0 cleanup?
