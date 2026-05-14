# Frontend Remodel — alinear el iOS app a la Constitución

**Fecha:** 2026-05-14
**Estado:** Brainstorming → spec
**Decisor:** founder (jose.mizrahi@quimibond.com)
**Constitución:** `Plans/Active/Constitution.md` (canónico 2026-05-13)
**Plan canónico de shell:** `Plans/Active/AppShell.md`
**Principios visuales:** `docs/DesignPrinciples.md`
**Spec previo (parcial):** `docs/superpowers/specs/2026-05-11-universal-event-detail-migration-design.md`

## Problema

El BE está alineado con la Constitución (Resource polimórfico, atoms append-only, capabilities server-side post mig 00164), pero el FE quedó **a medio migrar**:

1. **La vertical legacy `Features/Events/` sigue siendo dueña del shell.** `MainTabView.swift` mide 1619 L con ~30 `@State` props; `HomeView.swift` mide 821 L. Ambos viven dentro de `Features/Events/Views/` — la app entera arranca en una carpeta event-specific.

2. **Dos detail screens coexisten.** `Resources/Detail/UniversalResourceDetailView` (polimórfica, capability-driven — lo correcto) y `Events/Views/EventDetailHost.swift` (438 L) + `Events/Coordinator/EventDetailCoordinator.swift` (434 L). El spec 2026-05-11 aprobó matar el segundo; aún no se ejecutó.

3. **Drift respecto a `AppShell.md`.** El plan canónico define 5 tabs (`Home · Inbox · Create · Activity · Profile`). El código real tiene `home · group · create · decisions · profile`: Inbox se fusionó con Home, Activity bajó a linkout, apareció Group como tab con `Features/Group/` (carpeta separada de `Features/Groups/`, 5 archivos + 512 L de `GroupTabView`).

4. **20 sitios** con `switch resource.resourceType { case .event/.fund/.asset/.slot/.space/.right }` en views. Mayoría son icon lookup pero rompen la regla "no vertical-specific en SwiftUI" (memoria `feedback_no_hardcoded_verticals`).

5. **Higiene SwiftUI degradada vs `DesignPrinciples.md`:**
   - `.font(.system(...))` directo: **115** call-sites (violación §5)
   - `DateFormatter()` ad-hoc: **22** call-sites (violación §3)
   - No hay SwiftLint rule que enforce; cada PR puede reintroducirlos
   - Bueno: 0 `@StateObject`/`ObservableObject`, 0 `NavigationView` (stack moderno limpio)

## Objetivo

App iOS donde:
- El shell, los detail screens, y el create flow son **resource-type-agnostic**. Ningún `switch resourceType` en SwiftUI; toda discriminación pasa por `CapabilityResolver` y un nuevo `ResourceTypeChrome` (icon/color/label).
- Las 5 tabs de `AppShell.md` están alineadas con el código (`Home · Inbox · Create · Activity · Profile`).
- Ningún archivo de feature view supera ~250 L; `RootShell` queda en <200 L y delega routing a un `RootRouter` dedicado.
- Tipografía, espaciado, formato de fechas, status indicators, motion, haptics, empty states siguen tokens; SwiftLint custom rules fallan PRs que reintroduzcan ad-hoc.
- iOS 26 features explotadas donde Apple las pone: `tabBarMinimizeBehavior(.onScrollDown)` ✅ ya está, `.glassEffect()` solo en floating chrome, `ScrollTransition` en cards al entrar al viewport, `contentMargins` en lugar de paddings manuales en scrollviews.

## Approach — tres pasadas secuenciales

Cada pasada es un PR mergeable y demoable. Order matters: Pass 2 y Pass 3 dependen estructuralmente de Pass 1.

### Pass 1 · Extirpar la vertical Events (1 semana)

**Objetivo:** que la app arranque, navegue, y muestre detalle de cualquier `Resource` sin que la carpeta `Features/Events/` exista en su forma actual.

**File moves exactos:**

