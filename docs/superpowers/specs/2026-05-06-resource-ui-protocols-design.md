# Resource UI Protocols (Sub-fase A) — design

**Status**: brainstormed, ready for implementation plan
**Author**: Claude (session 2026-05-06, post-VoidFineSheet)
**Roadmap item**: Plans/Phase0.5-UIResourceGeneralization.md §3 Sub-fase A
**Scope**: Sub-fase A only — primitivas UI puras (`ResourceProtocol` + `EventResource` + `ResourceAction` + `ResourceActionsProvider` skeleton + tests). Refactors de HomeView/EventDetailView/EventHostActionsSection son Sub-fases B/C/D.

## Goal

Introducir las primitivas Swift que habilitan dispatch genérico de resources en UI sin tocar nada existente. Después de Sub-fase A:

- `ResourceProtocol` está definida en `Platform/Resources/` (UI-layer, distinta de la data-layer `Platform/Models/Resource.swift`).
- `EventResource` wrappea `Event` y conforma a `ResourceProtocol`. Es el único concrete resource shippeado en V1.
- `ResourceAction` (data + closure) y `ResourceActionsProvider` (associatedtype protocol) existen pero sin implementación concreta — `EventActionsProvider` se difiere a Sub-fase D.
- Tests verifican que los wrappers preservan identidad y que las primitivas componen correctamente.
- Cero cambios en views existentes. HomeView, EventDetailView, EventCard, EventHostActionsSection siguen idénticos.

## Out of scope

- **`EventActionsProvider`** (concrete provider para events) — Sub-fase D. Sin EventResource y ResourceAction shipped no hay nada contra qué probarlo.
- **`ResourceCard`, `ResourceDetailView`, `ResourceActionsSection`** (containers/views genéricos) — Sub-fases B/C/D respectivamente.
- **Refactors de HomeCoordinator (`nextEvent: Event?` → `nextResource: any ResourceProtocol?`)** — Sub-fase B.
- **Mapping `Event → EventResource` en el seam UI/data** — se introduce cuando lo necesite el primer consumer (Sub-fase B).
- **Hashable conformance en `ResourceProtocol`** — diferido. Si NavigationStack(path:) lo necesita, agregar entonces.
- **Codable conformance en `EventResource`** — UI-layer no persiste.
- **Type-erased wrapper para `ResourceActionsProvider`** — V1 no necesita arrays heterogéneos de providers.
- **Re-check de governance al ejecutar `onTap`** — V1 trata `governanceAction` como metadata only.

## Backend assumptions verified

Sub-fase A es **Swift-only**. Cero migrations, cero RPC changes, cero edge function changes. Backend intacto.

**`Platform/Models/Resource.swift` (data-layer protocol)**: confirmado en línea 13:
```swift
public protocol Resource: Identifiable, Sendable, Codable {
    var resourceType: ResourceType { get }
    // ... id, groupId, status, createdAt, updatedAt
}
```

Naming alignment: data-layer y UI-layer ambos demandan `resourceType: ResourceType`. **Sin collision** — un solo getter en `EventResource` satisface a ambos protocols cuando conforme a los dos.

**`Platform/Models/ResourceType.swift`**: enum ya define los 6 cases (event, slot, fund, position, asset, contribution) + unknown(String). Sub-fase A consume `.event` únicamente.

**`Platform/Models/GovernanceAction.swift`**: enum existente, codegen-managed. `ResourceAction.governanceAction` lo referencia sin ampliarlo. Sub-fase D agrega `case cancelEvent`/`closeEvent`/`remindAttendees` si no existen ya.

**`Models/Member.swift`, `Models/Group.swift`**: ya existen, son los inputs de `ResourceActionsProvider.actions(...)`. Sin cambios.

## §1 — Architecture

```
ios/Tandas/
  Platform/Resources/                                ← directorio nuevo
    ResourceProtocol.swift                           ← UI-layer protocol (3 miembros)
    EventResource.swift                              ← struct wrapper sobre Event
    ResourceAction.swift                             ← struct (UI action data + closure)
    ResourceActionsProvider.swift                    ← protocol skeleton (associatedtype)

ios/TandasTests/
  Platform/Resources/
    EventResourceTests.swift                         ← 4 tests
    ResourceActionTests.swift                        ← 3 tests
```

