# Nivel 3 — Resource: gaps + completar polimorfismo

**Fecha:** 2026-05-15
**Estado:** Brainstorming → spec
**Decisor:** founder (jose.mizrahi@quimibond.com)
**Jerarquía:** `Plans/Active/HierarchyReference.md` §1 — Layer 3 (Resource/Object) + §2 (Resource types frozen)
**Migraciones base:** `00147` (resource_type frozen), `00158` (writers redirect to resources), `00159` (drop legacy events), `00184` (archive/unarchive), `00186` (atom guards), `00188` (metadata shape), `00191` (capabilities catalog write-lock)
**Specs hermanas:** Nivel 0/1/2 todas shipped. Spec previo `docs/superpowers/specs/2026-05-14-frontend-remodel-design.md` cubrió la extirpación del vertical Events — ya ejecutado.

## Problema

A diferencia de Nivel 0/1/2, el polimorfismo de Nivel 3 está **mayormente correcto**. La infraestructura clave existe:

- `UniversalResourceDetailView` (350 L) renderiza capabilities desde `CapabilityResolver`.
- `ResourceWizardSheet` + `ResourceBuilderRegistry` crean cualquier tipo sin `switch resourceType`.
- `ResourceTypeChrome.resolve(_:)` centraliza icon + color + labelKey para los 6 tipos.
- `LiveResourceRepository.list(in:types:statuses:limit:)` es polimórfico.
- `AssetDetailView` (260 L) + `SlotDetailView` (262 L) existen con UI real.
- `system_events` con tipos `resourceCreated`/`Archived`/`Renamed` ya se emiten.

Pero quedan **5 lagunas operativas** que rompen la promesa de "cualquier tipo coordinable":

1. **Fund / Space / Right no tienen detail views.** Aparecen creables en el wizard pero al tap "ver detalle" caen en un fallback de `UniversalResourceDetailView` que no sabe qué mostrar para tipos sin capabilities maduras. Resultado: tap = pantalla casi vacía.

2. **HomeView sigue hybrid.** `HomeCoordinator` lee `eventRepo.upcomingEvents(...)` para una sección + `resourceRepo.list(types: [todos menos event], ...)` para otra. Dos secciones distintas en el feed cuando deberían ser un solo feed cronológico polimórfico.

3. **`UniversalResourceDetailView` line 131** todavía hace `switch resource.resourceType` para decidir `coverHeroHeight`. Único switch que queda — violación residual del principio `feedback_no_hardcoded_verticals`.

4. **`EventRepository` usado en 15 sites.** No es bloqueante (la dual-write desapareció en mig 00159 y `events_view` es read-only), pero es deuda. `PastResourcesView`, `MyFeedCoordinator`, `ResourceCreationCoordinator`, `ResourceEditCoordinator`, `RotationSectionView`, `Adapters/EventDetailCoordinator` siguen llamándolo. Migrar requiere o (a) hacer `LiveResourceRepository` exponer los métodos faltantes, o (b) tratar `EventRepository` como un thin adapter sobre resources (que es lo que terminó siendo).

5. **`archive_resource` / `unarchive_resource` RPCs** existen (mig 00184) con triggers que emiten atoms. UI cero. No hay "archivar este recurso", no hay "papelera de recursos" análogo a la papelera de grupos.

## Objetivo

Cerrar las 3 lagunas más visibles:

- **3 nuevos detail views** (Fund, Space, Right) que muestren al menos: hero + metadata + capabilities activas + acciones primarias del `CapabilityResolver`.
- **HomeView polimórfico** — un solo feed cronológico que mezcla event/asset/fund/etc. cuando hay datos.
- **`coverHeroHeight` movido a `ResourceTypeChrome`** — última eliminación del `switch resourceType` de Views.

Lo demás (15 sitios de `EventRepository`, archivar resource desde UI) se defiere a pases posteriores — no bloquean nada hoy y tienen su propio spec en `2026-05-14-frontend-remodel-design.md`.

## Approach — 4 pasadas, Pass 1+2 en este plan

### Pass 1 · 3 detail views minimales (Fund/Space/Right)

Cada uno con la misma estructura mínima (~140 L):
- Hero card: type chrome icon + nombre + status + member count si aplica
- "Información" sección leyendo `metadata` jsonb safe (currency para fund, capacity para space, etc.)
- "Capabilities activas" lista (lee `resource_capabilities` filtered by enabled=true)
- "Reglas que aplican aquí" preview (si hay rules con scope=resource o resource_type)
- "Archivar" footer (admin-only, llama `archive_resource` RPC)

