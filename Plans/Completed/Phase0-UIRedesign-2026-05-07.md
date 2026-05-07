# Fase 0 — UI Redesign Spec

> Fecha: 2026-05-07
> Origen: `Plans/UIAudit-2026-05-07.md` (auditoría completa)
> Estado: PROPUESTA — implementación sprint-by-sprint

---

## 0. Tesis

El código está **arquitectónicamente sano**: `@Observable @MainActor` correctamente, `async let` para fetches paralelos, design system bien tokenizado, AuthGate como single source of truth.

La UX sufre de **5 problemas de pulido** que son visibles y arregables sin re-arquitectura:

1. Loading states bare → reemplazar con `LoadingStateView` ya existente
2. Group switcher solo en HomeView → exponer global en header sticky
3. Errors silenciosos → protocolo `LoadingCoordinator` + `ErrorStateView` rollout
4. Motion ausente → aplicar `RuulMotion` tokens en transiciones loading↔content
5. MainTabView monolítica (23 `@State`) → extraer `RouteRegistry` + builders

**No re-arquitectura. Pulido sistemático.**

---

## 1. Principios

### 1.1 Patrón único de loading
Toda vista que carga data sigue exactamente este árbol:

```swift
if coordinator.items.isEmpty && coordinator.isLoading {
    LoadingStateView(variant: .list | .card | .detail)
        .transition(.opacity.animation(RuulMotion.fadeIn))
} else if let error = coordinator.error {
    ErrorStateView(error: error, retry: { await coordinator.refresh() })
} else if coordinator.items.isEmpty {
    EmptyStateView(...)
} else {
    contentList
        .refreshable { await coordinator.refresh() }
}
```

Sin variantes. Sin shortcuts. Sin `ProgressView()` bare.

### 1.2 Protocolo `LoadingCoordinator`
Todos los coordinators implementan:

```swift
@MainActor
protocol LoadingCoordinator: AnyObject, Observable {
    var isLoading: Bool { get }
    var isRefreshing: Bool { get }
    var error: CoordinatorError? { get set }
    func refresh() async
    func clearError()
}

struct CoordinatorError: Equatable, Sendable {
    let message: String
    let isRetryable: Bool
}
```

Cuando un fetch falla, el coordinator setea `error`. La vista lo muestra. Punto.

### 1.3 Group switcher global
Movemos el switcher del menú contextual de HomeView a un **`GroupHeaderBar`** sticky que vive en el shell por encima del tab content. Visible siempre, mismo tap-to-switch sheet, badge consistente cross-tab.

### 1.4 Motion sistemático
Aplica `RuulMotion.fadeIn` (200ms linear) en transiciones de skeleton→contenido. Aplica `RuulMotion.standard` (300ms easeOut) en sheet dismiss. Aplica `RuulMotion.expressive` (450ms spring) en group switch.

Definir `RuulMotion` namespace si no existe; mover constants ahí.

### 1.5 Routing por feature
MainTabView reduce `@State` de 23 a ~5. Cada tab expone su propio `RouteHost` que encapsula sus rutas. MainTabView solo orquesta tabs + group switch + deep links de alto nivel.

---

## 2. Plan de ejecución (5 sprints)

### Sprint 1 — Loading States Unification (MUST)
**Objetivo:** Cero `ProgressView()` bare en vistas principales. `LoadingStateView` rollout en 8 vistas.

**Touchpoints:**
- `Features/Home/Views/HomeView.swift` — variant `.card` para hero, `.list` para upcoming
- `Features/Inbox/Views/ActionInboxView.swift` — `.list`
- `Features/Rules/RulesView.swift` — `.list`
- `Features/Votes/Views/OpenVotesListView.swift` — `.list`
- `Features/Votes/Views/VoteDetailView.swift` — `.detail`
- `Features/Fines/Views/MyFinesView.swift` — `.list`
- `Features/Profile/Views/ProfileView.swift` — `.card`
- `Features/Events/Views/EventDetailView.swift` — `.detail`

**Salida:** Build OK + visual smoke en simulador.

**Esfuerzo:** 1 sesión.

### Sprint 2 — Error Protocol + Rollout (MUST)
**Objetivo:** Todo coordinator tiene `.error: CoordinatorError?`. Toda vista muestra `ErrorStateView` con retry.

**Touchpoints:**
- Crear `Platform/Coordinators/LoadingCoordinator.swift` (protocolo + struct)
- Adoptar en: Home, Inbox, Rules, OpenVotes, VoteDetail, MyFines, Profile, EventDetail, GroupHistory
- Mostrar `ErrorStateView` en cada vista correspondiente
- Limpiar error en `clearError()` cuando user dismisses

**Salida:** Forzar fallo en simulador (matar red) → ver ErrorStateView con retry funcional.

**Esfuerzo:** 1.5 sesiones.

### Sprint 3 — Group Header Global (HIGH)
**Objetivo:** Group switcher visible desde cualquier tab. Tap → mismo `GroupSwitcherSheet`. Badge sync cross-tab.

**Touchpoints:**
- Crear `Shell/GroupHeaderBar.swift` — sticky bar con group name + chevron + total inbox badge
- Inyectar arriba de `TabView` en `MainTabView` (zIndex high, glass material)
- Quitar el group switcher Menu de `HomeView` header (deja solo greeting)
- Mantener `GroupSwitcherSheet` (no cambia)
- Animar transition al cambiar grupo: fade + crossfade del nombre (250ms)

**Decisión:** Bar arriba (encima de tab content), no en tab bar (preserva Apple Sports aesthetic).

