# Plan Fase 0.5 — UI Resource Generalization

> Refactorizar la capa de UI de la iOS app para que sea resource-typed,
> no event-locked. Pre-condition para que Fase 2 (`shared_resource`) y
> Fase 3 (`pool`) sean aditivos en lugar de refactor-heavy. **Nueva fase,
> no estaba en el Roadmap original** — insertada por decisión 2026-05-06
> después de identificar que la UI heredó event-centricity del template
> `recurring_dinner` aunque el platform layer ya soporta múltiples
> resource types.
>
> **Versión 1.0** — 2026-05-06
> **Roadmap reference**: insertar entre Fase 0 (close) y Fase 1 (launch).

---

## 0. Premisa

El platform layer ya soporta 6 resource types (`event`, `slot`, `fund`, `position`, `asset`, `contribution`) en `Platform/Models/ResourceType.swift`. Tablas (`resources`, `system_events`, `fines`, `votes`) son resource-agnostic. Rule engine evalúa contra cualquier resource. Todo eso está hecho.

La UI no. Hoy:

- `HomeView` muestra "próximo evento", no "próxima cosa"
- `EventDetailView` es la pantalla central de la experiencia
- `EventHostActionsSection` se llama así porque asume eventos
- Los recientes P0 UI gaps (EditRulesView, AddManualFineSheet) anclan a EventDetailView como entry point natural

Esa asimetría — **platform agnostic, UI hardcoded a un resource type** — es el problema arquitectónico que Fase 0.5 resuelve. Sin esto:

- Fase 2 (`shared_resource`) cuesta 8-12 semanas porque tiene que refactorizar HomeView/EventDetailView para introducir slots
- Fase 3 (`pool`) cuesta otras 4-6 semanas para introducir contributions
- Cada template subsiguiente arrastra la deuda

Con Fase 0.5:

- Fase 2 cuesta 4-6 semanas (solo aditivo: nuevo body component, nuevo template config)
- Fase 3 cuesta 3-4 semanas (mismo principio)
- Net ahorro: 4-8 semanas en los próximos 12 meses

---

## 1. Principios

**P1. Refactor es invisible al usuario.** Después de Fase 0.5, el grupo de cenas existente debe ver exactamente la misma app. Mismas pantallas, mismos textos, mismos flows. Si un tester nota diferencia, es bug.

**P2. No tocamos backend.** El platform ya es agnostic. Cero migrations, cero cambios a RPCs, cero cambios a edge functions. Solo Swift.

**P3. Aditivo, no destructivo.** No borramos `EventDetailView`. Lo refactorizamos a `ResourceDetailView` que tiene `EventDetailBody` adentro. Cuando llegue `slot`, agregamos `SlotDetailBody` como hermano, no como reemplazo.

**P4. Tests primero, código después.** Cada refactor es snapshot-tested antes y después para asegurar paridad visual y funcional.

**P5. No abstraer lo que no aplica.** RSVP es event-only — no se abstrae a "respuesta de resource". Check-in es event-only. Slot tiene "accept/decline", no es lo mismo. Cada resource type tiene sus propios verbs; el contenedor genérico solo abstrae lo que es genuinamente común.

**P6. Templates declaran resources.** El `template.config` define qué resource types instancia. `recurring_dinner` declara `[event]`. Futuro `shared_resource` declara `[slot, position]`. Futuro `pool` declara `[fund, contribution]`. La UI lee del template, no asume.

---

## 2. La abstracción

### Capa 1 — Resource (data)

Ya existe en `Platform/Models/Resource.swift` (per docs/Platform.md). Es una struct que abstrae sobre `events`, `resources` table rows. V1 tiene un solo concrete type (`event` proyectado vía `events_view`).

**No se toca en Fase 0.5.** Está bien.

### Capa 2 — ResourceBody (UI body component, NEW)

Protocol + concrete implementations:

```swift
public protocol ResourceBodyView: View {
    associatedtype R: ResourceProtocol
    init(resource: R, coordinator: ResourceCoordinator)
}

// V1 implementación única
public struct EventDetailBody: ResourceBodyView {
    let resource: EventResource  // wrapper sobre Event que conforma a ResourceProtocol
    let coordinator: EventCoordinator  // existente, sin cambios
    public var body: some View { /* el cuerpo de EventDetailView actual */ }
}
```

### Capa 3 — ResourceDetailView (container, NEW)

