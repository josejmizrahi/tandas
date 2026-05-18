# Resource Detail UX Refactor — Pass 1: Universal Tabs

**Fecha:** 2026-05-18
**Estado:** Brainstorming → spec (approved verbally by founder, scope: Pass 1 only)
**Decisor:** founder (jose.mizrahi@quimibond.com)
**Predecesores:**
- `docs/superpowers/specs/2026-05-14-universal-resource-detail-redesign.md` (Apple-Invites-inspired hero + sticky CTA)
- `docs/superpowers/specs/2026-05-15-level-3-resource-polish.md` (per-type detail scaffolds)
- `docs/superpowers/specs/2026-05-15-level-5-capability-management.md` (ManageCapabilitiesSheet + dependency cascade)
- Memorias: `project_resource_detail_capability_driven`, `feedback_no_hardcoded_verticals`, `feedback_rules_ux_human`, `feedback_dont_strip_working_entries`
**Constitution:** `Plans/Active/Vision.md` (2 primitives: Resource + Capability)
**Freeze caveat:** Consistency Audit freeze 2026-05-17 blocks new primitives/types/capabilities/features. This spec is **UX-only**: zero ontology, capability catalog, RPC, or engine changes. Founder approved proceed during freeze.

## Problema

La doctrina UX nueva (founder 2026-05-18) dice que las capabilities deben ser **infraestructura invisible**, no objetos primarios de UX. Hoy el detail es:

- Un solo `ScrollView` con 32 secciones del catálogo apiladas por prioridad
- `ManageCapabilitiesSheet` con toggles "ACTIVAS / Disponibles" como entry point primario via `Ajustes → Manejar capabilities`
- El usuario debe entender el concepto de "capability" para configurar el recurso

La doctrina nueva pide que el usuario piense en **intenciones humanas** ("ver actividad", "ver reglas", "ver conexiones") en lugar de en infraestructura ("activar capability X"). Las capabilities siguen siendo canónicas internamente — solo deja de exponerse al usuario como modelo primario.

## Objetivo (Pass 1)

Reemplazar el scroll-único por **5 pestañas universales** que organicen las secciones existentes por intención del usuario:

1. **Overview** — qué es este recurso, qué pasa, qué puedo hacer ya
2. **Activity** — quién hizo qué, en orden cronológico
3. **Rules** — qué reglas aplican aquí
4. **Connections** — con qué otros recursos se relaciona
5. **Governance** — quién puede hacer qué + (avanzado) capabilities + archivar

**Demote `ManageCapabilitiesSheet`** al sub-bloque "Avanzado" dentro de la pestaña Governance. El sheet sigue existiendo (los flujos enable/disable/cascade ya están testeados); solo deja de ser entry point primario.

**Out of scope (Passes posteriores):**
- Pestañas per-type (Space → Reservations/Access/Schedule/Usage/Costs etc.)
- Lazy activation (`LazyCapabilityActivator`) — capabilities siguen activándose explícitamente via Governance > Avanzado en Pass 1
- Empty-state copy registry (`IntentCopyRegistry`) — Pass 1 usa copy inline mínima
- Nuevas secciones de cualquier tipo
- Cambios backend (RPCs, migrations, capability catalog)
- Renames de capability ids o sección ids
- Cambios al `CapabilityResolver`, `CapabilityCatalog.v1`, `ResourceCapabilityRepository`
- Cambios al wizard, edit sheets, rules engine, atom emission

## Approach

### 1. `CapabilitySection` gana un campo opcional `tabId`

```swift
public struct CapabilitySection: Identifiable {
    public let id: String
    public let priority: Int
    public let tabId: String          // NEW. Default "overview" via init
    public let isEnabledFor: (Set<String>) -> Bool
    public let isVisibleFor: ((ResourceDetailContext) -> Bool)?
    public let render: (ResourceDetailContext) -> AnyView

    public init(
        id: String,
        priority: Int,
        tabId: String = ResourceDetailTab.overview.id,   // default
        isEnabledFor: @escaping (Set<String>) -> Bool,
        isVisibleFor: ((ResourceDetailContext) -> Bool)? = nil,
        render: @escaping (ResourceDetailContext) -> AnyView
    ) { ... }
}
```