**Decisión clave 1 — separación UI-layer / data-layer**: `ResourceProtocol` vive en `Platform/Resources/` (UI). El existing `Platform/Models/Resource.swift` (data) queda intacto. **V1 solo hace conformar `EventResource` a `ResourceProtocol` (UI)**. Conformar a la data-layer `Resource` queda como follow-up — requiere `updatedAt` en `Event` (no existe hoy) y Codable, ninguno necesario para Sub-fase A. Esto evita contaminar el data layer con UI concerns y permite que ambas capas evolucionen independientemente.

**Decisión clave 2 — `EventActionsProvider` movido a Sub-fase D** (delta vs Plans/Phase0.5 §3 original): Sub-fase A queda como "primitivas UI puras"; Sub-fase D agrega "providers que producen acciones contra resources". Linealmente dependiente, separación correcta — sin EventResource y ResourceAction shipped no hay contra qué probar el provider.

**Decisión clave 3 — minimal protocol surface (3 miembros)**: `id, groupId, resourceType`. Lo que es type-specific (title, status, dates) lo proyecta el body concreto vía cast. Liskov-safe para V2+ resource types.

## §2 — Components

### 1. `ResourceProtocol` — `Platform/Resources/ResourceProtocol.swift`

```swift
import Foundation

/// UI-layer protocol — habilita dispatch genérico de resources en views,
/// containers y providers. Distinta de `Platform/Models/Resource.swift`
/// (data-layer protocol con Codable + status + timestamps). Mantener
/// minimal: si tu vista necesita un campo type-specific, accedé al
/// concrete type via cast en el branch correspondiente del switch.
public protocol ResourceProtocol: Identifiable, Sendable {
    var id: UUID { get }
    var groupId: UUID { get }
    var resourceType: ResourceType { get }
}
```

**Justificación de cada miembro**:
- `id: UUID` — Identifiable conformance + navigation key.
- `groupId: UUID` — todo resource es group-scoped por contrato del platform; cross-group views badgeán por grupo.
- `resourceType: ResourceType` — único campo necesario para `switch` en containers genéricos. Nombre alineado con data-layer `Resource` para que `EventResource` pueda conformar a ambos sin colisión.

**Lo que NO está y por qué**:
- ~~`title`~~ — Slot tiene número, Fund tiene nombre, Position tiene rol. Liskov tension. Body concreto proyecta.
- ~~`status`~~ — cada type su state machine.
- ~~`createdAt/updatedAt`~~ — irrelevantes para dispatch UI.
- ~~`Hashable`~~ — diferido. `any Hashable` es awkward en Swift 6. Si NavigationStack(path:) lo necesita, agregar entonces.
- ~~`Codable`~~ — UI no persiste. Data-layer `Resource` mantiene Codable; UI no lo hereda.

### 2. `EventResource` — `Platform/Resources/EventResource.swift`

```swift
import Foundation

/// Wrapper de `Event` que conforma a `ResourceProtocol` (UI dispatch).
/// V1: el único concrete resource shippeado. Cuando llegue Slot/Fund,
/// vivirán como hermanos en este directorio.
///
/// Por qué wrapper y no extension: `Event` no debería conocer la capa
/// de UI. El wrapper es la traducción explícita — si mañana cambia el
/// shape de `ResourceProtocol`, solo este archivo se actualiza.
///
/// Invariante: `EventResource` es el único conformer de `ResourceProtocol`
/// con `resourceType == .event` en V1. Bodies concretos pueden hacer
/// `(resource as! EventResource)` con seguridad dentro del case `.event`.
public struct EventResource: ResourceProtocol {
    public let event: Event

    public init(_ event: Event) { self.event = event }

    public var id: UUID { event.id }
    public var groupId: UUID { event.groupId }
    public var resourceType: ResourceType { .event }
}
```

**Decisión**: expone `event: Event` público. Bodies concretos (EventDetailBody, EventCard) van a hacer `let event = (resource as! EventResource).event` en su branch del switch — patrón aceptado de "concrete cast en bodies" del principio P5 del plan Fase 0.5. Alternativa (proyectar fields uno a uno) duplica la API de Event sin valor.

### 3. `ResourceAction` — `Platform/Resources/ResourceAction.swift`

