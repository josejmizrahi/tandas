# Migración a `UniversalResourceDetailView` para eventos

**Fecha:** 2026-05-11
**Estado:** Aprobado (one detail page)
**Decisor:** founder
**Contexto previo:** [Plans/Active/AtomProjection.md](../../../Plans/Active/AtomProjection.md), `Features/Resources/Detail/UniversalResourceDetailView.swift`

## Problema

Hoy coexisten dos páginas de detail para events:

1. `EventDetailView` (817 líneas) — la canonical, con cover full-bleed, parallax,
   sticky CTA, host actions, attendee roll, RSVP intent, check-in.
2. `UniversalResourceDetailView` — la polimórfica nueva, capability-driven,
   accesible solo como "Ver como recurso (Beta)" dentro del menú nav del
   EventDetailView.

Los comentarios del código documentan que la dualidad fue intencional hasta
Phase 2 (Slot), cuando se extraería un "polymorphic interaction context"
compartido. El founder decidió 2026-05-11 acelerar: matar EventDetailView
ahora y dejar que la página polimórfica nueva sea el único surface.

## Objetivo

Una sola página de detail polimórfica (`UniversalResourceDetailView`) que
renderiza events con paridad de features vs el surface actual. Sin
`EventDetailView` en producción.

## Approach: capability sections con SwiftUI environment injection

Las capability sections que necesitan estado event-specific (RSVP intent,
check-in, host actions) lo leen vía SwiftUI `@Environment` inyectando un
protocolo `EventInteractor` (conformado por `EventDetailCoordinator`). El
contrato `ResourceDetailContext` se queda genérico — no se contamina con
campos event-shaped. Cuando llegue Slot, su `SlotInteractor` hace lo mismo.

### Catálogo extendido

Nuevas capabilities a registrar en `modules` y a auto-seedear vía trigger
estilo mig 00096:

| Capability id | Sección | Gate adicional |
|---|---|---|
| `description` | `DescriptionSectionView` | metadata.description non-empty |
| `check_in` | `CheckInSectionView` | EventInteractor disponible |
| `host_actions` | `HostActionsSectionView` | EventInteractor + viewer.role == host |
| (existente) `rsvp` | `RSVPSectionView` extendida con intent CTA | intent visible solo si EventInteractor presente |

### Zonas Universal extendidas

- `DetailHeaderView`: aprende cover image opcional (gradient overlay + parallax)
  cuando `resource.metadata.cover_image_url` está set. Sin metadata cover:
  cae al iconBadge actual.
- `DetailSummaryView`: nuevos `SummaryFieldDescriptor` para events
  (countdown, capacity bar, location card con botón maps). Catálogo
  ya es declarativo (`SummaryFieldCatalog.v1`) — solo registrar
  descriptors.
- `UniversalResourceDetailView` gana:
  - `topNav` slot (close, share, edit, más) — buttons leen
    `ResourceDetailContext` callbacks (mayoría ya existen:
    `onPresentEditResource`; agregar `onClose`, `onShare`, `onOpenAsResource`).
  - `stickyFooter` slot opcional para CTA de bottom (`onStickyCTA`).

### EventInteractor protocol

```swift
@MainActor
protocol EventInteractor: AnyObject, Observable {
    var event: Event { get }
    var myRSVP: RSVP? { get }
    var viewerRole: GroupMemberRole { get }
    var rsvps: [RSVP] { get }
    var walletAvailable: Bool { get }
    // Mutations
    func setRSVP(_ status: RSVPStatus, plusOnes: Int, reason: String?) async
    func selfCheckIn(locationVerified: Bool) async
    func hostMarkCheckIn(memberId: UUID) async
    func sendHostReminders() async -> Bool
    func cancelEvent(reason: String?) async
    func closeEvent(autoGenerateEnabled: Bool) async
    func toggleAutoGenerate(_ enabled: Bool) async
    func generateWalletPass() async -> URL?
    // Host action presentation hooks (dueño del shell decide cómo abre)
    var onOpenScanner: () -> Void { get }
    var onEdit: () -> Void { get }
    var onIssueManualFine: () -> Void { get }
    var canIssueManualFine: Bool { get }
}

extension EnvironmentValues {
    @Entry var eventInteractor: (any EventInteractor)? = nil
}
```

`EventDetailCoordinator` se conforma a esto. Las nuevas capability sections
leen `@Environment(\.eventInteractor)` y degradan a read-only cuando es nil
(p.ej. previews o non-event resources con la misma capability si llegan).

### Sheets

Pasan a ser propiedad de `MainTabView` (ya es el owner del navigation stack
para events). EventInteractor expone callbacks que abren sheets. Esto evita
que las capability sections embeban sheets — siguen siendo body-only.

Sheets a mover:
- `ShareEventSheet`
- `MemberQRSheet`
- `CancelEventSheet`
- `CancelAttendanceSheet`
- `RemindAttendeesSheet`
- `CloseEventSheet`
- `AddManualFineSheet`
- `attendeeMemberRoute` (`MemberDetailView`)

Los que ya son polymorphic (`ResourceLedgerSheet`, `ResourceRulesSheet`) se
quedan donde están (compartidos con `ResourceDetailSheet`).

## Phases (orden de commits)

Cada phase compila + tests verdes antes de avanzar.