Default `tabId == "overview"` — secciones que no explicitan su tab caen en Overview, lo cual matchea el comportamiento actual (todo apilado). Sólo las secciones que cambian de tab necesitan declarar `tabId` distinto.

### 2. `ResourceDetailTab` enum nuevo

```swift
public enum ResourceDetailTab: String, CaseIterable, Identifiable, Sendable {
    case overview
    case activity
    case rules
    case connections
    case governance

    public var id: String { rawValue }
    public var label: String { ... }      // "General" / "Actividad" / "Reglas" / "Conexiones" / "Gobierno"
    public var symbol: String { ... }     // SF Symbols
}
```

Vive en `RuulFeatures/Features/Resources/Detail/ResourceDetailTab.swift` (~50 L). Sin registry — Pass 1 sólo conoce las 5 universales. Pass 2 introducirá un `ResourceTabRegistry` con tabs per-type.

### 3. Tab assignments en `registerDefaults()`

| Sección actual | Tab asignado | Razón |
|---|---|---|
| `ScheduleSectionView` | overview | "cuándo es" |
| `CapacityProgressSectionView` | overview | "cuántos caben" |
| `LocationSectionView` | overview | "dónde es" |
| `DescriptionSectionView` | overview | "de qué se trata" |
| `RSVPSectionView` | overview | "quién viene" — acción primaria del usuario |
| `CheckInSectionView` | overview | acción del host inline |
| `HostActionsSectionView` | overview | acciones de host |
| `MoneySectionView` | overview | resumen de dinero |
| `RotationSectionView` | overview | rotación próxima |
| `AssetCustodySection` | overview | "quién tiene esto" |
| `AssetOwnershipSection` | overview | "de quién es" |
| `AssetMaintenanceSection` | overview | estado del activo |
| `AssetBookingsSection` | overview | quién lo está usando |
| `SpaceCapacitySection` | overview | cuánto cabe |
| `SpaceOccupancySection` | overview | ocupación actual |
| `SpaceBookingsSection` | overview | reservas próximas |
| `FundBalanceSection` | overview | balance del fondo |
| `RulesSectionView` | **rules** | mueve a tab Rules |
| `ResourcesUsedSectionView` | **connections** | mueve a tab Connections |
| `ActivitySectionView` | **activity** | mueve a tab Activity |
| Todos los `Stubs/*SectionView` (Status, Recurrence, Deadline, Expiration, Participants, Attendance, GuestAccess, Assignment, Booking, Valuation, Inventory, Access, Delegation, Voting, Approval, Appeal, Consequence, Swap, Cancellation, Reminder, History) | overview | stubs siguen en Overview hasta que se materialicen; Pass 2-3 los redistribuye con las pestañas per-type |

**Sin renames, sin cambios de id, sin cambios de prioridad.** Sólo se agrega `tabId` al constructor de las 3 secciones que cambian de tab (Rules, ResourcesUsed, Activity).

### 4. `UniversalResourceDetailView` — segmented control debajo del hero

Layout nuevo:

```swift
ScrollView {
    VStack(alignment: .leading, spacing: RuulSpacing.xl) {
        liveBanner
        if !context.attentionActions.isEmpty {
            DetailAttentionView(context: context)
        }
        hero
        informationSection              // identity zones — siempre visibles

        RuulSegmentedControl(           // tab picker
            selection: $selectedTab,
            segments: ResourceDetailTab.allCases.map { ($0, $0.label) }
        )
        .padding(.top, RuulSpacing.xs)

        tabContent                      // swap por tab
    }
    .padding(...)
}
.safeAreaInset(edge: .bottom) { ResourcePrimaryCTA(...) }
.toolbar { ... }   // unchanged
```

