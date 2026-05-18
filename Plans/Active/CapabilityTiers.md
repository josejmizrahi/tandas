# Ruul — Capability Tiers (Source of Truth)

**Status:** Canónico desde 2026-05-17. Founder directive.
**Companion of:** `Plans/Active/Constitution.md` (Artículos 2 y 11), `Plans/Active/HierarchyReference.md` §3 (capabilities catalog), `Plans/Active/Asset.md` §8 (atom contracts).
**Scope:** Declara qué capabilities son **universales** (Tier 0) vs **económicas** (Tier 0.5) vs **type-specific** (Tier 1). Toda decisión de extender o restringir `enabledResourceTypes` en el catálogo consulta primero este documento.

> Ruul venía cargando una inconsistencia: `status`, `description`, `history`, `voting` eran universales en los 6 resource types, pero `rules`, `ledger`, `money` estaban gateados a un subset histórico `[event, slot, fund]`. No por doctrina — por accidente de Phase 1/2. Este doc cierra el hueco.

---

## §1 — Principio

Una capability es **universal** si responde "sí" a:

> *¿Tiene sentido decir que CUALQUIER tipo de resource puede tener esto?*

Si la respuesta requiere caveats por type → no es universal, es type-specific. Si la respuesta es "sí, aunque en algunos types el caso de uso sea menor" → es universal.

Para los economicos hay un Tier intermedio porque hay un subset bien definido (todo lo que tiene relevancia económica menos `right`) donde la cap aplica universalmente.

---

## §2 — Tier 0: Universales absolutas (los 6)

Estas capabilities **deben estar en `[event, fund, asset, space, slot, right]`**. Aplican a todo lo que existe en el sistema.

| Capability | Razón ontológica |
|---|---|
| `status` | Todo resource existe en algún lifecycle (draft → active → completed/cancelled/expired) |
| `description` | Todo resource puede portar texto humano que lo contextualice |
| `history` | Todo resource emite `system_events` y produce una bitácora. **Activity = History** (canónico: `history`, no se crea bloque `activity` separado) |
| `rules` | Todo resource puede gobernarse: rules atan WHEN/IF/THEN sobre cualquier atom |
| `voting` | Toda decisión puede someterse a votación; voting es la primitiva de gobernanza canónica |

**No se crean en Fase 1**:
- `activity` — sinónimo de `history`. Misma surface, mismo bloque.
- `permissions` — el access control vive a nivel grupo (`groups.roles`) + via `right` resource type. Resource-specific permissions futuras se resuelven con `right + governance`, no con un permission layer paralelo.

---

## §3 — Tier 0.5: Económicas (5 de 6, sin `right`)

Estas capabilities aplican a **`[event, fund, asset, space, slot]`** — todo resource que puede ser destinatario o origen de movimientos económicos. **`right` queda fuera por doctrina**:

> Un `right` es una **relación estructurada**, no una cosa con balance propio. Un derecho puede generar fees, expirar, transferirse, votarse — pero el dinero vive en el resource subyacente (el fund que paga el fee, el asset que el derecho controla), no en el derecho mismo.

| Capability | Tipos | Razón |
|---|---|---|
| `ledger` | event, fund, asset, space, slot | Cualquier resource puede recibir atoms económicos (gastos asociados, aportes, settlements, payouts) |
| `money` | event, fund, asset, space, slot | Surface de balance + projection económica derivada del ledger |
| `valuation` | asset, fund | Sólo asset y fund tienen "cuánto vale yo" como concepto canónico. En event/space/slot lo que querés es `budget`/`cost`/`price`/`capacity economics` — son conceptos distintos a `valuation` |

---

## §4 — Tier 1: Type-specific (subset por diseño)

Estas capabilities están correctamente gateadas a un subset porque su semántica es type-específica. Listado no exhaustivo — la fuente canónica sigue siendo `CapabilityCatalog.swift`:

| Capability | Types | Razón |
|---|---|---|
| `rsvp`, `check_in`, `host_actions`, `appeal` | event | Sólo eventos tienen invitados, asistencia, host, apelación de cancelación |
| `swap`, `rotation`, `recurrence` | slot (+ event para recurrence) | Lifecycle de turnos rotativos |
| `custody`, `maintenance`, `transfer`, `inventory` | asset (algunos extendidos a space/right) | Sólo objetos persistentes tienen custodio, mantenimiento, transferencia |
| `booking` | slot, asset | Reservas |
| `access`, `delegation`, `approval` | combos asset/right/slot | Control de acceso explícito |
| `location` | event, slot, asset | Ubicación física |
| `reminder` | event, slot, fund | Notificaciones programadas (extendible cuando se necesite) |