| De | A | Notas |
|---|---|---|
| `Features/Events/Views/MainTabView.swift` (1619 L) | troceado a `Features/Shell/` | Ver "Decomposición del shell" abajo |
| `Features/Events/Views/HomeView.swift` (821 L) | `Features/Home/HomeView.swift` | Polimorfizar: usar `LiveResourceRepository.list(groupId:)` no `eventRepo`; ver `AppShell.md §1` |
| `Features/Events/Views/EventDetailHost.swift` (438 L) | **DELETE** | Sustituido por `UniversalResourceDetailView`. Migra deeplinks al `RootRouter.openResource(id:)` |
| `Features/Events/Coordinator/EventDetailCoordinator.swift` (434 L) | `Features/Resources/Detail/EventInteractor.swift` (renombrar + slim) | Pasa de "coordinator dueño de view" a `EventInteractor` inyectado vía `@Environment` — el patrón del spec 2026-05-11 |
| `Features/Events/Coordinator/HomeCoordinator.swift` | `Features/Home/HomeCoordinator.swift` | Renombrar; expande para leer `resources` no `events` |
| `Features/Events/Coordinator/EventLedgerCoordinator.swift` | `Features/Resources/Money/ResourceLedgerCoordinator.swift` | Generalizar a cualquier resource con capability `ledger` |
| `Features/Events/Coordinator/EventRulesCoordinator.swift` | `Features/Rules/ResourceRulesCoordinator.swift` | Generalizar (rules scope = `resource` aplica a cualquier type) |
| `Features/Events/Coordinator/EventCreationCoordinator.swift` | `Features/Create/ResourceCreationCoordinator.swift` | Ya hay `ResourceWizardCoordinator.swift` (557 L) — consolidar a uno |
| `Features/Events/Coordinator/EventEditCoordinator.swift` | `Features/Resources/Edit/ResourceEditCoordinator.swift` | Generalizar; metadata patch via `rpc update_event_metadata` queda pero se renombra a `update_resource_metadata` en Pass 2 (BE) |
| `Features/Events/Views/CreateEventView.swift` (313 L) | **DELETE** | Reemplazada por `ResourceWizardSheet` polimórfica. El form de "event" pasa a ser un `ResourceBuilder` registrado para `resource_type=event` |
| `Features/Events/Views/EditEventView.swift` | **DELETE** | Idem; edit fluye por `ResourceEditCoordinator` + form polimórfico |
| `Features/Events/Views/PastEventsView.swift` | `Features/Resources/Past/PastResourcesView.swift` | Filter por capability `recurring` o status closed; aplicable a slots/bookings futuros |
| `Features/Events/Views/CheckInScannerView.swift` | `Features/Resources/CheckIn/CheckInScannerView.swift` | Capability `check_in` — no event-specific |
| `Features/Events/Subviews/EventCard.swift` (gold standard per DP) | `RuulUI/Patterns/Resource/ResourceHeroCard.swift` | Renombrar + parametrizar por capabilities (cover, date, RSVP count). Single hero pattern |
| `Features/Events/Subviews/EventRSVPStateView.swift` (330 L) | `RuulUI/Patterns/Resource/RSVPStateView.swift` | Capability `rsvp` — primitive del DS |
| `Features/Events/Subviews/EventLocationCard.swift` | `RuulUI/Patterns/Resource/LocationCard.swift` | Capability `location` |
| `Features/Events/Subviews/RecurrenceOptionsCard.swift` | `RuulUI/Patterns/Resource/RecurrenceOptionsCard.swift` | Capability `scheduling` |
| `Features/Events/Subviews/LocationAutocompletePicker.swift` | `RuulUI/Patterns/Resource/LocationAutocompletePicker.swift` | Idem |
| `Features/Events/Sheets/*.swift` (10 sheets) | `Features/Resources/Sheets/` o capability-scoped | `AddLedgerEntrySheet` → `Money/`; `CloseEventSheet` → `HostActions/`; `RemindAttendeesSheet` → `RSVP/`; etc. |
| `Features/Group/Views/GroupTabView.swift` (512 L) | **DELETE** (Pass 2 lo absorbe) | Pass 1 lo deja existente pero marca `@available(*, deprecated, message: "Pass 2")`. No se borra hasta que Pass 2 mueva sus 4 sub-tabs a `GroupSettingsSheet` |

**Decomposición del shell** (sustituye `Events/Views/MainTabView.swift`):