`tabContent`:
```swift
@ViewBuilder
private var tabContent: some View {
    switch selectedTab {
    case .overview:    overviewSections
    case .activity:    activitySections
    case .rules:       rulesSections
    case .connections: connectionsSections
    case .governance:  governanceSections
    }
}
```

Cada `xSections` filtra el catálogo por `tabId == selectedTab.id` con `CapabilitySectionCatalog.shared.sectionsFor(context: context).filter { $0.tabId == ... }`. Empty state inline per-tab (ver §6).

State: `@State private var selectedTab: ResourceDetailTab = .overview`. Sin persistencia entre presentaciones del detail — siempre arranca en Overview.

### 5. Governance tab content

`GovernanceTabView` (~140 L, nuevo) consume:

```
┌──────────────────────────────────────────┐
│  Capabilities activas                     │
│  ┌──────────────────────────────────┐    │
│  │ ✓ RSVP                       ⋯   │    │  ← inline render of ManageCapabilitiesSheet rows
│  │ ✓ Check-in                   ⋯   │    │
│  │ ✓ Ledger                     ⋯   │    │
│  └──────────────────────────────────┘    │
│                                           │
│  Disponibles                              │
│  ┌──────────────────────────────────┐    │
│  │ ○ Voting           [Activar]     │    │
│  │ ○ Rotation         [Activar]     │    │
│  └──────────────────────────────────┘    │
│                                           │
│  ─────────                                │
│  Avanzado                                 │
│  📦 Archivar este recurso                 │
└──────────────────────────────────────────┘
```

Implementación: extraer el contenido del `body` actual de `ManageCapabilitiesSheet` a una `AdvancedCapabilitiesView` reusable (~250 L, basically the existing `body` minus el NavigationStack wrapper + ruulSheetToolbar). El sheet `ManageCapabilitiesSheet` sigue existiendo y embed la nueva view por dentro, así que el callsite externo no se rompe estructuralmente.

**Callsites externos (grep 2026-05-18):**
- `UniversalResourceDetailView.swift:75` — `SettingsSectionView(onPresentEnableCapability:...)` — **se elimina en este pass**.
- `ResourceDetailSheet.swift:76` — `.fullScreenCover(isPresented: $enableCapabilityPresented) { ManageCapabilitiesSheet(...) }` — el cover queda sin triggerer (porque `SettingsSectionView` que disparaba `onPresentEnableCapability` se elimina). El cover + el state `enableCapabilityPresented` quedan como dead code. **Pass 1 cleanup:** eliminar el `fullScreenCover` y el `@State enableCapabilityPresented` de `ResourceDetailSheet`. `ManageCapabilitiesSheet` queda sin callers vivos pero se mantiene como surface estable y como wrapper del AdvancedCapabilitiesView reusable.

`GovernanceTabView` wraps `AdvancedCapabilitiesView` + archive button + (futuro) role/permission summary placeholder.

**Demote del entry point:** `SettingsSectionView` deja de renderizar "Manejar capabilities" — esa ruta vive ahora en la pestaña Governance. `SettingsSectionView` se borra del body de `UniversalResourceDetailView` (su `onPresentEnableCapability` callback se elimina del contexto). Si sólo queda `onArchive`, ese también se mueve a Governance. El archivo `SettingsSectionView.swift` queda como dead code para borrar en Pass 1 cleanup.

### 6. Empty states per tab (Pass 1 inline)

**Semántica:** El empty-state a nivel de tab dispara **sólo cuando cero secciones del catálogo matchean** ese tab (después de aplicar `isEnabledFor` + `isVisibleFor`). Si una sección matchea pero internamente tiene contenido vacío (ej. `RulesSectionView` con la capability `rules` activa pero 0 rules existentes), la sección sigue renderizando su propia card vacía interna — el tab no muestra el empty-state global.