```swift
public struct ResourceDetailView: View {
    let resource: any ResourceProtocol
    
    public var body: some View {
        ScrollView {
            ResourceHeader(resource: resource)
            
            // Body switches por type. V1 solo .event.
            switch resource.type {
            case .event:
                EventDetailBody(
                    resource: resource as! EventResource,
                    coordinator: /* injected */
                )
            // case .slot, .fund, etc — futuras Fases
            default:
                ResourceUnknownBody(resource: resource)
            }
        }
    }
}
```

`EventDetailView` actual queda como **alias deprecated** apuntando a `ResourceDetailView` con el wrapping correcto. Los call sites que hoy hacen `EventDetailView(event: e)` siguen funcionando vía un convenience init.

### Capa 4 — ResourceActionsSection (host actions, NEW)

```swift
public protocol ResourceActionsProvider {
    associatedtype R: ResourceProtocol
    func actions(for resource: R, member: Member, in group: Group) -> [ResourceAction]
}

public struct ResourceAction: Identifiable {
    let id: String
    let icon: String
    let title: String
    let subtitle: String?
    let isDestructive: Bool
    let governanceAction: GovernanceAction
    let onTap: () async -> Void
}

// V1 implementación única
public struct EventActionsProvider: ResourceActionsProvider {
    func actions(for resource: EventResource, member: Member, in group: Group) -> [ResourceAction] {
        // genera CancelEvent, CloseEvent, AddManualFine, RemindAttendees
        // basado en governance + estado del evento
    }
}
```

`EventHostActionsSection` se renombra a `ResourceActionsSection` y consume del provider correcto según resource type.

### Capa 5 — HomeView resource-typed (REFACTOR)

```swift
public struct HomeView: View {
    let nextResource: (any ResourceProtocol)?  // hoy es Event?
    
    public var body: some View {
        if let resource = nextResource {
            ResourceCard(resource: resource)  // genérico, switches por type
                .onTapGesture { navigate(to: resource) }
        } else {
            EmptyHomeState(template: activeTemplate)
        }
    }
}
```

`ResourceCard` es el equivalente generic de `EventCard`. Para V1, switch interno solo tiene `.event` case que renderiza igual que el card actual.

---

## 3. Las 6 sub-fases (sprints)

Cada uno es su propio brainstorm → spec → plan → execute cycle. Estimaciones son focused-work hours, no calendar hours.

### Sub-fase A — Resource UI protocols + EventResource wrapper

**Duración**: 1 día (4-6h).
**Goal**: introducir las primitivas de UI sin tocar nada existente.

**Trabajos**:
- Crear `ios/Tandas/Platform/Resources/ResourceProtocol.swift` con el protocol
- Crear `ios/Tandas/Platform/Resources/EventResource.swift` que wrappea `Event` y conforma a `ResourceProtocol`
- Crear `ios/Tandas/Platform/Resources/ResourceAction.swift` con la struct
- Crear `ios/Tandas/Platform/Resources/ResourceActionsProvider.swift` con el protocol
- Tests unitarios verificando que `EventResource(event)` round-trips correctamente

**DoD**: nuevos archivos compilan, tests verdes, código existente intacto.

### Sub-fase B — ResourceCard + HomeView refactor

**Duración**: 1-2 días (6-10h).
**Goal**: HomeView consume Resource genérico, EventCard se renombra a EventResourceCard con conformance.

**Trabajos**:
- Crear `ios/Tandas/DesignSystem/Components/ResourceCard.swift` que recibe `any ResourceProtocol` y switches por type
- `EventCard.swift` actual se convierte en una vista interna llamada por `ResourceCard` cuando `resource.type == .event`
- `HomeCoordinator.nextEvent: Event?` se renombra a `nextResource: any ResourceProtocol?`
- Snapshot tests asegurando que HomeView con un evento se ve idéntico a antes
- Manual visual diff: home con evento, home sin evento, home con evento pasado

**DoD**: snapshots idénticos a baseline pre-refactor, manual verification verde.

### Sub-fase C — ResourceDetailView container + EventDetailBody extraction

**Duración**: 2-3 días (10-14h). **Más complejo de toda Fase 0.5.**
**Goal**: extraer el cuerpo de `EventDetailView` a `EventDetailBody`, crear container `ResourceDetailView`, asegurar que todos los call sites siguen funcionando.