---

## §5 — Backfill obligatorio para resources existentes

Cuando se introduce una nueva universal o se extiende el subset de una económica, los resources existentes deben recibir la capability automáticamente. La migración correspondiente inserta en `resource_capabilities` con `enabled = true` para todo resource cuyo type ahora califica.

Idempotente: usa `ON CONFLICT (resource_id, capability_block_id) DO NOTHING`.

---

## §6 — Reglas de evolución

1. **Promover de Tier 1 a Tier 0** requiere edit a este doc + extensión del catálogo + backfill. No se puede hacer sin doc.
2. **Demoter de Tier 0 a Tier 1** está prohibido salvo founder directive explícita. Universal es un compromiso.
3. **Crear nueva capability** debe declarar su Tier desde el día 1. Si dudás entre Tier 0 y Tier 1, defaulteá a Tier 1 — promovés después si el caso de uso emerge en ≥3 types distintos.
4. **`right` nunca recibe Tier 0.5** salvo redefinición ontológica de qué es un `right`. Hoy `right` = relación estructurada, no contenedor económico.

---

## §7 — Doctrina post-Fase 1

Después de aplicar este documento, el founder puede afirmar:

> *"Cualquier resource del grupo tiene status, description, history, rules y voting. Cualquier resource económicamente relevante (todos menos `right`) además tiene ledger y money. Si un resource no tiene una capability, es porque no le aplica semánticamente, no por accidente histórico."*

Esa es la base sobre la que la Fase 2 (grafo polimórfico `resource_links`) y Fase 3 (superficies agregadas del grupo) pueden construirse sin más debates ontológicos.

---

## §8 — Capability ≠ Surface (regla cardinal)

Tener una capability **no obliga** a renderizar una sección UI para ella. Encontrado al cierre de Fase 1: la cap `valuation` está sancionada para fund pero no hay `FundValuationSection`. La cap `voting` es universal pero no hay `VotingSectionView`. Eso **no es bug** — es la consecuencia natural de separar potencial estructural de superficie visual.

**Regla**:

> *Una capability declara que el resource puede, doctrinalmente, sostener cierta función. Una surface UI es el render concreto de esa función. Las dos evolucionan en distinta velocidad. Es válido tener cap activa sin surface, y la inversa (surface que sólo aparece bajo data específica) también.*

**Implicancias**:
1. Un resource creado puede tener 8 caps en `resource_capabilities` y mostrar 3 sections en el detalle. Normal.
2. Agregar una surface después (ej: `FundValuationSection`) no requiere migración de caps — los caps ya están.
3. **No** justifica crear caps de más "por si acaso". Cap nueva = compromiso doctrinal (§6).
4. **No** justifica esconder caps que ya están — la falta de surface es transitoria, no doctrinal.

Esta regla es la que permite a Ruul evolucionar incrementalmente sin sobrediseñar UI ni subdiseñar el modelo.

---

## §9 — Deferred backlog (Phase 1.1 cleanup)

Los siguientes items son consecuencia natural de Fase 1 pero **NO** se ejecutan ahora. Quedan documentados para retomar después de Fase 2 (`resource_links`). Hacerlos prematuramente abre el riesgo "ya que estamos" — alcance creciendo en paralelo a cambios estructurales mayores.

| # | Item | Motivo de diferir |
|---|---|---|
| 1 | `ActivitySectionView` gate `caps.contains("activity")` → `caps.contains("history")` | "activity" no existe como cap; eliminarlo confirma `activity = history` per §2. Cleanup de doctrina, no de feature. |
| 2 | `FundValuationSection` (surface para valuation cap en fund) | Cap ya está, surface no — §8 admite el desfase. Crearlo cuando un caso de uso lo demande. |
| 3 | `VotingSectionView` universal | Voting cap es Tier 0 desde hace tiempo pero no tiene surface dedicada. Mismo principio §8. |
| 4 | Normalización de copy en rule shapes que asumen lenguaje event-flavored | Cosmético; sale después de Fase 2 cuando el grafo permita rule shapes cross-resource. |
| 5 | Empty-state polish en Money/Rules cuando resource recién creado | Las cards funcionan; el polish es estética. |

**Promesa**: estos items se retoman como "Phase 1.1 cleanup" después de cerrar Fase 2. No antes.