Cada tab que pueda quedar vacío renderiza una card de un solo párrafo + CTA opcional:

| Tab | Estado vacío | Copy | CTA |
|---|---|---|---|
| Overview | nunca vacío (hero + INFORMACIÓN siempre presentes) | — | — |
| Activity | sin eventos en `system_events` para este recurso | "Aún no hay actividad. Cuando alguien interactúe con este recurso, lo verás aquí." | ninguno |
| Rules | sin rules con scope=resource Y sin rules heredadas | "Sin reglas propias. Las reglas del grupo aplican aquí por defecto." | "Agregar regla" → existing rules sheet (the `RulesSectionView` button) |
| Connections | sin `resource_links` desde o hacia este recurso | "Aún no hay recursos vinculados. Vincula otros recursos para mostrar cómo se relacionan." | "Vincular recurso" → existing `LinkResourcePickerSheet` (the `ResourcesUsedSectionView` button) |
| Governance | sin capabilities activas (improbable) | "Sin capabilities activas." | nada — la sección "Disponibles" abajo ya tiene los CTAs Activar |

Copy es inline en cada `xSections` view-builder. Pass 3 lo refactorea a un `IntentCopyRegistry` cuando se introduzcan empty states más sofisticados.

### 7. CTA primario + `⋯` menu — sin cambios

El `safeAreaInset(.bottom)` con `ResourcePrimaryCTA` y el toolbar `⋯` siguen renderizando **sin importar la pestaña activa**. La identidad del recurso (incluyendo "qué es la acción primaria ahora") es invariante, no por-tab. Resolvers `primaryAction(...)` y `secondaryActions(...)` no se tocan.

## File structure (post-Pass 1)

```
ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/
├── UniversalResourceDetailView.swift            MODIFY (~720 L → ~620 L; segmented + tab dispatch)
├── ../ResourceDetailSheet.swift                 MODIFY: drop fullScreenCover + enableCapabilityPresented state
├── ResourceDetailTab.swift                      NEW (~60 L)
├── ResourceDetailContext.swift                  MODIFY: drop onPresentEnableCapability (governance owns it)
├── CapabilitySection.swift                      MODIFY (+1 field `tabId`, default "overview")
├── ManageCapabilitiesSheet.swift                MODIFY: thin shell wrapping AdvancedCapabilitiesView
├── AdvancedCapabilitiesView.swift               NEW (~250 L; extracted from ManageCapabilitiesSheet body)
├── GovernanceTabView.swift                      NEW (~140 L; wraps AdvancedCapabilitiesView + archive)
├── Sections/
│   ├── RulesSectionView.swift                   MODIFY: definition gains tabId: .rules
│   ├── ResourcesUsedSectionView.swift           MODIFY: definition gains tabId: .connections
│   ├── ActivitySectionView.swift                MODIFY: definition gains tabId: .activity
│   ├── SettingsSectionView.swift                DELETE (functionality moves to GovernanceTabView)
│   └── (todas las demás)                        UNCHANGED — default tabId: .overview
└── (resto sin cambios)
```

Net delta:
- Files: +3, -1 = +2 (ResourceDetailTab, AdvancedCapabilitiesView, GovernanceTabView; minus SettingsSectionView)
- LoC: +~450 / -~100 ≈ +350 net (mostly the extracted advanced view)
- `UniversalResourceDetailView`: -~100 L net (delete SettingsSection block + sheet plumbing, add tab dispatch)
- Action surfaces: unchanged (sticky CTA + ⋯ menu)
- Tabs: 0 → 5

## Behavior preserved

- Capability-driven section inclusion: cada sección sigue gateando en `enabledCapabilities.contains(...)`. Catálogo intacto.
- Todos los sheets existentes (rules, attendees, contribute, edit right, etc.) sobreviven sin cambios.
- `EventInteractor`, `EventDetailPresenter`, `EventDetailCoordinator` intactos.
- `CapabilityResolver`, `CapabilityCatalog.v1`, dependencies resolver intactos.
- `ManageCapabilitiesSheet` sigue funcionando si algún callsite externo (poco probable) lo presenta.
- Enable / disable / config edit / cascade — todo el flujo actual sigue vivo, sólo cambia ubicación visual.