```
Features/Shell/
├── RootShell.swift               (~150 L)   — TabView nativo + tint + minimize + body
├── RootShellState.swift          (~80 L)    — @Observable: selectedTab, sheet/route state
├── RootRouter.swift              (~200 L)   — handle(deeplink:), openResource, present(.create/.invite/.switch), etc.
├── Tabs/
│   ├── HomeTab.swift             (~60 L)    — wraps HomeView + NavigationStack
│   ├── InboxTab.swift            (~60 L)    — moved out of HomeView
│   ├── CreateTabIntercept.swift  (~40 L)    — the "+" tab that opens ResourceWizard cover
│   ├── ActivityTab.swift         (~60 L)    — wraps GroupHistoryView
│   └── ProfileTab.swift          (~60 L)    — wraps ProfileView
└── GroupSwitcherHeader.swift     (~80 L)    — already exists, moves here
```

**Ningún archivo > 250 L.** `RootShell.body` en Pass 1 **preserva el inventario actual de tabs** (`home · group · create · decisions · profile`) para no mezclar refactor estructural con cambio de IA en un solo PR. Pass 2 es el que vira a los 5 tabs canónicos.

```swift
// Pass 1 — same tabs as today, but ahora en Shell/, no en Events/
TabView(selection: router.tabBinding) {
    HomeTab().tag(Tab.home)
    GroupTab().tag(Tab.group)              // ← absorbe GroupTabView legacy; muere en Pass 2
    CreateTabIntercept().tag(Tab.create)
    DecisionsTab().tag(Tab.decisions)      // ← se fusiona con Inbox en Pass 2
    ProfileTab().tag(Tab.profile)
}
.tint(app.activeGroup?.category.ramp.accent ?? .ruulTextPrimary)
.tabBarMinimizeBehavior(.onScrollDown)
.environment(router)
.modifier(RootShellSheets(router: router))   // toda la sheet/route soup vive aquí
.task { await router.bootstrap() }
```

`RootShellSheets` es un `ViewModifier` dedicado que centraliza los ~14 `.sheet(item:)` / `.fullScreenCover()` que hoy se apilan en `MainTabView.body`. Cada slot lee de `router.activeRoutes` y dispara su sheet correspondiente. Esto saca ~400 L de body del shell sin cambiar comportamiento.

Los ~14 `.sheet(item:)` / `.fullScreenCover()` que hoy se apilan en `MainTabView.body` se mueven a un `RootShellSheets` ViewModifier dedicado.

**Capability chrome registry** — nuevo en `RuulCore/Capabilities/`:

```swift
// ResourceTypeChrome.swift  (~40 L)
public struct ResourceTypeChrome: Sendable {
    public let symbol: String       // SF Symbol name
    public let semanticColor: Color // foreground tint
    public let labelKey: String     // localized

    public static func resolve(_ type: ResourceType) -> ResourceTypeChrome { ... }
}
```

Single source para los 20 `case .event/.fund/...` repartidos. SwiftUI llama `ResourceTypeChrome.resolve(resource.resourceType).symbol` — el switch vive una sola vez.

**Behavior preservado:**
- Todas las rutas existentes (deeplinks de push, universal links, RSVP from notification) siguen funcionando — `RootRouter` toma callbacks idénticos a los handlers que hoy viven inline en `MainTabView`.
- `EventInteractor` se conforma desde `EventDetailCoordinator` migrado (ya empezado en spec 2026-05-11) — RSVP intent, check-in, host actions intactos.
- `HomeView` nuevo lee `LiveResourceRepository.list(groupId:)` filtrado por capabilities `scheduling`/`rsvp` para la sección `Upcoming`, no `EventRepository`.

**Test coverage Pass 1:**
- Swift Testing en `RuulFeatures/Tests/Shell/`: `RootRouterTests` (deeplink routing, tab intercept, sheet stacking)
- Mock-driven `#Preview` para cada `Tab*` con AppState mock y 0/1/N groups
- Smoke iOS 26 simulator: arranque cold start, switch group, deeplink a notification, abrir wizard, abrir detail, RSVP — todo verde

**DoD Pass 1:**
- `Features/Events/` no existe en repo (eliminado en bulk)
- 0 referencias a `EventDetailHost`, `MainTabView` (Events namespace), `HomeView` (Events namespace)
- `xcodebuild test` green
- Codegen sin diff
- Smoke completo en simulador iOS 26
- Diff neto: ~-3000 L (consolidación + reuso)

### Pass 2 · AppShell canónico (1 semana)