| Archivo | Tipo | Notas |
|---|---|---|
| `Features/Resources/Views/FundDetailView.swift` | NEW (~150 L) | Muestra `metadata.name`, `metadata.currency`, balance projection si `ledger` cap está activa |
| `Features/Resources/Views/SpaceDetailView.swift` | NEW (~140 L) | Muestra `metadata.location_name`, capacity, slots disponibles (si tiene cap `booking`) |
| `Features/Resources/Views/RightDetailView.swift` | NEW (~120 L) | Muestra `metadata.right_kind` (text), expiration, holder |
| `Features/Resources/Detail/UniversalResourceDetailView.swift` | MODIFY | Routing: si `resourceType == .fund` → `FundDetailView`; `.space` → SpaceDetail; `.right` → RightDetail. Mantiene la implementación rica para `.event`. |

NOTA: el routing es un único switch ubicado en `UniversalResourceDetailView` (no en cada caller). Esto NO viola `no_hardcoded_verticals` porque es el único nivel donde la discriminación es necesaria — el resto del código sigue siendo agnóstico.

### Pass 2 · HomeView polimórfico + remove cover switch

| Archivo | Acción |
|---|---|
| `Features/Home/HomeCoordinator.swift` | MODIFY. Reemplazar `eventRepo.upcomingEvents/upcomingEventsAcrossGroups` con `resourceRepo.list(types: ResourceType.allCases.filter { $0 != .right }, ...)`. (`right` quizás no se lista en feed cronológico — confirmar). Resultado: un solo `upcomingResources: [ResourceRow]`. |
| `Features/Home/HomeView.swift` | MODIFY. Las dos secciones "Próximos eventos" + "Otros recursos" → una sección "Próximas actividades" con cards heterogéneas. Usa `ResourceHeroCard` (ya existe en RuulUI) o equivalente. Falta confirmar el componente exacto. |
| `Features/Home/Views/HomeResourceCard.swift` | NEW si no existe (~120 L). Tarjeta polimórfica que renderiza chrome + título + fecha (para events) o info type-specific. Tap → `UniversalResourceDetailView`. |
| `RuulCore/Capabilities/ResourceTypeChrome.swift` | MODIFY. Agregar `coverHeroHeight: CGFloat`. Default ~180; event ~220 (más alto para cover image grande). |
| `Features/Resources/Detail/UniversalResourceDetailView.swift` | MODIFY. Reemplazar el `switch resource.resourceType` en line 131 (cover height) con `ResourceTypeChrome.resolve(resource.resourceType).coverHeroHeight`. |

### Pass 3 · Archivar / restaurar recursos (deferred)

Crear `ArchiveResourceSheet` + footer en `UniversalResourceDetailView` + `ArchivedResourcesView` accesible desde GroupHome.AVANZADO.

### Pass 4 · Drift cleanup: migrar 15 sites de EventRepository (deferred)

Reemplazar cada call con la versión polymorphic. Cada site es un mini-refactor; spec separado.

## Wireframes

**FundDetailView**
```
┌─────────────────────────────────────────┐
│  ⟵                       ⋯              │
│                                          │
│         🏦  Fondo de Cena                │
│         MXN · 8 contribuidores           │
│                                          │
├─ Información ───────────────────────────┤
│  Moneda                            MXN  │
│  Saldo actual                  $4,500   │  ← si ledger cap activa
│  Meta                          $10,000  │  ← si metadata.goal_amount
│  Activo                       Hace 3 m  │
│                                          │
├─ Capabilities ──────────────────────────┤
│  ✓ Ledger                               │
│  ✓ Contributions                        │
│  ✓ Voting on expenses                   │
│                                          │
├─ Reglas que aplican ────────────────────┤
│  "Gastos > $5,000 requieren voto"       │
│                                          │
├─ Avanzado ──────────────────────────────┤
│  📦 Archivar este recurso (admin)       │
└─────────────────────────────────────────┘
```