## Behavior changed (deliberate)

1. **Entry point único de capability mgmt es Governance tab**. El row "Manejar capabilities" del `SettingsSectionView` desaparece. Si un usuario tap antes ahí, ahora tap en pestaña Governance.
2. **Scroll position resetea entre tabs** (Pass 1 default). Cada tab arranca al top. Es aceptable porque cada tab es una vista distinta.
3. **Activity, Rules, Connections ya no aparecen en el scroll de Overview**. Quien busque "qué reglas aplican" debe tap en Rules. Es exactamente el punto del refactor.
4. **`SettingsSectionView` muere**. Si tenía `onArchive` callback, ese se mueve a Governance > Avanzado.
5. **`ResourceDetailContext.onPresentEnableCapability` se elimina**. Governance tab usa directamente `app.resourceCapabilityRepo` (igual que el sheet hace hoy).

## Tests

Test critical (Swift Testing en `RuulFeatures/Tests/` y `RuulCore/Tests/`):

| Test | Qué valida |
|---|---|
| `CapabilitySection_TabIdDefault` | Sección creada sin `tabId` recibe `"overview"` |
| `CapabilitySectionCatalog_TabFiltering` | `sectionsFor(context:).filter { $0.tabId == "rules" }` retorna sólo `RulesSectionView` para un event con rules cap on |
| `ResourceDetailTab_AllCases` | Las 5 tabs en orden esperado con labels/symbols esperados |
| `UniversalResourceDetailView_TabSwitching` (snapshot) | Render con tab=overview vs tab=activity muestra diferentes secciones |
| `GovernanceTabView_EmptyAndPopulated` (snapshot) | Con 0 caps enabled y con 3 caps enabled |
| `ManageCapabilitiesSheet_StillFunctional` | El sheet sigue presentando AdvancedCapabilitiesView (regression guard si algún callsite externo subsiste) |

Manual smoke (simulador iOS 26):
1. Open event detail → 5 tabs visibles → Overview default
2. Tap cada tab → contenido coherente
3. Open fund detail → Activity tab vacío con teaching copy
4. Open fund detail → Governance tab → enable Voting → activación funciona
5. Open asset detail → custodian sigue apareciendo en Overview
6. Open right detail → Rules tab vacío con teaching copy
7. RSVP / Check-in / Aportar siguen funcionando desde Overview

## Riesgos

| Riesgo | Mitigación |
|---|---|
| Usuarios acostumbrados al scroll único se confunden con tabs | Tab "Overview" mantiene casi todo el contenido actual; sólo 3 secciones se mueven (Rules/Activity/Connections). Onboarding implícito por iconos + labels en español |
| `RuulSegmentedControl` no tiene espacio para 5 segments en iPhone SE | Cálculo: 375pt width – ~24pt padding = ~350pt / 5 = 70pt por segment. "Conexiones" (label más largo) ≈ 63pt en callout. Cabe pero ajustado. Verificar en simulator iPhone SE 3rd gen; si overflow, fallback a `ScrollView(.horizontal)` wrap o abreviar labels ("Conex." / "Gob.") |
| Algún callsite externo invoca `ManageCapabilitiesSheet` y se rompe | Grep antes de modificar; el sheet sigue funcional como thin shell wrapping AdvancedCapabilitiesView |
| Empty states inline crecen y duplican copy | Acepta esta deuda en Pass 1; Pass 3 introduce `IntentCopyRegistry` |
| Stub sections (21 archivos en `Sections/Stubs/`) inflate Overview tab | Aceptable Pass 1 — los stubs ya renderizan "Próximamente" + son condicionales a capability enabled. Pass 2-3 distribuye a tabs per-type |
| `SettingsSectionView` deletion breaks DEBUG previews | Eliminar el archivo + sus 3 previews. Sin callers fuera del propio archivo (grep confirma) |
| Scroll reset entre tabs molesta si user estaba investigando | Acepta Pass 1 default; si feedback duele, agregar `ScrollViewReader` con id-per-tab |