**Objetivo:** las 5 tabs reales = las 5 tabs de `AppShell.md`. `Group` deja de ser tab.

**Cambios:**

Inventario de tabs vira de `home · group · create · decisions · profile` (Pass 1) → `home · inbox · create · activity · profile` (canónico `AppShell.md`).

1. **Inbox vuelve a tab top-level** (hoy es sección embebida en Home + lo que era `decisions`). Crear `Features/Inbox/InboxView.swift` (~200 L) con filter chips (`Urgent · Approvals · Votes · Payments · Requests · Confirmations · Reminders`). El badge del tab lee `inboxCoordinator.actions.count`. La sub-sección "Pendientes" de HomeView se borra (queda solo `NeedsAttention` con urgencia ≥ medium como preview).

2. **Activity sustituye a `Decisions` como cuarto tab**. Existe ya `GroupHistoryView` (265 L); renombrar a `ActivityView`, mover a `Features/Activity/`. Source única: `systemEventRepo` (polimórfico por `event_type`). Decisions desaparece — votos pendientes viven en Inbox, votos cerrados en Activity con filter `Governance`.

3. **Tab `Group` se elimina.** Su contenido se divide:
   - `GroupOverviewSubTab` (449 L) → secciones embebidas en `HomeView` (member ramp, recent activity preview) + linkout "Ver detalles del grupo" → `GroupInfoSheet`
   - `GroupMoneyView` (394 L) → tab `Activity` con filter `Money`, o linkout en `ProfileView.MyBalances` (cross-group)
   - `MembersSubTab` → `GroupInfoSheet → MembersSection`
   - `GroupMoreSubTab` → distribuido entre `GroupSettingsSheet` y `ProfileView → Settings`

4. **Botón Create centralizado.** Hoy hay `CreateEventView` + `ResourceWizardSheet` + builders ad-hoc. Pass 1 ya consolidó a `ResourceWizardSheet`; Pass 2 añade el `TypePicker` con las 6 categorías canónicas (`Popular · Coordination · Money · SharedThings · Governance · Custom`) leyendo `CapabilityResolver.creatableTypes(group:)` runtime.

5. **`Features/Group/` y `Features/Groups/` se unifican** a `Features/Groups/` con sub-folders `Switcher/`, `Settings/`, `Members/`, `Invites/`.

**Files que mueren en Pass 2:**
- `Features/Group/Views/GroupTabView.swift` (deprecated en Pass 1)
- `Features/Group/Overview/GroupOverviewSubTab.swift`
- `Features/Group/Members/MembersSubTab.swift`
- `Features/Group/More/GroupMoreSubTab.swift`
- La carpeta `Features/Group/` entera

**DoD Pass 2:**
- 5 tabs = `Home · Inbox · Create · Activity · Profile` (literal match con `AppShell.md`)
- 0 archivos en `Features/Group/`; todo `Features/Groups/`
- Deeplinks que apuntaban a `Group` tab se rerutean a `Activity` o `GroupInfoSheet`
- Smoke green

### Pass 3 · Hygiene + iOS 26 polish (1 semana)

**Sweep mecánico (PRs separadas para revisar):**

1. **Tipografía:** `.font(.system(...))` (115 sites) → tokens de `RuulTypography`. Donde no exista token apropiado, **añadir el token primero** (DP §5). SwiftLint custom rule `no_system_font` en `.swiftlint.yml`.

2. **Fechas:** `DateFormatter()` (22 sites) → `Date+EventFormatting` helpers. Si falta helper, añadirlo en `RuulUI/Modifiers/Date+EventFormatting.swift` (DP §3). SwiftLint custom rule `no_ad_hoc_dateformatter`.

3. **Status indicators audit:** revisar cada `Text("...").background(Color.X)` y migrar a `RuulStatusDot` primitive (DP §4).

4. **Empty / Loading / Error states audit:** views que renderean `ProgressView` o `Text("No hay…")` puro pasan a `LoadingStateView` / `ErrorStateView` / `EmptyStateView` (DP §9-§10).