```swift
import Foundation

/// Acción que un host puede ejecutar contra un resource. Producida por
/// un `ResourceActionsProvider`, consumida por `ResourceActionsSection`
/// (Sub-fase D). Diseñada como data + closure: el provider arma la lista,
/// la view la renderiza.
///
/// **Retain cycle warning**: `onTap` captura coordinator/services
/// lexicalmente. Cuando el provider construye la action, el closure
/// debe ser `[weak coordinator] in await coordinator?.foo()` — el
/// coordinator es @Observable (reference type) y guardarlo strong
/// dentro del closure crea ciclo. Patrón obligado en Sub-fase D.
///
/// **`governanceAction` role en V1**: metadata only. El provider ya
/// filtró las actions disponibles según governance antes de emitirlas;
/// este field documenta a qué permission key corresponde la action
/// (útil para analytics, logs y futuro re-check). V1 NO re-chequea
/// en `onTap`. Sub-fase D puede expandir a defense-in-depth con UI
/// fallback ("La gobernanza cambió, refrescá") si decide.
public struct ResourceAction: Identifiable, Sendable {
    public let id: String
    public let icon: String              // SF Symbol name
    public let title: String
    public let subtitle: String?
    public let isDestructive: Bool
    public let governanceAction: GovernanceAction
    public let onTap: @Sendable () async -> Void

    public init(
        id: String,
        icon: String,
        title: String,
        subtitle: String? = nil,
        isDestructive: Bool = false,
        governanceAction: GovernanceAction,
        onTap: @escaping @Sendable () async -> Void
    ) {
        self.id = id
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.isDestructive = isDestructive
        self.governanceAction = governanceAction
        self.onTap = onTap
    }
}
```

**Decisiones**:
- `id: String` (no UUID) — ids son humanos: `"cancel-event"`, `"close-event"`. Permite estabilidad cross-instance y diff en SwiftUI por id.
- `governanceAction: GovernanceAction` — la action conoce su permission key. V1 metadata-only.
- `onTap: @Sendable () async -> Void` — closure async. Captura coordinator/services con `[weak]`. Errores se manejan adentro.
- No `Equatable/Hashable` — closures lo bloquean. Si SwiftUI necesita diff, comparar por `id` con un wrapper `IdentifiedAction` ad-hoc en Sub-fase D.

### 4. `ResourceActionsProvider` — `Platform/Resources/ResourceActionsProvider.swift`

```swift
import Foundation

/// Estrategia para producir acciones contra un resource. Cada concrete
/// resource type tiene su provider (V1: `EventActionsProvider`, deferido
/// a Sub-fase D). El provider conoce las reglas de governance + el
/// estado del resource y decide qué acciones están disponibles.
///
/// **Associatedtype no existential**: `R: ResourceProtocol` permite que
/// el provider concreto reciba el type ya tipado, sin `as!` interno.
/// Trade-off: consumers no pueden tener `[any ResourceActionsProvider]`.
/// V1 no lo necesita — cada resource type tiene su provider concreto
/// inyectado donde corresponde, accedido por switch en `resource.resourceType`.
public protocol ResourceActionsProvider: Sendable {
    associatedtype R: ResourceProtocol

    func actions(
        for resource: R,
        member: Member,
        in group: Group
    ) async -> [ResourceAction]
}
```

**Decisiones**:
- `associatedtype R` (no `any ResourceProtocol`) — type-safe adentro del provider, evita `as!` interno.
- `async` — la provider va a tocar governance y posiblemente repos. Empezar async desde el día 1.
- `Member, Group` inyectados — coherente con cómo VoidFineSheet hace governance check con el `Member` resuelto upstream.

## §3 — Data flow

Sub-fase A es foundational: las primitivas no ejecutan nada en runtime, sólo habilitan que sub-fases posteriores las consuman. Tres flujos relevantes (todos forward-looking, **no implementados en Sub-fase A**):

**Construcción de `EventResource`** (Sub-fase B activa esto):

```
HomeCoordinator.refresh
  └─ eventRepo.upcomingEvents(...)
      └─ [Event] → mapped to [EventResource(event)] at the boundary
                    where view consumes (ResourceCard, ResourceDetailView)
```

El mapping `Event → EventResource` ocurre en el seam UI/data, no en el coordinator. El coordinator puede seguir hablando `Event` internamente; sólo el binding al view lo wrappea. Minimiza el blast-radius de Sub-fase A.

**Dispatch genérico en views** (Sub-fase B/C activan esto):

```
ResourceCard(resource: any ResourceProtocol)
  └─ switch resource.resourceType {
       case .event:
         let event = (resource as! EventResource).event
         EventCardBody(event: event)
       case .slot, .fund, .position, .asset, .contribution:
         ResourceUnknownBody(resource: resource)
       case .unknown:
         ResourceUnknownBody(resource: resource)
     }
```

Cada branch hace `as!` al concrete type. Es seguro porque el invariant es: `resource.resourceType == .event ⇒ resource is EventResource`. EventResource es el único conformer de `.event` en V1.

**Acciones via provider** (Sub-fase D activa esto):