## Decisiones explícitas

1. **`RuulSegmentedControl`, no `TabView`**. TabView nativo es para top-level navigation; el detail ya está dentro de un sheet/push. Segmented preserva el flow de scroll + sticky CTA del redesign 2026-05-14.
2. **Segmented control vive dentro del ScrollView**, no sticky. Scrollea con el contenido. Sticky lo evalúa Pass 2 si hace falta.
3. **Tab assignment es declarativo en la sección** (`tabId` field), no en el view. Mantiene el principio de Rule 6 del ontology constitution: el view es renderer, las secciones declaran su comportamiento.
4. **Pass 1 NO introduce `ResourceTabRegistry`** — las 5 tabs son hardcoded en `ResourceDetailTab` enum. Pass 2 las hace extensibles per-type.
5. **Stubs van a Overview en Pass 1**. Distribución per-tab de los 21 stubs se difiere a Pass 2-3 cuando se introduzcan las tabs per-type.
6. **No persistencia de selectedTab**. Cada presentación del detail arranca en Overview. Pass 2 evaluará persistir en `AppState` per-resource-id si el feedback pide.
7. **CTA + ⋯ menu son invariantes a la tab activa**. La identidad del recurso (qué es y qué puedo hacer) no cambia al cambiar de tab.
8. **`SettingsSectionView` se elimina**, no se deja deprecado. Es un archivo sin callers externos; mejor borrarlo limpio que dejarlo dead code.

## Done When

- 5 pestañas universales renderizan en `UniversalResourceDetailView`
- `CapabilitySection.tabId` field existe con default `"overview"`
- `RulesSectionView`, `ResourcesUsedSectionView`, `ActivitySectionView` declaran su tab no-default
- `GovernanceTabView` muestra capabilities activas + disponibles + archivar
- `ManageCapabilitiesSheet` no es entry point primario en ningún tab/section
- Empty states inline para Activity / Rules / Connections / Governance (cuando vacíos)
- Smoke pass en simulador: 5 tabs visibles, contenido coherente, no regresiones de RSVP/checkin/aportar
- `xcodebuild test` verde
- Codegen sin diff
- Build clean sin warnings

## Out of scope (Pass 2+)

- **Pass 2**: pestañas per-type (Space → Reservations/Access/Schedule/Usage/Costs; Fund → Balance/Contributions/Expenses/Approvals; etc.). Introduce `ResourceTabRegistry`. Redistribuye stubs.
- **Pass 3**: lazy capability activation (`LazyCapabilityActivator`) reemplaza Governance > Activar como path primario. Intent CTAs ("Reservar este espacio" auto-init booking capability).
- **Pass 4**: `IntentCopyRegistry` para empty states + recommended actions per (resource_type, tab).
- Connections: human framing copy per resource_type ("Este fondo financia estos activos") — Pass 3.
- Rules: template-first UX dentro del tab Rules — Pass 3, requiere refactor de `ResourceRulesSheet`.
- Activity: per-resource filter en `SystemEventRepository.query(referenceId:)` — Pass 3, requiere repo extension.

## Referencias

- Founder doctrine 2026-05-18 (in-thread): capabilities = invisible infrastructure
- `Plans/Active/Vision.md` — 2-primitive doctrine
- `Plans/Active/HierarchyReference.md` §3 — capability catalog
- `Plans/Active/UniversalRuleTemplates.md` — Rule 6: view-as-renderer
- `Plans/Active/ConsistencyAudit_2026-05-17.md` — feature freeze rationale
- `docs/superpowers/specs/2026-05-15-level-5-capability-management.md` — ManageCapabilitiesSheet origin