**HomeView polimórfico (Pass 2)**
```
┌─────────────────────────────────────────┐
│  Cenas con amigos                    ⌄  │
│  Pendientes (3) →                       │
│                                          │
│  Próximas actividades                    │
│  ┌──────────────────────────────────┐   │
│  │ 📅 Cena del jueves               │   │
│  │ Mañana 8pm · Casa de Ana          │   │
│  │ 6 confirmados                     │   │
│  └──────────────────────────────────┘   │
│  ┌──────────────────────────────────┐   │
│  │ 🏦 Fondo de Cena                  │   │
│  │ Saldo $4,500 / $10,000           │   │
│  └──────────────────────────────────┘   │
│  ┌──────────────────────────────────┐   │
│  │ 🏠 Palco Azteca 204               │   │
│  │ 3 slots disponibles               │   │
│  └──────────────────────────────────┘   │
│  ┌──────────────────────────────────┐   │
│  │ 📅 Cena del próximo jueves        │   │
│  │ En 8 días · Casa de Carlos        │   │
│  └──────────────────────────────────┘   │
└─────────────────────────────────────────┘
```

## Decisiones explícitas

1. **El detail switch vive en `UniversalResourceDetailView`** — único punto de discriminación. Justificado: el switch es estructural (qué view renderizar) no decorativo (icon/color). El resto del código sigue siendo agnóstico via `CapabilityResolver` y `ResourceTypeChrome`.

2. **`RightDetailView` es scaffold minimalista** — Right ("derecho de uso") tiene menos coordinación que los demás tipos. Asset y Space dominan; Right vive como FYI.

3. **HomeView muestra un solo feed cronológico** — no clusters por tipo. La heterogeneidad es UN cualidad del producto. Sortear por `created_at desc` (o un campo `display_at` cuando sea event).

4. **`coverHeroHeight` es type-specific via Chrome**, no via View. Event = 220, others = 180 default. Si más tarde Fund quiere cover image grande, basta cambiar el Chrome.

5. **Pass 3 (archivar resource) se difiere** — no es bloqueante, requiere su propio spec con consideración de cascade (qué pasa con fines/votes asociados cuando se archiva el resource).

6. **15 sites de `EventRepository` quedan vivos**. No los toco aquí porque cada uno requiere análisis caso a caso (ej. `RotationSectionView` necesita event-specific data — quizás eventRepo es lo correcto allí). Migración granular en spec dedicado.

## Riesgos

| Riesgo | Mitigación |
|---|---|
| `ResourceRow.metadata` jsonb shape varía por tipo | Cada detail view tiene helpers safe `metadata["key"] as? String` con defaults. NO crashes |
| HomeView polimórfico rompe ordering de events | Verificar que `ResourceRow` tiene `created_at` o `display_at`; sort estable |
| Fund balance projection requiere ledger view query | Si `ledger_view` no tiene helper polymorphic, mostrar placeholder "Próximamente" en lugar de crash |
| `RightDetailView` sin contenido real puede sentirse vacío | Acepta esta delgadez por ahora; metadata shape de Right se afina con el primer caso real |
| `coverHeroHeight` default puede ser ajustado | Es un único valor cambiable luego sin migración |

## Tests

| Pass | Tests críticos |
|---|---|
| 1 | `FundDetailView` snapshot: render con metadata completa + incompleta. `SpaceDetailView`: render sin capability `booking`. `RightDetailView`: render mínimo. UniversalDetailView routing: cada tipo abre el view correcto. |
| 2 | `HomeCoordinator`: una sola llamada `list(types:)` reemplaza dos. `HomeView`: feed ordenado, items mezclados. `ResourceTypeChrome.coverHeroHeight`: event devuelve 220, otros 180. |

## Out of scope (futuros specs)

- **Pass 3:** archivar/restaurar recursos UI
- **Pass 4:** migrar los 15 sites de `EventRepository`
- **Past resources** — `PastResourcesView` ya existe pero usa eventRepo
- **Cross-group resource feed** — feed across all my groups
- **Fund-specific actions** — contribute / approve expense UI
- **Resource transfer** — cambiar ownership / responsable
- **Right kind taxonomy** — qué tipos de "derecho" existen (membresía externa, equity, voto, acceso) — necesita producto-research

## Done When

- 3 nuevos detail views funcionando (Fund/Space/Right).
- `UniversalResourceDetailView` routea a ellos por tipo.
- `HomeView` muestra un solo feed polimórfico.
- `ResourceTypeChrome.coverHeroHeight` existe.
- Última `switch resource.resourceType` en una View eliminada.
- Build clean + smoke en simulador.

## Cobertura del plan inicial

**Pass 1 + Pass 2 en el primer commit** (~6-7 tasks). Pass 3 + Pass 4 cada uno como plan dedicado posterior.