5. **iOS 26 polish:**
   - `.glassEffect()` en floating chrome: `GroupSwitcherHeader`, sticky CTA del `UniversalResourceDetailView`, FAB hover state si aplica. Cero en content cards (DP §1).
   - `ScrollTransition` en cards al entrar al viewport (subtle scale 0.96 → 1.0). Aplica a `ResourceHeroCard`, `ActionRow`, `ActivityRow`.
   - `.contentMargins(.scrollIndicators, RuulSpacing.s4)` en lugar de paddings manuales en scrollviews.
   - `.scrollEdgeEffectStyle(.soft)` en lists (smooth fade en bordes iOS 26).
   - `.symbolEffect(.bounce, value: ...)` en counters animados (badge inbox, RSVP count).

6. **Accessibility audit checklist** (DP §11):
   - Dynamic Type pass hasta `xxxLarge`: cada view con `#Preview(traits: .sizeThatFitsLayout) { ... }` + `.dynamicTypeSize(.xxxLarge)` snapshot
   - VoiceOver pass: `accessibilityLabel` en every interactive surface, `accessibilityElement(children: .combine)` en cards compuestas
   - High contrast pass: snapshot en `.colorScheme(.dark)` + `Increase Contrast` enabled
   - Reduce Motion: confirmar que los tokens `.ruulSnappy` / `.ruulMorph` ya respetan; auditar `.spring(...)` ad-hoc

7. **Haptics audit** (DP §8): `SensoryFeedback` solo en (a) éxito de RPC, (b) error de RPC, (c) tab switch, (d) destructive confirmation. Auditar pulses ad-hoc.

**DoD Pass 3:**
- SwiftLint pasa en CI con las nuevas custom rules
- Snapshot tests Dynamic Type xxxLarge + dark + high-contrast green
- 0 `.font(.system(...))`, 0 `DateFormatter()` en `Features/`
- Smoke green en device físico iOS 26 (no solo simulador) — Liquid Glass real

## Architecture — boundaries finales (post Pass 3)

```
ios/Packages/
├── RuulCore/                                  — modelos, repos, capabilities, services
│   ├── AppState (cross-group, session)
│   ├── Capabilities/
│   │   ├── CapabilityCatalog (server-mirrored, post mig 00164)
│   │   ├── CapabilityResolver (computa what's enabled where)
│   │   └── ResourceTypeChrome (icon/color/label per type) ← NEW Pass 1
│   ├── Repositories/ (Mock + Live de cada uno)
│   └── PlatformModels/
├── RuulUI/                                    — design system, primitives, patterns
│   ├── Primitives/ (RuulCard, RuulButton, RuulAvatar, RuulStatusDot, RuulCoverView, ...)
│   ├── Patterns/Resource/ (ResourceHeroCard, RSVPStateView, LocationCard, ...) ← Pass 1 hub
│   ├── Patterns/States/ (EmptyStateView, LoadingStateView, ErrorStateView)
│   └── Tokens/ (RuulTypography, RuulSpacing, RuulRadius, RuulMotion, RuulSemanticColor)
└── RuulFeatures/                              — feature surfaces, capability-driven
    ├── Shell/                                 ← Pass 1
    │   ├── RootShell, RootShellState, RootRouter
    │   └── Tabs/ (HomeTab, InboxTab, CreateTabIntercept, ActivityTab, ProfileTab)
    ├── Home/                                  ← Pass 1 (ex-Events/Views/HomeView)
    ├── Inbox/                                 ← Pass 2 (promoted to tab)
    ├── Create/ (ResourceWizard + builders)    ← Pass 1 consolidación
    ├── Resources/
    │   ├── Detail/ (UniversalResourceDetailView + sections + EventInteractor + …)
    │   ├── Edit/, Past/, CheckIn/, Money/
    │   └── Sheets/ (capability-scoped)
    ├── Activity/                              ← Pass 2 (ex-History)
    ├── Profile/
    ├── Groups/ (Switcher, Settings, Members, Invites)  ← Pass 2 unificación
    ├── Rules/, Votes/, Fines/, Auth/, Onboarding/
```

**Reglas de dependencia:**
- `RuulFeatures` → `RuulUI` → `RuulCore` (one-way; SwiftPM lo enforza)
- Ningún `Features/X/` importa de `Features/Y/` excepto a través de tipos públicos
- `Coordinators` viven en `Features/X/Coordinators/`; nunca en `RuulCore`
- `RuulCore.AppState` solo expone repos y session — no UI state

## State ownership (clarificado Pass 1)

