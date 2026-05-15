# UniversalResourceDetailView v2 — Apple Invites-inspired redesign

**Fecha:** 2026-05-14
**Estado:** Brainstorming → spec
**Decisor:** founder
**Reemplaza:** la implementación actual de `Features/Resources/Detail/` (post Pass 1-3)
**Predecesores relevantes:**
- Spec previo: `docs/superpowers/specs/2026-05-11-universal-event-detail-migration-design.md` (estableció EventInteractor + capability sections)
- AppShell.md `## ResourceDetail` (define la pieza polimórfica clave)
- DesignPrinciples.md §1 (cover IS the card), §3 (date language), §5 (tokens), §7 (motion)
- Memoria `project_resource_detail_capability_driven`

## Problema

La implementación actual de `UniversalResourceDetailView` (5718 líneas / 35 archivos) es estructuralmente capability-driven y técnicamente sólida, pero la UX está desordenada y mezcla 4 superficies de acción simultáneas:

1. **`DetailTopNavView`** flotante sobre el content (close / share / ⋯)
2. **`DetailPrimaryActions`** zone in-content (CTA principal repetido)
3. **`DetailActionsBar`** zone in-content (chips secundarias: Gasto / Aportación / Payout)
4. **`DetailStickyFooterView`** sticky CTA con `safeAreaInset`

El usuario no sabe dónde mirar. Adicionalmente:

- **Doble identity zone**: `EventHeroTitleBlock` (event-specific, 167L) coexiste con `DetailHeaderView` (universal, 86L) — el "universal" no es tan universal
- **Floating nav pelea con iOS 26 Liquid Glass**: `DetailTopNavView` reimplementa lo que `NavigationStack` + Liquid Glass dan nativamente
- **`EventDetailHost` (438L)** mezcla bootstrap + 10 sheets + presenter + governance check + coordinator construction
- **Orden por capability, no por pregunta del usuario** — RSVP/CheckIn/HostActions/Money/Rules/Activity son agnósticos al "¿qué necesita ver primero el usuario?"
- **Carga secuencial**: cover + capabilities + attention + governance — primer render aparece sin secciones (flash)
- **Dead route**: "Activar capability" en el ⋯ menu para events (commenteado en EventDetailHost.swift línea 218)

## Objetivo

Detail screen inspirado en **Apple Invites**: cover hero full-bleed con título/fecha/host overlay en blanco, panel rounded-corner que sube por debajo, **un solo CTA** sticky, **una sola superficie secundaria** (`⋯` menu en nav bar nativa), secciones organizadas por **pregunta del usuario** (no por capability). Sigue siendo capability-driven en arquitectura — solo el orden y la presentación cambian.

Targets:
- Archivos: 35 → ~25 (-30%)
- Líneas: ~5700 → ~3500 (-38%)
- Action surfaces: 4 → 2 (sticky CTA + ⋯ menu)
- Floating chrome: eliminada (NavigationStack nativa)
- Sections: ordenadas por user question
- Cover hero polimórfico: imagen real OR procedural mesh por `Group.category.ramp`

## Approach

**Composición canónica** (post-redesign):

```swift
NavigationStack {
    ScrollView {
        VStack(spacing: 0) {
            ResourceCoverHero(...)            // full-bleed, parallax, white overlay
            ResourceDetailPanel(...) {        // rounded-corner panel slides up
                NeedsAttentionCard(...)       // compact alert if inbox actions
                ResourceQuickFactsView(...)   // horizontal pills (capability-driven)
                DescriptionSection(...)       // metadata.description if non-empty
                AttendeesSection(...)         // capability rsvp
                MoneySection(...)             // capability ledger
                RulesSection(...)             // capability rules + scope hierarchy
                ActivitySection(...)          // last 5 + "Ver todo" linkout
                SettingsSection(...)          // capabilities toggle, archive (collapsed)
            }
        }
    }
    .safeAreaInset(edge: .bottom) {
        ResourcePrimaryCTA(...)               // single button, glassEffect
    }
    .toolbar {
        ToolbarItem(placement: .topBarLeading)  { closeButton }
        ToolbarItem(placement: .topBarTrailing) { shareButton; moreMenu }
    }
}
```

