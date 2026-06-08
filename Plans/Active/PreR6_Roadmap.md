# Pre-R.6 Roadmap — Plan consolidado (R.5X + R.5Y + R.5W)

**Fecha consolidación:** 2026-06-07
**Status:** 🟢 SOBRE RIEL — 5/8 slices shipped, 3 pendientes antes de R.6
**Bloquea:** R.6 Rule Engine 2.0
**Founder lock (signed 2026-06-07):** orden de ejecución congelado, NO se altera sin firma adicional.

Este documento **reemplaza** los tres planes previos:
- ~~`Plans/Archive/R5X_ProductCompletenessAudit.md`~~ (matriz histórica en `Plans/Reports/R5X_AuditMatrix.md`)
- ~~`Plans/Archive/R5Y_AttentionCenter.md`~~ (shipped, ver memorias `project_r5y_a1/a2_shipped.md`)
- ~~`Plans/Archive/R5W_UserDecisionTreeConsistency.md`~~ (matriz histórica en `Plans/Reports/R5W_UserDecisionTreeMatrix.md`)

---

## 1. Visión single-source

Antes de R.6 Rule Engine 2.0 hay que cerrar product completeness + decision tree consistency + attention surface. Las 3 auditorías levantadas (R.5X, R.5Y, R.5W) tienen UN solo backlog priorizado, UN solo orden, y UN solo flujo de cierre.

Pregunta única que el founder firma al cierre:

> "¿El producto es honesto, predecible, y la atención del usuario está consolidada antes de que el Rule Engine empiece a generar volumen?"

---

## 2. Orden de ejecución FIRMADO (congelado founder)

```
1. ✅ R.5X.fix.A   — RPCErrorMapper mapper "Próximamente" (P0-01 D firmado)
2. ✅ R.5X.fix.B   — intent.obligation en CreateIntentSheet (P0-02 Flow 4 Empresa unblock)
3. ✅ R.5X.fix.C   — register_document emit canonical document.created (P0-03)
4. ✅ R.5Y.A1      — Attention Center backend (settlement_open + resource_conflict_direct cross-context + payload enrichment)
5. ✅ R.5Y.A2      — Attention Center iOS (AttentionDispatcher único + 3 switches duplicados eliminados)
6. ⏳ Documents V2 — DocumentsListView + DocumentDetailView + QuickLook + supersedes (immutables + versions = nuevo doc)
7. ⏳ Resource Subtype Picker — en CreateResourceView
8. ⏳ R.5W.fix.*   — 3 P1 INCONSISTENT (cancel_decision dialog · roles section honest disabled · reservation row push)
9. ⏳ R.6 Rule Engine 2.0
```

Founder cita literal: **"el mayor faltante ya no es backend; es la capa de atención y descubrimiento de problemas."**

---

## 3. Estado actual (2026-06-07)

### Shipped (5)

| Slice | Build | Memoria |
|---|---|---|
| R.5X.fix.A | iOS verde 10.4s · 6 tests | `project_r5x_fix_a_shipped.md` |
| R.5X.fix.B | iOS verde 6.8s | `project_r5x_fix_b_shipped.md` |
| R.5X.fix.C | Mig `r5x_fix_c_register_document_canonical_emit` aplicada | `project_r5x_fix_c_shipped.md` |
| R.5Y.A1 | Migs `r5y_a1`+`a1_1`+`a1_2` aplicadas · smoke verde | `project_r5y_a1_shipped.md` |
| R.5Y.A2 | iOS verde 25.3s · 230 LOC dispatcher · 3 switches eliminados | `project_r5y_a2_shipped.md` |

Push a `main` y device install (iPhone JJ) confirmados en `bc8953c2..b1742389`.

### Pending (3)

| Slice | Bloqueante | ETA estimado |
|---|---|---|
| **Documents V2** | Founder priority #1 ("deuda evidente") | 3 views nuevas + RPC client + store + 5 wire-ups + Storage QuickLook |
| **Resource Subtype Picker** | P1-11 R.5X firmado | iOS picker + CreateResourceView refactor + descriptor refresh |
| **R.5W.fix.* (3 P1)** | Cosméticos pero firmados | ~35 LOC iOS total |

---

## 4. Decisiones founder firmadas (todas)

### R.5X — Product Completeness