```
EventDetailBody [host opens detail]
  └─ Task { actions = await EventActionsProvider().actions(for: eventResource, member, in: group) }
      └─ ResourceActionsSection(actions: actions)
          └─ ForEach(actions) { Button(...) { Task { await action.onTap() } } }
```

El provider corre async una vez (al abrir la view), produce `[ResourceAction]`, la section los renderiza. Re-render manual via refresh — sin observación reactiva contra governance changes en V1. **Symmetry con EditRulesView Q5.1** (timing on-view-appear, no observación). RLS server-side bloquea si la governance cambió mid-session.

## §4 — Riesgos y edge cases

| # | Riesgo | Severidad | Mitigación |
|---|---|---|---|
| 1 | **Naming collision data/UI Resource** — verificado: ambos usan `resourceType` en línea 13 de `Platform/Models/Resource.swift`. Si en futuro la data-layer renombra, EventResource rompe en ambos lados. | Baja | Mantener invariante: el getter de `resourceType` es **uno solo** en `EventResource`. Si data-layer cambia naming, fix-up es local a este archivo + tests. |
| 2 | **Retain cycle en `onTap` closure** — `EventActionsProvider` que captura `EventCoordinator` (Observable, reference type) crea ciclo si la coordinator guarda referencias a actions transitivamente. | Media | Patrón obligado en Sub-fase D: `[weak coordinator] in await coordinator?.cancelEvent()`. Documentado en doc-comment de `ResourceAction.onTap` y reforzado en code review. |
| 3 | **`governanceAction` field — metadata vs re-check** — ambiguo en spec original. | Baja | Defecto **metadata** en V1 (provider ya filtró). Doc-comment explicita el rol. Sub-fase D confirma o expande a re-check con UI fallback si decide. |
| 4 | **Protocol shape inadecuado para V2+ resources** — Sub-fase A define `ResourceProtocol` con 3 miembros. Cuando llegue Slot, descubrir que falta algo (ej: parent group hierarchy) significa breaking change. | Media | Minimal-by-design: agregar miembros es aditivo (no breaking) si tienen default impls vía extensions. Si necesitan ser requirement, el cliente concreto lo agrega — refactor localizado. |
| 5 | **Cast `as!` en branches del switch** — si alguien construye `MockResource` que dice `resourceType = .event` pero no es `EventResource`, crash en runtime. | Baja | Invariant documentado: "el concrete type asociado a `.event` es `EventResource`, único en V1". Tests futuros (Sub-fase B) ejercitan el switch con un fake si hace falta. Hardening pattern (assertionFailure + graceful degradation) registrado como follow-up. |
| 6 | **`ResourceActionsProvider` con associatedtype no soporta heterogeneous arrays** — `[any ResourceActionsProvider]` no compila (PAT limitation). | Baja | V1 no necesita arrays de providers. Cada resource type tiene su provider concreto, accedido por switch en `resource.resourceType`. Si Fase 4 (template authoring tooling) lo necesita, agregar type-erased wrapper entonces. |

**Edge cases confirmados como out-of-scope V1**:
- Múltiples conformers de `.event` (ej: `LegacyEventResource`). No hay caso de uso.
- Resource sin grupo. Todo resource es group-scoped por contrato del platform.
- Mutation del wrapped Event. `EventResource` es value-type; refresh implica nuevo wrapper.

## §5 — Testing

### `EventResourceTests.swift` — 4 tests

XCTest, mock-based, `@MainActor` (donde aplique). Sin async — los tests son sincrónicos.

| Test | Verifica |
|---|---|
| `init_preservesEventIdentity` | Dado un `Event` con id/groupId conocidos, `EventResource(event).id == event.id` y `.groupId == event.groupId`. |
| `resourceType_alwaysEvent` | `EventResource(event).resourceType == .event` para cualquier evento (invariant). |
| `event_property_returnsOriginal` | `EventResource(event).event` retorna la struct original sin pérdida — comparar con `XCTAssertEqual` (Event es Hashable). |
| `identifiable_inForEach` | Construir 3 EventResources con ids distintos, verificar que un set de sus ids tiene size 3 (Identifiable conformance funciona). |

Fixture: factory helper `makeEvent(id:UUID = .init(), groupId:UUID = .init(), ...)` con defaults razonables, similar al pattern de fines/votes existentes.

### `ResourceActionTests.swift` — 3 tests