### Key design moves

#### 1. Cover hero — replaces 3 zone files

`ResourceCoverHero` (~120L) consolidates `DetailCoverView` (98L) + `EventHeroTitleBlock` (167L) + the cover-time work in `DetailHeaderView` (86L). Behavior:

- **Full-bleed image** when `metadata.cover_image_url` is set; aspect ratio 16:11
- **Procedural mesh fallback** when no image: SwiftUI `MeshGradient` (iOS 18+) using `Group.category.ramp.bgGradient.colors` 4-corner palette. Same component, different fill source
- **Vignette gradient** at bottom (linear, opacity 0 → 0.6 over bottom 40% of cover)
- **Bottom-leading overlay** (white text, ignores cover dark/light):
  - Date pill (capability `scheduling`): "JUE 12 MAR · 9:00 PM" (`ruulShortDateWithWeekday` + `ruulShortTime` from Pass 3 helpers)
  - Title (`RuulTypography.displayLarge`, white)
  - Subtitle (`RuulTypography.callout`, white .opacity(0.85)) — host name + capacity for events; balance + goal for funds; etc. Driven by `CapabilityResolver.coverSubtitle(...)`
- **Top-trailing status pill** (capability-aware): "OPEN" / "FULL" / "PASSED" / "DRAFT" / etc. Single source per `ResourceTypeChrome.statusPillText(...)` extension
- **Parallax**: `GeometryReader`-driven scale + offset; cover stretches when scroll-pull-down, compresses when scroll-up

#### 2. Quick facts — new polymorphic primitive

`ResourceQuickFactsView` (~80L) — horizontal `ScrollView(.horizontal)` of small icon+label pills, one pill per fact. Facts are derived from capabilities:

```swift
public struct QuickFact: Identifiable, Hashable {
    public let id: String
    public let symbol: String     // SF Symbol
    public let label: String      // "9:00 PM"
    public let onTap: (() -> Void)?  // optional — most facts inert; location taps maps
}

extension CapabilityResolver {
    func quickFacts(for resource: ResourceRow, in group: Group) -> [QuickFact] {
        // composes facts from active capabilities — pure logic, testable
    }
}
```

Examples:
- Event with `scheduling` + `location` + `rsvp`: `📅 JUE 12 MAR  ·  📍 Casa de JJ  ·  👥 8/12`
- Fund with `ledger`: `💰 $4,500 / $10,000  ·  📊 45%  ·  🔄 Hace 3 días`
- Asset with `availability` + `location`: `🔑 Disponible  ·  📅 Última: Hace 2 sem  ·  📍 Garage`

Bonus: `ResourceQuickFactsView` is small enough to embed elsewhere (e.g. detail of a resource pulled from another tab).

#### 3. Single primary CTA — pure logic resolver

`ResourcePrimaryActionResolver.swift` (~60L, in `RuulCore/Capabilities/`) — pure function:

```swift
public struct PrimaryAction: Sendable, Hashable {
    public enum Style: Sendable, Hashable { case standard, destructive, prominent }
    public let label: String
    public let symbol: String?
    public let style: Style
    public let kind: Kind  // enum payload — what to dispatch on tap

    public enum Kind: Sendable, Hashable {
        case rsvpConfirm
        case rsvpCancel
        case viewHostActions
        case openContribute  // fund
        case openBooking     // asset
        case viewClosed      // history-only
        case none            // no CTA — sticky footer hidden
    }
}

public extension CapabilityResolver {
    func primaryAction(
        for resource: ResourceRow,
        viewer role: MemberRole,
        rsvpStatus: RSVPStatus?,
        eventStatus: EventStatus?
    ) -> PrimaryAction { ... }
}
```