| ID | Decisión | Cuándo |
|---|---|---|
| **P0-01** | Acción no implementada → **D ahora** (mapper iOS) + **C post-R.6** (badge backend). NUNCA error técnico al user. Copy oficial: "Próximamente · Esta funcionalidad ya está modelada en Ruul, pero todavía no está disponible." | ✅ D shipped (R.5X.fix.A) · C deferred post-R.6 |
| **P0-02** | `intent.obligation` en CreateIntentSheet | ✅ shipped (R.5X.fix.B) |
| **P0-03** | Activity emit canonical `document.created` | ✅ shipped (R.5X.fix.C) |
| **FQ-1** | Documents **inmutables** (snapshot histórico, no edit). `archived_at IS NOT NULL` semantics. | ⏳ Documents V2 |
| **FQ-2** | Sign/Approve documents vía **Decisions** (`request_decision` template `document_approval`/`document_signing`). NO en R.5Y. | ⏳ Post-Documents V2, probable R.6+ |
| **FQ-3** | Document status: `archived_at` bool basta. Sin enum lifecycle. | ⏳ Documents V2 |
| **FQ-4** | Versions = **nuevo documento + `supersedes` relation**. OCR P3 (no ahora). | ⏳ Documents V2 |
| **P1-04** | Attention scope: **CROSS-CONTEXT** (Global → Context). | ✅ shipped (R.5Y.A1/A2) |
| **P2-03** | NO `ConflictDetailView` dedicada. Dialog inline de R.5B.5b es correcto. Esperar R.6. | ✅ confirmado en R.5Y.A2 dispatcher |
| **P1-11** | Resource subtype picker SÍ P1 alto. Arquitectura ya depende de class/subtype/capabilities/sections/widgets. | ⏳ siguiente post-Documents V2 |

### R.5W — User Decision Tree

| ID | Decisión | Cuándo |
|---|---|---|
| **INC-1** | `cancel_decision` debe tener dialog propio (no reusar `close_decision`) | ⏳ R.5W.fix.cancel_decision_dialog |
| **INC-2** | Roles section "Editable próximamente" → disabled row honesta (no label suelto) | ⏳ R.5W.fix.roles_section_honest_disabled |
| **INC-3** | Regular reservation row tap → push ReservationDetail (simetría con conflict row) | ⏳ R.5W.fix.reservation_row_push |

### R.5Y — Attention Center

| ID | Decisión | Cuándo |
|---|---|---|
| **AC-1** | `AttentionDispatcher` es el ÚNICO punto de navegación por attention item. Cualquier kind futuro (rule_violation, policy_violation, maintenance_due, document_expiring) NO toca pantallas — solo extender el dispatcher. | ✅ shipped (R.5Y.A2) |
| **AC-2** | `rule_violation` deferred a R.6 (tabla `rule_violations` no existe aún). El dispatcher tiene `.unsupported(kind)` fallback graceful. | ⏳ R.6 lo añade |

---

## 5. Backlog consolidado (lo que queda)

### P0 (bloqueante demo)

Cero. Los 3 P0 (mapper + obligation + emit canonical) están shipped.

### P1 (siguiente cohort)

| ID | Slice | Source audit | Founder ack |
|---|---|---|---|
| P1-01 | **Documents V2** — `DocumentsListView` + `DocumentDetailView` + QuickLook + `listContextDocuments` RPC + DocumentsStore extension + 5 wire-ups + `archive_document` RPC + `supersedes` relation seedeada | R.5X | ✅ |
| P1-11 | **Resource Subtype Picker** | R.5X | ✅ |
| P1-04 (parcial) | `rule_violation` kind nuevo en `attention_inbox` | R.5Y → R.6 | ✅ (deferred) |
| INC-1/2/3 | R.5W.fix.* (3 cosméticos UX) | R.5W | ✅ |

### P2 (cleanup pre-R.6, no bloqueante)

| ID | Item |
|---|---|
| P2-cap | 6 capabilities ⚪ NO_EFFECT (`approval_required/depreciable/monetary/rentable/sellable/usable`) — cleanup catalog |
| P2-widgets | 7 widgets Resource INERT + 3 widgets Context INERT (5 con destino genérico, 2 sin) |
| P2-sections | 44 section rows Resource INERT (catalog seedea, UI no expone destino) |
| P2-state | Resource `inactive` ORPHAN (badge UI nunca renderiza) · EventDetailView SIN actions (close_event/edit_event MISSING) |
| P2-nav | Settlement batch header tap · ReservationsList swipe feedback toast · SettlementView currency Picker |

### P3 (optimización post-R.6)

| ID | Item |
|---|---|
| P3-helper | Helper API sin uso: `Descriptor.has()/.section()/.action()` |
| P3-jsonvalue | JSONValue holdouts HIGH RISK: `linkedEvents/linkedObligations/linkedDecisions` parsed inline; `membership/context` opaque |
| P3-dormant | Dormant descriptor fields: `metrics.balance/lastMovementAt`, `state.archivedAt/lockedForGovernance/openDecisionId`, `eventsPreview/decisionsPreview` |