| Test | Verifica |
|---|---|
| `init_withDefaults` | `ResourceAction(id:icon:title:governanceAction:onTap:)` deja `subtitle = nil` y `isDestructive = false`. Verificar campos asignados. |
| `id_isStable` | Dos ResourceActions con mismo id pero closures distintos comparten id. Útil porque `id` es la key estable para ForEach (no el closure). |
| `onTap_executesClosure` | Construir action con closure que incrementa counter via mutable Box; `await action.onTap()`; verificar counter == 1. Sendable closure pattern. |

Fixture: `GovernanceAction.cancelEvent` (o `.fineWaiver` si `cancelEvent` no existe en el enum aún — pickear uno disponible para no inflar codegen scope).

### Build gate

```bash
cd /Users/jj/code/tandas/ios && xcodegen generate >/dev/null 2>&1 \
  && xcodebuild -scheme Tandas -project Tandas.xcodeproj \
       -destination 'generic/platform=iOS' -configuration Debug build 2>&1 \
  | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED|\*\* )" | head -10
```

Must print `BUILD SUCCEEDED`.

### Test gate

```bash
cd /Users/jj/code/tandas/ios && xcodebuild test \
  -scheme Tandas -project Tandas.xcodeproj \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=26.0' \
  -only-testing:TandasTests/EventResourceTests \
  -only-testing:TandasTests/ResourceActionTests 2>&1 \
  | grep -E "(PASSED|FAILED|error:|Test Suite)" | tail -20
```

7 tests verdes, 0 fail.

### Codegen gate

Sub-fase A no toca enums (ResourceType, GovernanceAction, SystemEventType ya tienen los cases necesarios). `make gen` no debería producir diff. Si produce, abortar y revisar.

## DoD

- [ ] `Platform/Resources/ResourceProtocol.swift` creado, conforma a `Identifiable + Sendable`, expone 3 miembros.
- [ ] `Platform/Resources/EventResource.swift` creado, struct, conforma a `ResourceProtocol`, expone `event: Event` público.
- [ ] `Platform/Resources/ResourceAction.swift` creado, struct con doc-comments de retain cycle + governanceAction-as-metadata.
- [ ] `Platform/Resources/ResourceActionsProvider.swift` creado, protocol skeleton con associatedtype `R: ResourceProtocol`.
- [ ] `TandasTests/Platform/Resources/EventResourceTests.swift` creado, 4 tests verdes.
- [ ] `TandasTests/Platform/Resources/ResourceActionTests.swift` creado, 3 tests verdes.
- [ ] `xcodebuild build` green para `generic/platform=iOS`.
- [ ] `xcodebuild test` green para los dos suites nuevos.
- [ ] Codegen gate sin diff (`make gen` no-op).
- [ ] Cero cambios en `Features/`, `Models/`, `Coordinators/`. Sub-fase A es aditivo.
- [ ] Naming alignment verificado: `resourceType` consistente entre data-layer y UI-layer protocols.
- [ ] xcodegen actualiza `project.yml` para incluir el nuevo directorio (verificar que los archivos nuevos compilan).

## Follow-ups (registered, not blocking)

- **Hardening pattern para `as!` casts** (Risk #5) — convertir `as!` a `as?` con `assertionFailure` en DEBUG + graceful degradation a `ResourceUnknownBody` en RELEASE. Esperar a primer crash en Sentry con ese pattern antes de implementar.
- **`governanceAction` re-check on tap** — Sub-fase D decide si V1 sigue metadata-only o se expande a defense-in-depth con UI fallback ("La gobernanza cambió, refrescá").
- **Type-erased `AnyResourceActionsProvider`** — solo si Fase 4 (template authoring tooling) necesita arrays heterogéneos de providers.
- **Hashable conformance en `ResourceProtocol`** — solo si NavigationStack(path:) value-based routing lo demanda. Por ahora navegación pasa concrete types o id+type pair.
- **Codable conformance en `EventResource`** — solo si la data-layer comienza a persistir wrappers (no en V1).
- **Conformance de `EventResource` a la data-layer `Resource`** — requiere agregar `updatedAt` a `Event` + Codable. Útil cuando edge functions o repos quieran tipar contra el shape genérico. No bloquea ninguna sub-fase de Fase 0.5.
- **`IdentifiedAction` wrapper para diff en SwiftUI** — si `[ResourceAction]` necesita comparación estructural en una view animada, agregar wrapper que sea Equatable por id.
- **`Equatable` en `EventResource`** — si tests futuros lo necesitan, agregar conformance trivial (Event es Hashable).
- **Reactive observation de governance changes** — si UX feels stale post-mid-session governance change, suscribir provider a un publisher de governance updates. Symmetry-break con EditRulesView Q5.1.