Test coverage: ~12 `(resource_type × role × capability_state)` combinations as Swift Testing cases. The view dispatches based on `kind` to the existing presenter callbacks (no new sheets needed — they already exist in `EventDetailPresenter`).

#### 4. Secondary actions — `⋯` menu only

All actions that today live in `DetailTopNavView` ⋯ menu + `DetailActionsBar` chips + `DetailPrimaryActions` extras get consolidated into a single `Menu` in the nav bar trailing. Items vary by `(resource_type, role, capability_state)` per a small `secondaryActions(...)` resolver function (sibling to `primaryAction`).

Example menu for event + viewer is host:
```
Editar detalles
Recordar a invitados
Cerrar evento
Cancelar evento
─────────
Agregar al calendario
Compartir
Generar pase de Wallet
─────────
Acuerdos del recurso
Multa manual
─────────
Archivar
```

Items hidden when not applicable (e.g. "Multa manual" hidden when governance denies). Dead routes (e.g. "Activar capability" for events) just don't appear.

#### 5. Section order = user question order

Re-orders the existing capability sections without changing their internal implementation:

| Order | Section | Source view | User question |
|---|---|---|---|
| 1 | NeedsAttention | `DetailAttentionView` (kept, repurposed as compact card) | "¿Necesito hacer algo ya?" |
| 2 | Quick Facts | `ResourceQuickFactsView` (new) | "¿Qué es esto? ¿Cuándo? ¿Dónde?" |
| 3 | Description | `DescriptionSectionView` (existing) | "¿Qué pasa aquí?" |
| 4 | Quien viene | `RSVPSectionView` (existing) | "¿Quién está involucrado?" |
| 5 | Dinero | `MoneySectionView` (existing) | "¿Hay plata?" |
| 6 | Acuerdos | `RulesSectionView` (existing) | "¿Qué reglas aplican?" |
| 7 | Actividad | `ActivitySectionView` (existing) | "¿Qué pasó?" |
| 8 | Ajustes | New `SettingsSectionView` (collapsed) | "Configuración" |

Sections rendered conditional on capabilities (zero render when capability not enabled). The order is **fixed in the layout** — capability catalog no longer drives ordering, only inclusion. Why fixed: predictable IA matters more than catalog flexibility for a polymorphic detail screen. If a future capability needs a new section, it gets a fixed position in this list.

#### 6. EventDetailHost split

`EventDetailHost.swift` (438L) trocea en 3:

- `EventDetailBootstrap.swift` (~80L) — coordinator construction (`bootIfNeeded`), capability load (`loadCapabilities`), governance check (`computeCanIssueManualFine`). Pure async setup.
- `EventDetailSheets.swift` (~200L) — ViewModifier owning the 10 `.ruulSheet(...)` modifiers + the `prepareCoordinator(for:)` lazy builder. Apply via `.eventDetailSheets(host: self)`.
- `EventDetailHost.swift` (~120L) — kept as the entry shell that ties bootstrap + sheets + UniversalResourceDetailView together.

`EventDetailPresenter.swift` (already exists, ~80L) stays.

#### 7. iOS 26 native chrome

- **`NavigationStack`** wraps the entire detail. Native nav bar with Liquid Glass.
- **No floating overlays** over content. The nav bar IS the chrome.
- **`tabBarMinimizeBehavior(.onScrollDown)`** already inherited from RootShell parent.
- **`safeAreaInset(edge: .bottom)`** for the sticky CTA — survives keyboard, respects safe area, scrollable content tucks under it (which gets `.glassEffect()` for the iOS 26 frosted look).
- **`scrollTransition(.animated.threshold(.visible(0.2)))`** on each section card — already added in Pass 3 Task 7 for similar surfaces.
- **`symbolEffect(.bounce, value:)`** on the badge counter inside the NeedsAttention card.

## File structure (post-redesign)