---

## 6. Cierre conditions para R.6

R.6 Rule Engine 2.0 arranca cuando los 5 puntos siguientes están cerrados:

| # | Condición | Status |
|---|---|---|
| 1 | 3 P0 shipped + 2 R.5Y backend/iOS shipped | ✅ |
| 2 | Documents V2 shipped (siguiente) | ⏳ |
| 3 | Resource Subtype Picker shipped | ⏳ |
| 4 | R.5W.fix.* (3 P1 cosméticos) shipped | ⏳ |
| 5 | Smoke device founder firmado: "el producto es honesto, predecible, atención consolidada" | ⏳ |

P2/P3 NO bloquean R.6 — pueden ejecutar post-R.6 o en paralelo si surgen oportunidades.

---

## 7. Referencias

| Documento | Función |
|---|---|
| `Plans/Reports/R5X_AuditMatrix.md` | Matriz R.5X — 12 audits, capabilities/sections/widgets coverage, founder flows |
| `Plans/Reports/R5W_UserDecisionTreeMatrix.md` | Matriz R.5W — 275 decision nodes inventariados, listas derivadas |
| `Plans/Archive/R5X_ProductCompletenessAudit.md` | Plan original R.5X (histórico) |
| `Plans/Archive/R5Y_AttentionCenter.md` | Plan original R.5Y (histórico) |
| `Plans/Archive/R5W_UserDecisionTreeConsistency.md` | Plan original R.5W (histórico) |
| **Memorias activas:** |  |
| `project_r5x_CLOSED.md` · `project_r5x_fix_a/b/c_shipped.md` | R.5X audit + 3 P0 |
| `project_r5x_founder_signed_full_backlog.md` | Founder decisions completas |
| `project_r5y_a1_shipped.md` · `project_r5y_a2_shipped.md` | Attention Center |
| **Doctrina founder (CLAUDE.md):** | Triada inmutable Actor/Context/Resource · descriptor-driven · backend = autoridad |

---

## 8. Doctrina founder consolidada (single-source)

1. **Backend = autoridad.** UI sólo presenta + enruta.
2. **Triada Actor/Context/Resource lockeada.** No introducir `entity` ni fusionar.
3. **Descriptor-driven render.** No hardcode por subtype en iOS.
4. **`available_actions[]` autoritativa.** iOS NO inventa acciones.
5. **`execute_resource_action` único dispatcher backend** para actions del catalog.
6. **`AttentionDispatcher` único punto de navegación** por attention item presente o futuro.
7. **Permission chain `descriptor.actions[].enabled → UI .disabled() → RPC SECURITY DEFINER gate`.** Nunca botón fantasma.
8. **Errores backend nunca llegan crudos.** `RPCErrorMapper` los traduce a `UserFacingError`. `0A000/not_implemented` → "Próximamente".
9. **Activity events:** backend autoritativo. iOS no emite.
10. **Documents inmutables**, versions = nuevo doc + `supersedes`.

---

## 9. Próxima acción

**Documents V2.** Plan detallado se redacta al inicio del slice. Estructura tentativa:

- Mig backend: `archive_document` RPC SECURITY DEFINER (FQ-1).
- iOS RPC client: `listContextDocuments(contextId:)`.
- iOS store: `DocumentsStore.loadContextDocuments(contextId:)`.
- iOS Domain: `Document` ya existe (119 LOC), `LinkedDocument` ya existe en `ResourceDetailDescriptor`.
- iOS views nuevas:
  - `ContextDocumentsListView` (~150 LOC)
  - `DocumentDetailView` (~200 LOC) con QuickLook embebido vía `.quickLookPreview($url)`
  - `ResourceLinkedDocumentsCard` (subview en ResourceDetailViewV2 — render `descriptor.linkedDocuments`)
- Wire-ups:
  - `ContextDetailViewV2.swift:1144` — cambiar `case "documents": ActivityFeedView(...)` → `ContextDocumentsListView`
  - `ResourceDetailViewV2.swift` — agregar `linkedDocumentsCard` antes de activityCard
  - `widget destination` para `document_status` widget
  - `ContextHomeView` v1 espejo
  - `ActivityFeedView` deep-link en `document.created` events
- `supersedes` relation: agregar `supersedes` al catalog `resource_relations` (seed).
- Versions UI: en DocumentDetailView, listar documentos con `supersedes` apuntando al doc actual.
- Status badge: derivado de `archived_at IS NOT NULL`.

Quedo listo para arrancar Documents V2 cuando firmes el plan.