**Salida:** Cambio de grupo desde Inbox o Rules sin regresar a Home.

**Esfuerzo:** 1.5 sesiones.

### Sprint 4 — Motion Tokens Rollout (HIGH)
**Objetivo:** Loading→content fade. Group switch crossfade. Sheet dismiss spring.

**Touchpoints:**
- Auditar / completar `DesignSystem/Tokens/RuulMotion.swift` (define `fadeIn`, `standard`, `expressive`)
- Aplicar `.transition(.opacity)` con animación en cada `LoadingStateView` mount/unmount
- Aplicar crossfade en `GroupHeaderBar` cuando `activeGroup` cambia
- Aplicar `.animation(RuulMotion.standard, value: ...)` en sheet presentation toggles

**Salida:** Smoke en device — feel premium.

**Esfuerzo:** 1 sesión.

### Sprint 5 — MainTabView Refactor (MED, optional para F0)
**Objetivo:** Reducir `@State` de 23 a ~5. Extraer route builders por feature.

**Touchpoints:**
- Crear `Shell/Navigation/RouteHost.swift` — wrapper de `NavigationStack` + per-tab routes
- Crear `Shell/Navigation/HomeRouteHost.swift`, `InboxRouteHost.swift`, `RulesRouteHost.swift`, `ProfileRouteHost.swift`
- Cada hosts encapsula sus `@State` routes + `navigationDestination`
- MainTabView solo orquesta: `TabView { HomeRouteHost(); InboxRouteHost(); ... }` + group bar + global sheets

**Salida:** Build OK + smoke. Diff de líneas en MainTabView -300 líneas.

**Esfuerzo:** 2 sesiones. **Marca como follow-up post-F0** salvo que el usuario lo pida explícito — bajo el principio de "no re-arquitectura ahora".

---

## 3. Definition of Done por sprint

Cada sprint termina cuando:

- [ ] Build limpio (`xcodebuild ... build` → `BUILD SUCCEEDED`, sin warnings nuevos)
- [ ] Smoke en simulador iOS 26 (toda vista afectada al menos abierta una vez)
- [ ] Smoke en device (Sprint 3 + 4 son los que requieren device — motion + glass)
- [ ] Commit con mensaje descriptivo
- [ ] Audit doc updated con sprint marcado ✅

---

## 4. Lo que NO se toca en F0

- **Restructuración de tabs** — los 4 tabs actuales se quedan. Cambiar a 3 o 5 tabs es Fase 1+.
- **Custom transitions de NavigationStack push/pop** — usar default iOS.
- **Dynamic Type completo** — accesibilidad es Fase 1+ (importante pero no rompe la UX core).
- **Skeletons custom por feature** — `LoadingStateView.list/.card/.detail` cubre 95%; resto se patrolla en F1.
- **Cache strategy global** — solo `HomeCoordinator` cachea hoy; expandir a otros es F1.
- **Empty state hero illustrations** — los `EmptyStateView` actuales son funcionales; mejorar arte es F1+.

---

## 5. Riesgos

| Riesgo | Mitigación |
|---|---|
| `LoadingStateView` no encaja en `EventDetailView` (parallax) | Sprint 1 expone el caso; si `.detail` variant no funciona, agregar `.parallax` variant en LoadingStateView |
| `GroupHeaderBar` choca con safe area / nav bar | Probar en device con notch + Dynamic Island. Aplicar `.safeAreaInset(edge: .top)` |
| Motion tokens slow en simulador | Smoke en device. Simulador no es ground truth. |
| Error protocol breaking change | Migración gradual: protocol opcional al principio, vistas opt-in |

---

## 6. Sequencing recomendado

```
Sprint 1 (loading)  →  Sprint 2 (errors)  →  Sprint 3 (group bar)  →  Sprint 4 (motion)
                                                                              │
                                                                              ▼
                                                         Sprint 5 (refactor) — solo si tiempo
```

Sprints 1-2 son **prerequisitos visuales** — sin loading states unificados, agregar group bar y motion no se nota.

Sprints 3-4 son **el "wow"** — aquí es donde la app cambia de "funcional" a "se siente bonita".

Sprint 5 es **deuda técnica** — invisible al usuario pero crítico para escalar Fase 1+.

---

## 7. Plan de testing

Cada sprint cierra con smoke matrix:

| Acción | Sprint 1 | Sprint 2 | Sprint 3 | Sprint 4 |
|---|---|---|---|---|
| Cold start → Home | skeleton hero ✅ | — | header bar ✅ | fade in ✅ |
| Home → Inbox | skeleton list ✅ | — | header persists ✅ | tab fade ✅ |
| Pull-to-refresh Rules | spinner top ✅ | — | — | smooth ✅ |
| Cortar red → reload | — | error + retry ✅ | — | — |
| Tap header bar (Sprint 3+) | — | — | sheet ✅ | spring ✅ |
| Cambio de grupo | flicker → smooth | — | crossfade nombre ✅ | crossfade ✅ |

---

## 8. Estado de implementación

- [x] Sprint 0: Audit (`Plans/UIAudit-2026-05-07.md`)
- [x] Sprint 0.5: Spec (este doc)
- [ ] Sprint 1: Loading states unification
- [ ] Sprint 2: Error protocol + rollout
- [ ] Sprint 3: Group header global
- [ ] Sprint 4: Motion tokens rollout
- [ ] Sprint 5: MainTabView refactor (deferred follow-up)

---

**Próximo paso:** Sprint 1 — Loading states unification. Ejecutar via subagent-driven development.