```
ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/
├── UniversalResourceDetailView.swift          (~180L — orchestrator)
├── ResourceDetailContext.swift                 (existing, slight adjustments)
├── ResourceDetailPanel.swift                   (~60L — NEW: rounded panel wrapper)
├── ResourceCoverHero.swift                     (~120L — NEW: cover + parallax + overlay)
├── ResourceQuickFactsView.swift                (~80L — NEW: horizontal pills)
├── ResourcePrimaryCTA.swift                    (~80L — NEW: sticky footer button)
├── EventInteractor.swift                       (existing)
├── EventDetailPresenter.swift                  (existing)
├── EnableCapabilitySheet.swift                 (existing — kept for non-event types)
├── CapabilitySection.swift                     (existing — kept for catalog protocol)
├── Sections/
│   ├── DescriptionSectionView.swift            (existing)
│   ├── RSVPSectionView.swift                   (existing)
│   ├── CheckInSectionView.swift                (existing)
│   ├── MoneySectionView.swift                  (existing)
│   ├── RulesSectionView.swift                  (existing)
│   ├── ActivitySectionView.swift               (existing)
│   ├── HostActionsSectionView.swift            (existing — repurpose as ⋯ menu items source)
│   ├── ScheduleSectionView.swift               (existing — fold into Quick Facts)
│   ├── LocationSectionView.swift               (existing — fold into Quick Facts)
│   ├── CapacityProgressSectionView.swift       (existing — fold into Quick Facts)
│   ├── RotationSectionView.swift               (existing)
│   ├── SettlementSheet.swift                   (existing — sheet, not section)
│   └── SettingsSectionView.swift               (~80L — NEW: capabilities toggle + archive)
├── Adapters/
│   ├── EventDetailHost.swift                   (~120L — slimmed)
│   ├── EventDetailBootstrap.swift              (~80L — NEW: extracted from Host)
│   ├── EventDetailSheets.swift                 (~200L — NEW: ViewModifier from Host)
│   ├── EventDetailCoordinator.swift            (existing, untouched)
│   └── EditEventView.swift                     (existing)
├── Layouts/
│   └── EventInvitesContent.swift               (review usage; likely DELETE)
├── PreviewSupport/
│   └── MockEventInteractor.swift               (existing — extend for new sections)
├── Sheets/
│   └── AttendeesListSheet.swift                (existing)
└── Subviews/
    └── RSVPAvatarStrip.swift                   (existing)

# DELETED (consolidated into ResourceCoverHero or replaced by NavigationStack):
- Zones/DetailTopNavView.swift                  (130L) — replaced by NavigationStack toolbar
- Zones/DetailHeaderView.swift                  (86L)  — folded into ResourceCoverHero
- Zones/EventHeroTitleBlock.swift               (167L) — folded into ResourceCoverHero
- Zones/DetailPrimaryActions.swift              (82L)  — replaced by ResourcePrimaryCTA
- Zones/DetailActionsBar.swift                  (112L) — actions move to ⋯ menu
- Zones/DetailCoverView.swift                   (98L)  — folded into ResourceCoverHero

# KEPT (relocated, slight changes):
- Zones/DetailStickyFooterView.swift            (66L)  — RENAMED to ResourcePrimaryCTA.swift, simplified to single button
- Zones/DetailAttentionView.swift               (66L)  — KEPT, restyled in-place as a compact card for the NeedsAttention slot (renders only when context.attentionActions has items)

# Total deletions: -675L from zone deletions
```

**Net delta** (estimated):
- Files: 35 → ~25 (-10)
- Lines: ~5700 → ~3500 (-2200)
- Action surfaces: 4 → 2

## Capability Resolver extensions

New methods on `CapabilityResolver` (`RuulCore/Capabilities/`):