**Trabajos**:
- Crear `ResourceDetailView.swift` como container
- Mover el body completo de `EventDetailView` a `EventDetailBody.swift`
- `EventDetailView` queda como deprecated convenience: `init(event: Event) → ResourceDetailView(resource: EventResource(event))`
- Todos los call sites que hoy pushan `EventDetailView(event: ...)` pueden quedarse igual (init convenience preserva comportamiento) O migran a `ResourceDetailView(resource: ...)` — se prefiere el primer paso para minimizar riesgo, deprecar en Sub-fase F
- Snapshot tests de cada estado del evento (pre-event, en curso, cerrado, cancelado)
- E2E test del flow completo: tap event card → ResourceDetailView abre → todas las actions funcionan

**Riesgo más alto**: `EventDetailView` toca muchos componentes (RSVPSection, CheckInSection, HostActionsSection, etc.). Si la extracción rompe algún binding o navigation, el efecto cascada es grande.

**Mitigación**: snapshot tests obligatorios antes de mergear; manual QA sobre los 8 flows principales.

**DoD**: pixel-perfect identical a pre-refactor, todos los tests verdes, manual QA completo.

### Sub-fase D — ResourceActionsSection + provider

**Duración**: 1-2 días (5-8h).
**Goal**: generalizar host actions section.

**Trabajos**:
- Crear `ResourceActionsSection.swift` que recibe `[ResourceAction]`
- `EventHostActionsSection.swift` se reduce a invocar `ResourceActionsSection` con el output de `EventActionsProvider.actions(...)`
- Mover toda la lógica de "qué actions están disponibles" desde el view body al `EventActionsProvider`
- Tests del provider: dado evento + member + governance, retorna el set de actions correcto
- Snapshot tests de la section con 0, 1, varios actions

**DoD**: paridad funcional con la versión actual, lógica testeable centralizada.

### Sub-fase E — Templates declaran resource types

**Duración**: 1 día (4-6h).
**Goal**: el template config indica qué resources instancia, la UI lo lee.

**Trabajos**:
- En `templates.config` jsonb, agregar field `resourceTypes: ["event"]` para `recurring_dinner` (migration ligera, no rompe schema)
- En `TemplateConfig` Swift struct, agregar `resourceTypes: [ResourceType]` con default `[.event]` para backward compat
- `HomeCoordinator` y otros usan `template.resourceTypes` para decidir qué views renderizar
- Si template tiene `[event]`, HomeView muestra el next event. Si tuviera `[slot]` (futuro), mostraría next slot.
- En V1 todos los templates seguirán teniendo `[event]`, así que el behavior no cambia

**DoD**: migration aplicada limpia, struct deserializa correctamente, comportamiento idéntico en runtime.

### Sub-fase F — Cleanup + deprecations + regression QA

**Duración**: 1 día (4-6h).
**Goal**: limpiar deprecaciones, ejecutar QA exhaustivo, marcar Fase 0.5 cerrada.

**Trabajos**:
- Migrar todos los call sites de `EventDetailView(event:)` deprecated → `ResourceDetailView(resource: EventResource(event))`
- Borrar `EventDetailView.swift` (su contenido ya está distribuido entre `ResourceDetailView` y `EventDetailBody`)
- Idem `EventHostActionsSection.swift` → solo queda `ResourceActionsSection`
- Run full test suite (iOS + deno)
- Manual QA exhaustivo: 20 user flows del producto en simulador
- Push notification testing con resource-typed payloads (preparación para Fase 1 push notifs que ya no asumen "event")
- Update `Plans/Roadmap.md` para marcar Fase 0.5 como completa

**DoD**: cero usos del nombre `EventDetailView` (excepto en historial git), todos los tests verdes, 20 flows pasados manualmente, Roadmap actualizado.

---

## 4. Migration strategy

**Cero data migration.** Backend ya está listo, no se toca.

**Backward compat de UI**: durante toda Fase 0.5, los call sites pueden usar `EventDetailView(event:)` (init convenience) o `ResourceDetailView(resource:)` indistintamente. El cleanup en Sub-fase F migra todos a la nueva API y borra el alias.

**Rollback path**: si algo se rompe en producción (improbable porque no sale a App Store hasta Fase 1), revertir los commits de Fase 0.5. La estructura de "aditivo, no destructivo" hace cada commit reversible.

---

## 5. Definition of Done — Fase 0.5