1. **`feat(modules): seed check_in/host_actions/description capabilities`**
   - Migration SQL: registra los 3 capability blocks nuevos en `modules`.
   - Extiende `modules.provided_capability_blocks` para el módulo base.
   - Trigger update (mig 00096 successor) que auto-habilita estas caps
     en events nuevos al crear el resource.
   - Backfill `resource_capabilities` para events existentes.
   - Codegen TS bindings.

2. **`feat(ui): cover image in DetailHeaderView`**
   - DetailHeaderView aprende prop opcional `coverImageURL`.
   - Helper en ResourceDetailContext: deriva URL de metadata.
   - Tests de header con/sin cover.

3. **`feat(ui): DescriptionSectionView capability section`**
   - Nuevo section, gated por cap `description`.
   - Registrado en CapabilitySectionCatalog.
   - Reads `resource.metadata.description`.

4. **`feat(ui): EventInteractor protocol + environment`**
   - Define protocolo + EnvironmentValues entry.
   - `EventDetailCoordinator` conforma.
   - Sin consumers todavía; solo plumbing.

5. **`feat(ui): extend RSVPSectionView with intent CTA`**
   - Lee `@Environment(\.eventInteractor)`. Si presente, render intent
     CTA arriba del tally (yes/no/maybe + plusOnes + Wallet + QR).
   - Reuse del componente actual `EventRSVPStateView` movido a
     `Features/Resources/Detail/Sections/Subviews/RSVPIntentControl.swift`.

6. **`feat(ui): CheckInSectionView`**
   - Movida desde `Features/Events/Subviews/CheckInSection.swift`.
   - Renombrada + envuelta en `CapabilitySection.definition`.
   - Gated por cap `check_in`. Reads EventInteractor.

7. **`feat(ui): HostActionsSectionView`**
   - Movida desde `Features/Events/Subviews/EventHostActionsSection.swift`.
   - Gated por cap `host_actions` AND viewerRole == host.
   - Callbacks van vía EventInteractor.

8. **`feat(ui): summary descriptors for event countdown/capacity/location`**
   - Registra descriptors en `SummaryFieldCatalog.v1` para events.
   - Helpers de countdown / capacity / location existen — solo wrap.

9. **`feat(ui): topNav + stickyFooter slots in UniversalResourceDetailView`**
   - topNav callbacks: `onClose`, `onShare`, `onOpenAsResource`,
     `onEdit` (todos en ResourceDetailContext).
   - stickyFooter: closure opcional pasada al view init.

10. **`refactor(events): MainTabView builds Universal for events`**
    - Reemplaza `EventDetailView(...)` con `UniversalResourceDetailView(...)`.
    - MainTabView pasa el coordinator vía `.environment(\.eventInteractor, ...)`.
    - MainTabView owns todas las sheets (move from EventDetailView).

11. **`chore(events): delete EventDetailView + dead subviews`**
    - Borra `EventDetailView.swift` (817L).
    - Borra `EventDetailBody.swift` (24L, unused after step 10).
    - Borra `Features/Events/Subviews/EventHostActionsSection.swift` (movido en step 7).
    - Borra `Features/Events/Subviews/CheckInSection.swift` (movido en step 6).
    - Borra `Features/Events/Subviews/EventRSVPStateView.swift` (movido en step 5).
    - Update Plans/Active y comments que referenciaban EventDetailView.
    - `EventDetailCoordinator` se queda (es el data driver, ahora conforming a EventInteractor).

12. **`test(events): smoke + previews`**
    - Previews de Universal con event row + mock EventInteractor.
    - Smoke test en sim iOS 26 (golden path: open event, RSVP, check-in, host actions, share, close).
    - Update tests existentes que abrían EventDetailView directamente.

## DoD por commit

- Compila Xcode 16+ sin warnings
- `xcodebuild test` pasa
- Codegen sin diff (lefthook lo enforces)
- Migrations aplicadas vía MCP con review SQL antes
- Smoke en simulador iOS 26 al cerrar phase 10 (golden path)

## Riesgos

- **Cover parallax**: el efecto actual de EventDetailView depende de
  `GeometryReader` outer-wrapped al ScrollView. UniversalResourceDetailView
  usa un layout más plano. Step 2 necesita verificar que el parallax
  funcione dentro del Universal scrollview o aceptar perder el parallax y
  quedarnos con cover estático.
- **Sticky CTA inside cover**: el `stickyBottomBar` actual se posiciona
  con un `ZStack` outer. UniversalResourceDetailView va a necesitar el
  mismo wrapping en step 9 — no es solo "agregar un VStack abajo".
- **Manual fine governance check**: `computeCanIssueManualFine` es async
  + dispara en `.task`. Step 7 lo conserva como `@State` en
  HostActionsSectionView, mismo patrón que el original.
- **Realtime subscriptions**: `coordinator.startRealtime()` / `.stopRealtime()`
  hoy se atan al lifecycle de EventDetailView. Step 10 mueve esos hooks
  al wrapper en MainTabView (o `.task` en Universal con coordinator env).

## Out of scope

- Re-skin del UniversalResourceDetailView (mantener look actual).
- Slot/Booking/Fund — siguen como UnknownResourceDetailBody hasta Phase 2.
- Cover image upload UI (sigue con CreateEvent/EditEvent).
- ResourceDetailSheet (sheet polymorphic existente que no se abre desde EventDetailView): se queda intacto, sigue siendo la entry para resources non-event.