```swift
public extension CapabilityResolver {
    /// Quick facts (horizontal pills) for the resource header zone.
    /// Pure logic; reads capabilities + resource metadata.
    func quickFacts(
        for resource: ResourceRow,
        in group: Group
    ) -> [QuickFact]

    /// The single CTA shown in the sticky footer.
    /// Returns .none when no CTA applies (closed events, etc.) — caller
    /// hides the footer.
    func primaryAction(
        for resource: ResourceRow,
        viewer: MemberRole,
        rsvpStatus: RSVPStatus?,
        eventStatus: EventStatus?
    ) -> PrimaryAction

    /// Items for the nav bar `⋯` menu, in display order. Items the
    /// viewer can't perform (e.g. issue manual fine without governance)
    /// are filtered out before return.
    func secondaryActions(
        for resource: ResourceRow,
        viewer: MemberRole,
        viewerCanIssueManualFine: Bool
    ) -> [SecondaryAction]

    /// Subtitle for the cover hero overlay, derived from capabilities.
    /// Examples:
    ///   event: "Hosted by Daniel · 8 going"
    ///   fund:  "$4,500 of $10,000 raised"
    ///   asset: "Last booked by Lynda · 2 weeks ago"
    func coverSubtitle(
        for resource: ResourceRow,
        in group: Group,
        memberDirectory: [UUID: MemberWithProfile]
    ) -> String?
}
```

Each is **pure logic** — fully unit-testable without SwiftUI. New tests:
- `CapabilityResolver+PrimaryActionTests` — ~12 cases per `(resource_type × role × state)`
- `CapabilityResolver+QuickFactsTests` — per resource type happy path
- `CapabilityResolver+SecondaryActionsTests` — governance gating

## Procedural mesh fallback

`ResourceCoverHero` when no `cover_image_url`:

```swift
@ViewBuilder
private var meshFallback: some View {
    let palette = group.category.ramp  // existing GroupColorRamp
    MeshGradient(
        width: 2, height: 2,
        points: [.init(0, 0), .init(1, 0), .init(0, 1), .init(1, 1)],
        colors: [
            palette.bgGradient.colors[0],
            palette.accent,
            palette.bgGradient.colors[1],
            palette.accent.opacity(0.8)
        ]
    )
    .ignoresSafeArea(edges: .top)
}
```

iOS 18+ `MeshGradient` is available throughout iOS 26. Generates a smooth multi-color blend per group's category — visually distinct without requiring users to upload images. Apple Invites does this for non-photo invites.

## Behavior preserved

- Capability-driven section inclusion: every section gates on `enabledCapabilities.contains(...)`. Catalog stays.
- All existing sheets (Share, QR, Cancel, Remind, Close, Manual fine, Ledger, Rules, Attendees, Member detail) survive — moved into `EventDetailSheets` ViewModifier verbatim.
- `EventInteractor` protocol injection via `@Environment` stays.
- `EventDetailCoordinator` untouched (just used in fewer places).
- All existing capability sections (Description, RSVP, Money, Rules, Activity, etc.) keep their internal implementations — only the ordering and the wrapper change.

## Behavior changed (deliberate)

1. **Cover hero is the new identity zone**. Title/date/host appear in the cover overlay, not in a separate `EventHeroTitleBlock` below.
2. **CTA is single and persistent**. No more in-content `PrimaryActions` zone. The sticky footer is the only place to RSVP / contribute / book.
3. **Secondary chips are gone**. Money chips ("Gasto / Aportación / Payout") move to the ⋯ menu. They were a visual-noise source ranked low in usability tests.
4. **Nav bar is native, not floating**. Close button is `topBarLeading` standard `xmark`. No more circular glass close button overlaying the cover.
5. **Settings section is a NEW collapsed accordion at scroll bottom**. Today there's no in-detail settings; capability toggles live in the ⋯ menu only. Pass-3 polish: accessible danger zone in plain sight.
6. **Activity section is now last 5 + linkout**. Today it's a full embedded timeline — kept brief here so users go to the Activity tab for the full story. Linkout opens the Activity tab without resource-specific filtering for Pass 1; per-resource filter capability is queued for Pass 3.5 (requires `SystemEventRepository.query(...)` to accept a `referenceId` param, which it doesn't yet).