- [ ] `Resource` UI protocols shipped (Sub-fase A)
- [ ] `HomeView` consume `any ResourceProtocol` no `Event` (Sub-fase B)
- [ ] `ResourceDetailView` es el container, `EventDetailBody` el body único V1 (Sub-fase C)
- [ ] `ResourceActionsSection` generalizada con provider pattern (Sub-fase D)
- [ ] Templates declaran `resourceTypes` en config (Sub-fase E)
- [ ] `EventDetailView` y `EventHostActionsSection` borrados; cero referencias en codebase (Sub-fase F)
- [ ] Snapshot tests: pre-refactor vs post-refactor pixel-identical para todos los estados de evento
- [ ] Manual QA: 20 flows del producto verificados en simulador, paridad total con baseline
- [ ] Roadmap actualizado marcando Fase 0.5 ✅ y reordenando Fase 2 con la estimación reducida
- [ ] Push notifications (Fase 1 WS1) ahora reciben resource-typed payloads, no hardcoded a event

---

## 6. Riesgos y mitigaciones

| Riesgo | Severidad | Mitigación |
|---|---|---|
| Refactor de `EventDetailView` rompe bindings o navigation | Alta | Snapshot tests obligatorios pre/post; manual QA de los 8 flows principales antes de mergear Sub-fase C |
| Abstracción wrong-shape descubierta cuando llega `slot` | Media | El protocol es minimal (resource + type + base actions); concrete bodies tienen libertad. Si shape es wrong, refactor en Fase 2 es localizado a body components nuevos, no al container |
| Sub-fase C se atrasa más de 3 días | Media | Si se atrasa, dividir EventDetailBody en sub-componentes más chicos antes de extraer. Lo extraído debe tener tests independientes |
| Templates field `resourceTypes` no es reconocido por templates existentes en prod | Baja | Default value `[.event]` en deserialization; schema query de templates en prod muestra que todos tienen formato esperado |
| Push notifications V1 (Fase 1 WS1) ya está diseñado event-centric | Media | Coordinarse con quien tome WS1 para que use resource-typed payloads desde el día 1; evita refactor de WS1 después |

---

## 7. Out of scope (Fase 0.5)

- **Implementación de slot, fund, position, asset, contribution resource bodies**. Solo se preparan los slots de extensión; concrete implementations llegan en Fase 2 y 3 cuando shippeen sus templates.
- **Cambios al rule engine, edge functions, RPCs, schema**. Backend está intacto.
- **Refactor de Inbox, Rules, Fines, History views**. Esas ya son cross-resource naturalmente.
- **Templates parametrizados con UI dinámica**. Eso es Fase 4 (template authoring tooling).

---

## 8. Cómo se actualiza el Roadmap original

Antes:
```
Fase 0: Hardening (4-6 sem)
Fase 1: V1 launch sobre recurring_dinner (4-6 sem)
Fase 2: Template #2 shared_resource (8-12 sem)
Fase 3: Template #3 pool (10-14 sem)
```

Después:
```
Fase 0: Hardening (4-6 sem) — ya en curso
Fase 0.5: UI Resource Generalization (1.5-2 sem) — NUEVA
Fase 1: V1 launch sobre recurring_dinner — UI ya generalizada (4-6 sem)
Fase 2: Template #2 shared_resource (4-6 sem) — REDUCIDA por trabajo previo
Fase 3: Template #3 pool (3-4 sem) — REDUCIDA
```

Net delta: +1.5-2 sem ahora, -8-14 sem acumulado en Fase 2-3. Inversión positiva.

---

## 9. Cómo arrancar

Cuando OpenVotesView (último P0 de Fase 0) merge en main, arrancás Fase 0.5 con la Sub-fase A:

1. Brainstorm con Sub-fase A: scope del Resource protocol, cómo wrappea Event, qué métodos expone. ~30 min.
2. Spec con Sub-fase A: documento similar al de EditRulesView, ~150-200 líneas. ~30 min.
3. Plan con Sub-fase A: ~5 commits chicos. ~30 min.
4. Execute: ~4-6 horas focused work.
5. Repetir A→F.

Cada sub-fase merge a main como su propio branch. Total estimado: 6-9 días focused work, 1.5-2 semanas calendar work con review tiempo.

---

## Notas finales

Esta fase no estaba en el Roadmap original. La metí cuando vos identificaste que la app sigue siendo event-centric en la UI a pesar del platform agnostic. Tu instinct fue correcto y vale anotar la lección: **el Roadmap es vivo**. Cuando aparece un punto que no tiene espacio en el plan original pero es estructural, se le hace espacio.

La diferencia entre "agregar Fase 0.5 ahora" vs "intentar hacerlo en Fase 2 cuando ya pesa más" son 4-8 semanas acumuladas. Por eso vale la inserción.

Cuando arranquemos la primera sub-fase, seguimos el flow validado: brainstorm → spec → plan → execute. Mismo template que codegen, EditRulesView, AddManualFineSheet.