```
AppState (@Observable, app-wide)
  ├── session
  ├── activeGroupId / activeGroup
  ├── groups[], memberships[]
  └── repos: { resourceRepo, eventRepo*, ruleRepo, ... }   *kept until Pass 2 removes legacy callers

RootShellState (@Observable, shell-scope)
  ├── selectedTab
  ├── activeRoutes: [Route]    // stack-aware sheet/cover state
  └── pendingDeeplink

*Coordinator (@Observable, feature-scope)
  ├── data (resources, actions, votes, ...)
  ├── isLoading, error
  └── domain actions (load, refresh, perform RPC)
```

`MainTabView`'s 30 `@State` props se distribuyen así:
- 11 navegación → `RootShellState.activeRoutes`
- 8 coordinator handles → siguen en shell pero como `@State` de cada `*Tab.swift`
- 6 sheet presented bools → `RootRouter.present(.sheet(.X))`
- 5 misc cached state → coordinator-local

## No-goals explícitos

- NO redesign visual del DS (eso es otro ciclo)
- NO BE changes (Pass 2 tampoco — solo FE; mig 00164 ya cerró el catálogo)
- NO nuevas capabilities ni resource types (constitución §13 filter aplica)
- NO chat / feed social / dashboard enterprise (AppShell §No-goals)
- NO migración a UIKit ni a otro stack — SwiftUI exclusively (CLAUDE.md)
- NO refactor de `RuulCore.Capabilities/CapabilityCatalog.swift` (1115 L) — está OK funcionalmente; queue para otro spec
- NO tocar `Onboarding/` ni `Auth/` salvo cambios mecánicos de Pass 3

## Riesgos

| Riesgo | Mitigación |
|---|---|
| Deeplinks de push notification que apuntan a paths viejos rompen | Pass 1: `RootRouter.handle(deeplink:)` cubre exact mismo schema. Snapshot tests sobre el routing table |
| `EventInteractor` injection mediante `@Environment` choca con SwiftUI lifecycle | Spec 2026-05-11 ya validó el patrón; Pass 1 solo lo completa |
| Diff demasiado grande para revisar en un solo PR | Pass 1 sub-divide en 3 commits: (a) moves sin lógica nueva, (b) shell decomposition, (c) deletes |
| Beta1 demos durante el remodel | Pass 1 ejecutado en branch con feature flag `useNewShell` (toggled en `AppState`). Default `false`; flip al final |
| Smoke regression en device físico iOS 26 | Pass 1 + Pass 3 cierran con test en device, no solo simulador |
| 22 ad-hoc `DateFormatter` esconden formatos no cubiertos por helpers | Antes de migrar Pass 3, audit pass que cataloga cada formato; los nuevos formatos se añaden a `Date+EventFormatting` antes del sweep |

## Métricas de éxito

Pre/post Pass 1+2+3:

| Métrica | Hoy | Target post Pass 3 |
|---|---|---|
| Archivos > 500 L en `Features/` | 9 | 0 |
| Archivos > 250 L en `Features/` | ~25 | < 5 (todos justificados) |
| `switch resource.resourceType` en Views | 20 | 0 |
| `.font(.system(...))` direct calls | 115 | 0 |
| `DateFormatter()` ad-hoc | 22 | 0 |
| Tabs codificadas vs AppShell.md | drift | match exacto |
| Detail screens para `Resource` | 2 | 1 |
| Carpeta `Features/Events/` | existe | no existe |
| Diff neto código FE | — | ~-3000 a -4000 L |

## Próximos pasos

1. **User review de este spec** → ajustes inline si hay
2. **Invocar `writing-plans`** para el plan ejecutable de **Pass 1** únicamente (Pass 2 y Pass 3 generan sus propios planes al iniciar cada pasada)
3. Pass 1 se ejecuta con `superpowers:executing-plans` en branch dedicada con feature flag

## Referencias

- Constitución (canónica): `Plans/Active/Constitution.md`
- Shell plan: `Plans/Active/AppShell.md`
- Design principles: `docs/DesignPrinciples.md`
- Design system: `docs/DesignSystem.md`
- Spec previo (parcial): `docs/superpowers/specs/2026-05-11-universal-event-detail-migration-design.md`
- Memorias relevantes: `project_resource_detail_capability_driven`, `feedback_no_hardcoded_verticals`, `project_four_layer_model`, `feedback_create_flow_defaults`