## Out of scope

- New capability types (slot, fund, asset) — Phase 2 introduces these; this redesign just preserves the polymorphic shape so they slot in.
- Major change to `EventDetailCoordinator` internals — kept untouched.
- Migration of `Plans/Active/AppShell.md` ResourceDetail spec — this redesign IS the realization of that spec; no doc change needed.
- Removal of `EventInvitesContent.swift` (Layouts/) — review whether still used; if dead, delete in cleanup but not in scope of design.
- Localization audit (`labelKey` raw strings still appear in some places per Pass 2 close note) — separate Pass 3.5.

## Risks

| Risk | Mitigation |
|---|---|
| Visual change is significant; founder demo expectations | Land behind feature flag `useNewDetail` (mirroring Pass 1's `useNewShell` pattern); flip after manual smoke |
| `MeshGradient` perf on older devices | Target is iOS 26+ (Apple Silicon iPhones); validated; cache-friendly |
| `primaryAction(...)` resolver drift from EventInteractor expectations | Unit tests cover the matrix; integration test wires resolver → presenter callback chain |
| `EventDetailHost` split breaks @State preservation across the boundary | Use `@State` migration carefully; mock-driven `#Preview` per file validates shape |
| Settings section accordion is a NEW UX pattern not in DS | Use SwiftUI's built-in `DisclosureGroup` styled with `RuulSpacing` + `RuulTypography` tokens; no new primitive needed for Pass 1 |
| 10 sheets in `EventDetailSheets` ViewModifier is a lot for one file | Acceptable at 200L given each branch is small + similar; if it grows past 250L, split by capability domain (Money sheets / RSVP sheets / Host sheets) |
| Loss of `DetailActionsBar` chips removes a quick-money path | Mitigated by ⋯ menu placement + the existing `MoneySectionView` Add-Entry CTA |

## Métricas de éxito

| Indicator | Before | Target |
|---|---|---|
| Files in `Features/Resources/Detail/` | 35 | ≤ 25 |
| Lines of code in `Detail/` | ~5,700 | ≤ 3,800 |
| `EventDetailHost.swift` | 438L | ≤ 130L |
| Action surfaces visible to user | 4 | 2 (sticky CTA + ⋯ menu) |
| Floating chrome over content | yes (DetailTopNavView) | no |
| Sections ordered by user question | no | yes |
| Cover hero polymorphic (image OR mesh) | no (image only) | yes |
| Primary CTA logic unit-tested | no | yes (~12 cases) |
| Tests | 182 / 37 | 200+ / 40+ (new resolver tests) |

## Próximos pasos

1. **User review of this spec** — adjust if any of the 4 defaults (Section F of brainstorming) or the section order need to change
2. **Invoke `writing-plans`** to create the executable Pass-1-style implementation plan
3. Execution as a separate worktree (`detail-redesign/v2`) with `useNewDetail` feature flag for gradual cutover
4. Manual smoke + device test before flipping the flag
5. PR + push to main

## Referencias

- Spec previo: `docs/superpowers/specs/2026-05-11-universal-event-detail-migration-design.md`
- Frontend remodel passes 1-3 specs/plans: `docs/superpowers/specs/2026-05-14-frontend-remodel-design.md`, `plans/2026-05-14-frontend-remodel-pass{1,2,3}.md`
- Constitution: `Plans/Active/Constitution.md`
- AppShell canónico: `Plans/Active/AppShell.md`
- Vision (post-Constitution canon): `Plans/Active/Vision.md`
- Design principles: `docs/DesignPrinciples.md`
- Memorias: `project_resource_detail_capability_driven`, `feedback_no_hardcoded_verticals`, `feedback_create_flow_defaults`, `feedback_rules_ux_human`
