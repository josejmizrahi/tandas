# R.5X — Product Completeness Audit

**Fecha inicio:** 2026-06-07
**Fecha cierre:** 2026-06-07 (kickoff + cierre el mismo día)
**Status:** ✅ **CLOSED** — 12 audits + matriz + backlog firmado + 3 P0 shipped (fix.A mapper · fix.B intent.obligation · fix.C document.created canonical). R.5Y stub creado.
**Próximo:** R.5Y Attention Center (orden congelado founder).
**Companion:** `Plans/Active/R5Y_AttentionCenter.md` (stub) · `Plans/Reports/R5X_AuditMatrix.md` (matriz operativa fuente única R.6)

---

## Hallazgo macro Batch 1 (founder decisión pendiente)

**El catalog de actions creció a 88 (no 90), pero `resource_action_dispatch` sólo wirea 16.** Las 72 actions restantes son visibles en el ResourceDetailViewV2 (vía `descriptor.actions[]`), tienen `form_schema` válido, pasan el gate `enabled` del backend, y abren correctamente el `ResourceActionFormView` runtime. **Pero al submit, el dispatcher backend B.8 raise `0A000 not_implemented`.**

iOS hoy promete "intent-first": cualquier acción visible es ejecutable. Esa promesa se rompe al 18% real.

### Caminos posibles (founder elige)

| Opción | Trade-off |
|---|---|
| **A — Ampliar dispatch backend** a las 72 restantes | Desvía meses. Founder ❌ |
| **B — Ocultar UI las actions sin dispatch** | Destruye visión del producto. Founder ❌ |
| **C — Marcar UI "Próximamente"** (greyed, gated por campo backend) | Compromiso. Catalog visible, expectativa correcta. Founder ✅ **post-R.6** |
| **D — Mensaje "Próximamente" en alert post-submit** | Menos invasivo. Backend ya raises — mapper `0A000 → UserFacingError`. Founder ✅ **ahora R.5X** |

### ✅ P0-01 FIRMADA (founder 2026-06-07): **D + C combinado**

**Ahora (R.5X):** `RPCErrorMapper` traduce `0A000 / not_implemented / rpc missing` → "Esta funcionalidad ya está modelada en Ruul pero todavía no está disponible." Nunca string técnico al usuario.

**Post-R.6 (C):** campo `resource_action_dispatch.is_implemented` (o lectura del mapping) → iOS pinta badge "Próximamente" greyed en actions sin dispatcher.

Slice iOS R.5X.fix.A: 1 cambio en `RPCErrorMapper` + tests. Cero backend.

---

## Hallazgo macro Batch 2 (Documents subsystem)

Confirmado el "deuda evidente" del founder:

| Capa | Estado | Gap |
|---|---|---|
| Backend tabla `documents` | ✅ 16 cols, FKs, archived_at soft-delete, RLS, Storage bucket privado 50MB | — |
| RPCs CRUD | 🟡 1/7 wired (`register_document`); 6 RPCs faltan (`list_context_documents`, `archive_document`, `sign_document`, `approve_document`, `request_approval`, `upload_new_version`) | **P1** |
| Activity events | 🟡 `document.created` en catalog vs `document.registered` emitido por register_document — **DRIFT** | **P0 trivial** |
| Action catalog | 🟡 11 actions documents; sólo 2 (`attach_document`, `upload_document`) tienen dispatch RPC | depende de P0-01 |
| RLS | 🟡 select OK, NO UPDATE/DELETE policy (immutable v1 doctrina) | founder Q |
| iOS Domain | ✅ `Document.swift` 119 LOC + `LinkedDocument` + `ContextDocumentPreview` | — |
| iOS RPC client | 🟡 4 métodos; falta `listContextDocuments` mínimo | **P1** |
| iOS Store | 🟡 `DocumentsStore` 79 LOC; falta `loadContextDocuments` mínimo | **P1** |
| `AttachDocumentView` | ✅ 210 LOC, reusado por ResourceV2 + CreateIntentSheet | — |
| **`DocumentsListView`** | ❌ NO EXISTE — ContextV2 fallback a ActivityFeedView | **P1** founder-priority |
| **`DocumentDetailView`** | ❌ NO EXISTE — `descriptor.linkedDocuments` decoda pero NO renderiza | **P1** founder-priority |
| QuickLook | ❌ NO integrado — `.quickLookPreview($url)` nativo desde iOS 15 disponible | **P1** founder-priority |

### Decisión founder pendiente — Documents v2

| Pregunta | Recomendación temporal |
|---|---|
| ¿Documents `immutable v1` se queda o abrimos archive/delete? | **Open archive** vía nuevo RPC `archive_document` SECURITY DEFINER (soft delete con `archived_at`). Los blobs en Storage permanecen (cumple v1); fila se marca archived. Botón `archive_document` deja de ser fantasma. |
| ¿Sign/approve viven inline o via Decisions? | **Vía Decisions** (`request_decision` template `document_approval`/`document_signing`) — espejo de `transfer_ownership` de R.5A.B.8. Consistente con doctrina governance. |
| ¿Versions = `parent_document_id` o tabla aparte? | **Deferred** post-R.6. v1 immutable lo cubre. Catalog `upload_new_version` queda como "Próximamente" hasta firma. |

---

## Hallazgo macro Batch 2 (Descriptor consumption fino)

**Resource Descriptor — dead/dormant fields:**
- `linkedDocuments[]` ❌ DEAD (struct existe, ZERO usage UI). Confirmaría documents gap.
- `state.archivedAt`, `state.lockedForGovernance`, `state.openDecisionId` — dormant (UX value sin uso)
- `metrics.balance`, `metrics.lastMovementAt` — dormant (low-hanging UX)
- `rights[]` — v1 legacy only, v2 no lo usa
- `relations.resourceId` — nunca accedido

**Context Descriptor — dead/dormant fields:**
- `documentsPreview[]` ❌ DEAD (confirmado, struct presente, zero UI calls)
- `eventsPreview[]` — dormant (no surface en ningún tab)
- `decisionsPreview[]` — dormant
- `membership` JSONValue — nunca accedido (HIGH RISK opaque)
- `roles[].description` — dormant
- `metrics.balanceByCurrency` — dormant, posible duplicado de `moneyPreview.myBalanceByCurrency`

**JSONValue holdouts HIGH RISK:**
- `linkedEvents/linkedObligations/linkedDecisions[]` parseados manualmente en View → frágil ante cambios shape backend
- `context` opaque (sólo 2 keys hard-coded extraídos)
- `membership` opaque nunca accedido (¿cuál era la intención?)

**Helper API sin uso (typed accessors):**
- `ResourceDetailDescriptor.has()`, `.section()`, `.action()` — definidos, never called en V2 (usa array loop directo)
- `ContextDetailDescriptor.has()`, `.section()` — never called

---

## Hallazgo macro Batch 2 (State Coverage)

**Backend states reales por entidad:**

| Entity | Backend states | iOS visible | Gap |
|---|---|---|---|
| Context | 3 (active/inactive/archived) | 0 badge UI (usa bool `is_context_archived`) | 🟡 **P2** (badge en lista) |
| Resource | 3 (active/inactive/archived) | 2 (active/archived); **`inactive` ORPHANED** | 🔴 **P1** |
| Decision | 5 | 5 ✅ | — |
| Reservation | 7 | 7 ✅ | — |
| Obligation | 9 | 9 ✅ | — |
| Conflict | 4 | 2 visible + 2 historical (by design R.5B `includeResolved=false`) | — |
| Document | ❌ NO status field | n/a | founder Q (lifecycle?) |
| Event | 4 | 4 badge ✅ pero **EventDetailView sin actions** | 🟡 **P1** (close_event/edit_event MISSING UI) |

**One-way transitions sin undo:**
- Resource archived → restore_resource (catalog OK; dispatch wired) — verificar UI muestra restore
- Obligation completed → no reverse (catalog: no action `reopen_obligation`)
- Reservation cancelled → no reverse
- Conflict resolved/dismissed → no reverse (R.5B intencional)
- Event cancelled → UNK

---

## Hallazgo macro Batch 2 (Permission chain) — 🟢 LOW RISK

Auditoría confirma la doctrina "backend = autoridad":

- ✅ `descriptor.actions[].enabled` honrado consistentemente con `.disabled()` en UI (ResourceV2:471, ContextV2:1112)
- ✅ `action.reason` se muestra cuando disabled (ResourceV2:525-528)
- ✅ Sheets nativos (`GrantRightSheet`, `AttachDocumentView`, `EditResourceView`) sólo abren vía `handleActionTap` que ya validó
- ✅ 6/6 RPCs SECURITY DEFINER auditados tienen gate explícito (`has_actor_authority`, `actor_has_right`, `_can_manage_reservations`)
- ✅ `descriptor.permissions[]` correctamente usado como info-only (chips More tab), NO como gate
- ✅ `MembersListView` invite gateado por `store.canInvite()`
- ✅ **0 botones fantasma detectados**

**Estado del permission chain: 🟢 SOLID** — no genera P0/P1. R.6 puede asumir esta cadena para Rule Engine.

---

## Objetivo

Antes de iniciar R.6 Rule Engine 2.0, encontrar **todas las brechas** entre lo que el backend Ruul MVP 2.0 produce y lo que la UI iOS realmente expone, en doce dimensiones:

```
Backend  ·  Descriptors  ·  RPCs  ·  Actions  ·  Capabilities
Sections ·  Widgets      ·  Navigation  ·  UX  ·  UI
```

**NO se agregan features.** Sólo se levantan brechas:

- Existe backend pero no UI.
- Existe UI pero no backend.
- Existe descriptor pero no render.
- Existe acción pero no acceso.
- Existe capability pero no comportamiento.
- Existe sección pero no pantalla.
- Existe dato pero no flujo.
- Existe navegación muerta.
- Existe estado sin tratamiento.

---

## Reglas

1. **No modificar arquitectura.** R.5A foundation está lockeada (descriptor-driven Resource + Context).
2. **No agregar nuevas tablas.**
3. **No crear nuevos sistemas.**
4. **Auditar → Priorizar → Ejecutar** (en ese orden, sin atajos).
5. **Backend = autoridad.** Si el descriptor expone algo, la UI debe consumirlo o documentarse como UNUSED. Si la UI muestra algo, debe venir del descriptor / RPC vivo, no de hardcode.
6. **Honestidad UX.** Una sección que existe pero no carga datos vale menos que no tener la sección. Las inerts se documentan y se priorizan: convertir en COMPLETE o degradar a `display_only` / removerlas del subtype mapping.

---

## Deliverables

| Documento | Función |
|---|---|
| `Plans/Active/R5X_ProductCompletenessAudit.md` (este) | Metodología, hallazgos cualitativos por audit, decisiones, backlog priorizado final |
| `Plans/Reports/R5X_AuditMatrix.md` | Matriz operativa fila por fila (Domain · Feature · Backend · Descriptor · UI · Navigation · Actions · Permissions · Status · Priority) — fuente única para R.6 |

---

## Metodología

Cada auditoría sigue el mismo shape:

```
1. Inventario  ─── qué expone el backend / catalog
2. Cobertura UI ── qué consume iOS hoy
3. Brecha       ── delta (con file:line refs)
4. Clasificación ─ COMPLETE | PARTIAL | INERT | MISSING | ORPHANED | BROKEN | NO_EFFECT
5. Priorización  ─ P0 (roto) | P1 (incompleto) | P2 (UX) | P3 (optimización)
```

### Clasificación canónica

| Status | Significado |
|---|---|
| **COMPLETE** | Existe en backend Y en UI Y conecta extremo-a-extremo (loading/empty/error states incluidos) |
| **PARTIAL** | Existe en ambos lados pero algún edge case falta (estado, navegación, error, permiso) |
| **INERT** | Existe en UI (sección, widget, action row) pero no carga datos / no navega / no ejecuta |
| **MISSING** | Existe en backend pero la UI no lo expone |
| **ORPHANED** | Existe en UI pero el backend ya no lo respalda (RPC muerto, campo deprecado) |
| **BROKEN** | Estaba COMPLETE y dejó de funcionar (regresión confirmada) |
| **NO_EFFECT** | Existe el catálogo (capability/section/widget/action) pero ningún subtype lo usa O ningún flow real lo dispara |

### Prioridad

| Prio | Criterio | Ejemplo |
|---|---|---|
| **P0** | Roto end-to-end. El founder puede chocar con esto en demo. | Action visible que rompe, navegación que crashea, attention vacía |
| **P1** | Incompleto pero no roto. Camino dorado funciona, pero edge case visible falla. | Empty state ausente, descriptor key con render parcial |
| **P2** | UX. Existe pero no es claro / no es honesto / no escala. | Inert section que parece interactiva, doble navegación, copy ambiguo |
| **P3** | Optimización. Mejora de codigo, perf, refactor sin user-impact directo. | Code dedupe, descriptor field unused (cleanup) |

---

## Las 12 Auditorías

Cada una se detalla más abajo. Estado actual entre paréntesis.

| # | Audit | Owner-side | Status |
|---|---|---|---|
| 1 | Context Detail (5 tabs) | iOS + descriptor B.7 | ✅ Batch 1 cerrado · 10 🟢 · 1 ⚠️ |
| 2 | Resource Detail (subtypes founder) | iOS + descriptor B.6 | 🟡 Batch 1 cerrado · 8/8 PARTIAL (bloqueado por Audit 3) |
| 3 | Action Coverage (catalog ↔ UI) | Backend catalog + iOS handlers | 🟡 Batch 1 cerrado · 16/88 COMPLETE · 72/88 PARTIAL (rojo macro) |
| 4 | Capability Coverage | Backend catalog + iOS gates | 🟡 Batch 1 parcial · 6 ⚪ NO_EFFECT · 36 ❓ Batch 2 |
| 5 | Section Coverage (resource + context) | Backend catalog + iOS sections | 🟡 Batch 1 cerrado · R 7🟢/4🟡/37⚠️ · C 10🟢/1⚠️ |
| 6 | Widget Coverage (resource + context) | Backend catalog + iOS widgets | 🟡 Batch 1 cerrado · R 10🟢/1🟡/7⚠️ · C 10🟢/2🟡/1⚠️ |
| 7 | Descriptor Coverage (unused fields) | descriptor B.6/B.7 outputs | 🟡 Batch 1 parcial · `documents_preview` ⬛ MISSING · 4 ❓ Batch 2 |
| 8 | Navigation Audit (dead-ends) | iOS routes | ✅ Batch 1 cerrado · 11 dead-ends inventariados |
| 9 | Founder Flows (familia/casa/viaje/empresa) | end-to-end | ⚪ PENDIENTE (Batch 3) — preliminar 2🟢/1🟡/1🔴 |
| 10 | Attention System (consolidación) | attention_inbox + ContextHome/ContextDetail | 🟡 Batch 1 cerrado · 3🟢/2🟡/2⬛ (Settlements + Rules MISSING) |
| 11 | State Coverage (active/archived/cancelled/…) | UI badges + transitions | ⚪ PENDIENTE (Batch 2) |
| 12 | Permission Audit (descriptor ↔ RPC ↔ UI) | gate chain | ⚪ PENDIENTE (Batch 2) |

---

## Batches de ejecución

Para no quemar contexto y mantener fidelidad, la auditoría se ejecuta en 3 batches:

### Batch 1 — Inventario base (en curso)

Objetivo: levantar todos los inventarios "fríos" sin sintetizar.

- **B1.a** Backend catalogs dump (action_catalog · capabilities · sections · widgets · subtypes · descriptor RPC shapes)
- **B1.b** Context Detail iOS surface (ContextDetailViewV2 tabs Overview/People/Resources/Money/More) — qué renderiza, qué carga, qué states maneja
- **B1.c** Resource Detail iOS surface (ResourceDetailViewV2 hero + widgets + sections + actions + relations + activity) — descriptor consumption
- **B1.d** Navigation graph (router dispatches, ContextHomeView dispatches, attention dispatches, sheet items, NavigationLinks legacy)

Resultado: matriz inicial con filas pobladas hasta columna `UI` (status preliminar).

### Batch 2 — Cobertura cruzada

Objetivo: sobre el inventario base, cruzar catalog ↔ UI.

- **B2.a** Capability coverage (audit 4)
- **B2.b** Section coverage resource + context (audit 5)
- **B2.c** Widget coverage resource + context (audit 6)
- **B2.d** Descriptor coverage / unused fields (audit 7)
- **B2.e** State coverage (audit 11)
- **B2.f** Permission audit (audit 12)

Resultado: matriz completa con status + razón. Sin prioridad aún.

### Batch 3 — End-to-end + síntesis

Objetivo: validar lo levantado vía 2 lentes founder + cerrar matriz.

- **B3.a** Founder flows familia / casa / viaje / empresa (audit 9)
- **B3.b** Attention system consolidación (audit 10)
- **B3.c** Priorización P0–P3 + backlog para R.5X.fix.* slices (pre-R.6)

Resultado: backlog firmable. R.6 desbloqueada cuando todos los P0 cierran.

---

## Audit 1 — Context Detail

Source: `ContextDetailViewV2` + `ContextDescriptorStore` + `context_detail_descriptor` RPC.

Catálogo real (corregido): **11 sections** (`overview · people · resources · calendar · governance · obligations · activity · documents · money · conflicts · settings`).

### Hallazgos

- **Tabs dinámicos:** 5 segmentos (Overview/People/Resources/Money/More) se filtran por `descriptor.sections[].visible` (`ContextDetailViewV2.swift:186-190`). Tabs sin secciones no aparecen.
- **10/11 sections en surface concreto.** Cobertura matriz en `R5X_AuditMatrix.md` §Audit 1.
- **`documents` ⚠️ INERT:** More row tappable abre `ActivityFeedView` como fallback porque no existe `DocumentsListView`. UX deshonesto.
- **Refresh:** all-or-nothing (`store.load`); excepción: `loadContextConflictsIfNeeded()` lazy + `reloadContextConflicts()` post-resolve. No hay refresh granular por sección.
- **Empty/loading/error en Overview:** Loading ✅, Error ✅, Empty ❌ (Overview asume cards-with-fallback en lugar de un empty state propio si TODO está vacío).
- **Quick actions toolbar:** 7 wired (`create_resource`, `create_event`, `create_decision`, `record_expense`, `invite_member`, `create_rule`, `create_child_context`). Cualquier otra action devuelta por `context_available_actions` cae a `default: break` (handler no-op) — **P1**.

## Audit 2 — Resource Detail

Source: `ResourceDetailViewV2` + `ResourceDescriptorStore` + `resource_detail_descriptor` RPC.

**Corrección founder canon:** `vehicle` no existe como `resource_subtype_key`; el backend tiene `car`. Cuando el founder dice "vehicle" se refiere a `car`. Auditar como `car`.

### Hallazgos

- **100% data-driven:** ResourceDetailV2 NO hardcodea SF Symbols ni branding por subtype. El render se calcula desde `descriptor.subtype.icon`, `descriptor.class`, `descriptor.widgets[]`, `descriptor.sections[]`, etc. Esto es la promesa R.5A intacta.
- **8/8 subtypes founder canon en PARTIAL** — el bottleneck es transversal: 72 actions sin RPC backend (Audit 3) + 7 widgets sin destino (Audit 6) + 37 sections sin destino dedicado (Audit 5).
- **Por subtype** ver matriz §Audit 2. La fila más crítica es `money_pool` para flow viaje (Audit 9): `record_contribution` y `convert_to_settlement` NO están en B.8 dispatch → si user las invoca, el alert error es genérico.
- **Sheets nativos en V2:** `grant_right`, `attach_document`, `edit_resource`/`update_resource`. **`revoke_right` no tiene sheet propio** (cae a runtime form) — gap menor pero es la inversa de un sheet existente.
- **ConflictsModifier ViewModifier** aislado fuera de body (memoria del 2026-06-07 confirma decisión por type-checker timeout). 🟢.

## Audit 3 — Action Coverage

Source: `resource_action_catalog` (**88** acciones, no 90) + `resource_action_dispatch` (**16** RPC mappings B.8) + iOS `handleActionTap` interceptores (`ResourceDetailViewV2.swift:489-500`).

### Hallazgos

- **Sumario:** 16 🟢 COMPLETE · 72 🟡 PARTIAL · 0 ORPHANED · 0 MISSING. Coverage = **18.2%**.
- **88/88 forms con `form_schema`** (B.5b 100%). El form_schema funciona, lo que falla es el dispatch.
- **16 RPC vivos cableados:** ver `R5X_AuditMatrix.md` §Audit 3 y crudo en `resource_action_dispatch`.
- **72 actions sin dispatch raise `0A000 not_implemented`** desde `execute_resource_action`. iOS muestra alert error genérico (sin contextualización "próximamente vs roto").
- **Acciones founder-priority sin RPC:** `record_contribution`, `convert_to_settlement`, `dispute_obligation`, `record_payment`, `accept_obligation`, `complete_obligation`, `log_maintenance`, `record_insurance`, `record_tax_payment`, `update_valuation`, `record_lease_income`, `create_lease`, `terminate_lease`, `approve_document`, `sign_document`, `request_approval`, etc.
- **Sheets nativos iOS** cubren 4 actions específicas (`grant_right`, `attach_document`, `edit_resource`, `update_resource`) que SÍ tienen RPC vivo.

## Audit 4 — Capability Coverage

Source: `resource_capabilities_catalog` (42 caps post R.5A.B.2) + `resource_subtype_capabilities` defaults + `effective_resource_capabilities` RPC + UI gates.

Ejemplo `reservable`:
```
debe tener: availability · calendar · reservations · conflicts · actions
```

Cada capability key:
```
IMPLEMENTED  — descriptor inyecta → UI cambia render → acciones aparecen
PARTIAL      — descriptor inyecta pero no afecta UI o sólo afecta una de varias surfaces
NO_EFFECT    — no cambia nada visible (cap fantasma)
```

## Audit 5 — Section Coverage

Source: `resource_section_catalog` (47) + `context_section_catalog` (10) + sus subtype mappings.

Atención prioritaria (secciones específicas que sospechamos inerts):
`maintenance · insurance · taxes · valuation · leases · condition · inventory_movements · custody · income · payments`.

Por section key:
```
IMPLEMENTED · PARTIAL · INERT
```

## Audit 6 — Widget Coverage

Source: `resource_dashboard_widgets` (17) + `context_dashboard_widgets` (12) + subtype mappings + iOS widget renderers + tap → NavigationLink mappings.

```
COMPLETE — backend data + render + tap + drilldown
PARTIAL  — backend o render o tap o drilldown roto
BROKEN   — antes funcionaba y dejó de
```

## Audit 7 — Descriptor Coverage

Source: shape real de `resource_detail_descriptor` (17 top-level keys) + `context_detail_descriptor` (16 keys) ✕ iOS Domain consumption (`ResourceDetailDescriptor` + `ContextDetailDescriptor`).

Output: lista `unused_descriptor_fields[]` por descriptor.

## Audit 8 — Navigation Audit

### Hallazgos (11 dead-ends inventariados)

| Source | Destino esperado | Estado actual | Prio |
|---|---|---|---|
| `documents_preview` rows | DocumentDetailView / QuickLook | No existe; fallback ActivityFeedView | **P1** |
| Conflict individual ("Ver detalle") | ConflictDetailView | No existe; dialog inline resuelve, pero no detail dedicado | **P2** |
| Child contexts card (outsider) | Membership request / disclaimer | `.opacity(0.5)` sin error/CTA | **P1** |
| Attention `reservation_conflict` | ReservationConflictView (ARCHIVO EXISTE en /Reservations/) | Salta a context home; ningún row puente abre la view | **P1** |
| Attention `settlement` | SettlementView | NO dispatched (cae a EmptyView) | **P1** |
| Attention `rule_*` | RuleDetailView | NO dispatched | **P1** |
| Resource widget tap (`document_status`, `insurance_status`, `maintenance_status`, `tax_status`, `condition_status`, `custody_status`, `resource_value`) | Section dedicada | `tappable: false` cascade | **P1** (×6) / **P2** (×1) |
| Resource section row (44/48) | Section dedicada | Row plana sin chevron | **P1** founder-priority (×11) / **P2-P3** resto |
| `roles[]` row Context People tab V2 | MembersListView filtered | NO push (V1 sí) | **P2** |
| Context widget `active_projects` | Lista proyectos del contexto | Sin destino | **P2** |
| Context quick action no-listed (8º+) | Dispatch handler | `default: break` | **P1** |

## Audit 9 — Founder Flows

Cuatro flujos end-to-end (clic-por-clic):

```
Familia   :  crear familia · invitar miembro · registrar gasto · generar settlement
Casa      :  crear casa · agregar documento · reservar · resolver conflicto
Viaje     :  crear viaje · agregar participantes · crear fondo · registrar gastos · liquidar
Empresa   :  crear empresa · crear recurso · crear obligación · crear decisión
```

Por flujo:
```
clics totales · pantallas vacías encontradas · errores · acciones ocultas · navegación rota
```

## Audit 10 — Attention System

### Hallazgos preliminares Batch 1 (cierre final en Batch 3)

| Categoría | HomeView (cross) | ContextDetailV2 | ContextHome v1 | Verdict | Prio |
|---|---|---|---|---|---|
| Invitations | ✅ | ✅ | ✅ | 🟢 VISIBLE | — |
| Decisions (vote) | ✅ | ✅ | ✅ | 🟢 VISIBLE | — |
| Obligations (pay/complete) | ✅ | ✅ | ✅ | 🟢 VISIBLE | — |
| Reservation conflicts | 🟡 (salta contexto, no detail) | 🟡 (lista) | 🟡 (lista) | 🟡 PARCIAL | **P1** |
| Resource conflicts (R.5B direct) | ⬛ | ✅ via card local | ✅ via card local | 🟡 PARCIAL | **P2** |
| Settlements | ⬛ | ⬛ | ⬛ | ⬛ NO_VISIBLE | **P1** |
| Rules / Rule violations | ⬛ | ⬛ | ⬛ | ⬛ NO_VISIBLE | **P1** |

**Conclusión:** la pregunta clave del founder ("¿qué requiere atención hoy?") sólo responde 3 de 7 categorías de forma cross-context. Settlements y Rules deben aparecer en `attention_inbox` del backend antes de R.6.

## Audit 11 — State Coverage

Por entidad principal (`Context · Resource · Decision · Reservation · Obligation · Conflict · Document · Event`) y cada state (`active · inactive · archived · cancelled · completed · rejected · expired · disputed`):

```
UI badge · actions válidas para el estado · actions inválidas escondidas · transitions visibles
```

## Audit 12 — Permission Audit

Confirmar la cadena:
```
descriptor.permissions[] (B.7) / descriptor.rights+actions[].enabled (B.6)
        ↓
UI gate (button enabled/disabled, action visible)
        ↓
RPC enforcement (has_actor_authority / actor_has_permission)
```

Reglas:
- No botón fantasma (visible sin permiso).
- No acción enabled sin enforcement backend.
- No RPC ejecutable sin gate (ya validado por R.5A.B.8 — confirmar muestra).

---

## Backlog priorizado FINAL (post Batch 1 + 2 + 3)

> Slice IDs asignados. Listo para founder firma final.

### P0 — Roto end-to-end / demo-blocker (3)

| ID | Audit | Finding | Slice | Ack |
|---|---|---|---|---|
| P0-01 | 3 | 72/88 actions visibles raise `0A000` al ejecutar | **R.5X.fix.A** ✅ **SHIPPED 2026-06-07** build verde 10.4s. `BackendError.notImplemented(actionKey:)` + copy founder-signed + 6 tests. | ✅ |
| P0-02 | 9 | Flow 4 Empresa BLOQUEADO: `intent.obligation` NO existe en CreateIntentSheet | **R.5X.fix.B** ✅ **SHIPPED 2026-06-07** build verde 6.8s. Row "Asignar compromiso" + FormDestination case → CreateObligationView nativo. | ✅ |
| P0-03 | docs | Activity catalog/emit DRIFT: catalog `document.created` vs emit `document.registered` (parcialmente falso — `_emit_activity` mapper interno ya cubría; 6 rows live tenían `document.created`) | **R.5X.fix.C** ✅ **SHIPPED 2026-06-07** mig `r5x_fix_c_register_document_canonical_emit`. `register_document` ahora emite canonical directo. | ✅ |

### P1 — Incompleto (≈14)

| ID | Audit | Finding | Slice | Ack |
|---|---|---|---|---|
| P1-01 | 1, 7, docs | `DocumentsListView` + `DocumentDetailView` NO existen; `descriptor.linkedDocuments`/`documentsPreview` dead; QuickLook no integrado | **R.5X.fix.docs** — 3 views nuevas + `listContextDocuments` RPC client + DocumentsStore extension + 5 wire-ups (ContextV2:1144, ResourceV2:188, widget destination, ContextHome v1, Activity tap deep-link) | ⏳ |
| P1-02 | 5 | 11 sections Resource founder-priority INERT | R.5X.fix.sections — placeholder views con "Próximamente" honesto o subview embebido | ⏳ |
| P1-03 | 6 | 7 widgets Resource INERT (no destino) | R.5X.fix.widgets — mapping widget→section destination + placeholder | ⏳ |
| P1-04 | 10 | `settlement_attention` + `rule_*` MISSING en attention_inbox | **R.5Y.A1** Attention Center backend + iOS dispatch | ⏳ |
| P1-05 | 10 | `reservation_conflict` attention abre lista (no detail); ReservationConflictView existe pero ningún row la abre | R.5Y.A2 — wire row → ReservationConflictView | ⏳ |
| P1-06 | 1, 2 | ContextV2 quick actions `default: break` para 8°+ action | R.5X.fix.quickactions — audit output + ampliar switch | ⏳ |
| P1-07 | 8 | Child contexts outsider `.opacity(0.5)` sin error/CTA | R.5X.fix.childContexts — disclaimer + "Solicitar acceso" CTA | ⏳ |
| P1-08 | 11 | Resource `inactive` state ORPHAN (backend tiene, iOS nunca renderiza) | R.5X.fix.inactive — badge en heroCard | ⏳ |
| P1-09 | 11 | EventDetailView SIN actions (`close_event`/`edit_event` MISSING UI) | R.5X.fix.eventActions — espejo del pattern Obligation | ⏳ |
| P1-10 | 1 | Context `documents` More tab → fallback ActivityFeedView | cierra con P1-01 | — |
| P1-11 | 9 Flow 2 | Resource subtype picker NO existe en CreateResourceView | R.5X.fix.subtypePicker | ⏳ |
| P1-12 | 9 Flow 2 | `ReservationIntentLanding:446-450` filtra resource types HARDCODED → viola Foundation Lock | R.5X.fix.reservableFilter — leer `capability.reservable` del descriptor | ⏳ |
| P1-13 | 9 Flow 3 | EventScope NO populated por CreateIntentSheet/FormDestination → "gasto del evento" roto | R.5X.fix.eventScope — wire scope desde context | ⏳ |
| P1-14 | docs | 6 RPCs documents missing (`list_context_documents`, `archive_document`, `sign_document`, `approve_document`, `request_approval`, `upload_new_version`) | cierra parcial con P1-01 mínimo; sign/approve via `request_decision` (FQ-2); versions deferred (FQ-4) | ⏳ |

### P2 — UX (≈10)

| ID | Audit | Finding | Slice |
|---|---|---|---|
| P2-01 | 2 | `revoke_right` sin sheet propio (cae a runtime form) | `RevokeRightSheet` espejo de `GrantRightSheet` |
| P2-02 | 1 | `roles[]` row Context People V2 NO push (V1 sí) | NavigationLink → MembersListView filtered |
| P2-03 | 8 | Conflict individual "Ver detalle" no existe (dialog inline cubre resolve) | Decidir founder: ¿basta dialog o crear `ConflictDetailView`? |
| P2-04 | 1 | `pending_invitations_preview` More card sin manage inline | Tap row → PendingInvitationsView con highlight |
| P2-05 | 6 | Context widget `active_projects` sin destino | `ResourcesListView` filtered por classKey=internal_project |
| P2-06 | 11 | Context badge archived en lista no se ve | Badge en ContextsListView usando `is_context_archived` |
| P2-07 | 9 | `loadKnownActors` falla silenciosa en InviteMembersView | Surface error visible (no try/catch silencio) |
| P2-08 | 7 | `metrics.balance`+`metrics.lastMovementAt` dormant (UX value); `state.archivedAt/lockedForGovernance/openDecisionId` dormant | Render en heroCard ResourceV2 subtexts |
| P2-09 | 5 | Resource sections 2nd-tier (`access/location/budget/disputes/expenses`) sin destino | Genérica section-list o cleanup catalog mapping |
| P2-10 | 7 | JSONValue holdouts HIGH RISK: `linkedEvents/linkedObligations/linkedDecisions` parsed inline; `membership/context` opaque | Typed structs (defer si bloqueante post-R.6) |

### P3 — Optimización / cleanup (≈7)

| ID | Audit | Finding | Slice |
|---|---|---|---|
| P3-01 | 4 | 6 capabilities catalog ⚪ NO_EFFECT (`approval_required/depreciable/monetary/rentable/sellable/usable`) | Cleanup catalog o seed missing subtype mappings |
| P3-02 | 6 | `conflicts_summary` widget Resource+Context absorbido por conflictsCard (duplicate render) | Filtrar widget cuando card ya lo cubre |
| P3-03 | 5 | Resource sections residuales (`approvals/signatures/versions/tasks/checklist/itinerary/fines/usage_history/stock/recurrence/calendar`) sin destino | Defer-when-needed; documentar como "Próximamente" |
| P3-04 | 7 | Helper API sin uso: `.has()`, `.section()`, `.action()` en descriptors | Eliminar o adoptar consistentemente |
| P3-05 | 1 | Overview ContextV2 sin EmptyState propio | UX si TODOS los cards están vacíos |
| P3-06 | 7 | `roles[].description`, `metrics.balanceByCurrency` dormant (posible dup vs moneyPreview) | Decidir: eliminar del backend o consumir iOS |
| P3-07 | 2 | Resource `rights[]` descriptor — v1 legacy only, v2 ya muestra via heroCard chips | Eliminar de V2 path o documentar |

---

## Decisiones founder (TODAS FIRMADAS 2026-06-07)

1. ✅ **P0-01**: D+C combinado firmado (mapper iOS + badge backend post-R.6).
2. ✅ **P0-02 / P0-03**: aprobados para ship inmediato post-fix.A.
3. ✅ **FQ-1 Documents immutable**: **SÍ**. Documento subido = snapshot histórico, no se edita. (Consecuencia: `archived_at IS NOT NULL` semantics suficiente, sin enum.)
4. ✅ **FQ-2 Sign/Approve**: **NO en R.5Y**. Firma debe pasar por Decision → Approval → Governance. Deferred post-R.5Y.
5. ✅ **FQ-3 Document status**: `archived_at` bool basta (consecuencia de FQ-1).
6. ✅ **FQ-4 Versions**: **SÍ — modelo "nuevo documento + supersedes relation"**. Cada versión es documento distinto; relación `supersedes` vía `resource_relations` o `document_relations` futuro. OCR P3 (no ahora).
7. ✅ **P1-04 Attention scope**: **CROSS-CONTEXT**. Modelo: Global Attention Center → Context Attention. Founder rationale: "el usuario piensa '¿qué requiere mi atención?', no '¿qué requiere atención dentro de este contexto específico?'".
8. ✅ **P2-03 ConflictDetailView**: **NO**. Dialog inline de R.5B.5b es la decisión correcta. Esperar R.6.
9. ✅ **P1-11 Resource subtype picker**: **SÍ P1 alto**. La arquitectura ya depende de class/subtype/capabilities/sections/widgets — no tiene sentido crear recursos sin subtype explícito.

## Orden de ejecución FIRMADO (congelado)

```
1. R.5X.fix.A   — mapper "Próximamente" (RPCErrorMapper)
2. R.5X.fix.B   — intent.obligation en CreateIntentSheet (Flow 4 Empresa unblock)
3. R.5X.fix.C   — activity emit drift document.created ↔ document.registered (1-line backend)
4. R.5Y.A1      — Attention Center Backend (settlement + rule_violation + resource_conflict_direct cross-context)
5. R.5Y.A2      — Attention Center iOS (AttentionDispatcher único + dispatches nuevos)
6. Documents V2 — DocumentsListView + DocumentDetailView + QuickLook + supersedes relation + versions=nuevo doc
7. Resource Subtype Picker — en CreateResourceView
8. R.6 Rule Engine 2.0
```

**Founder cita literal:** "el mayor faltante ya no es backend; es la capa de atención y descubrimiento de problemas."

## Copy oficial del mapper "Próximamente" (R.5X.fix.A)

```
Título:    Próximamente
Mensaje:   Esta funcionalidad ya está modelada en Ruul, pero todavía no está disponible.
Opcional:  Puedes seguir utilizando el resto de las funciones del recurso
           mientras terminamos esta capacidad.
```

**Triggers a mapear** (cualquier match → mensaje arriba):
- `0A000` (PG `feature_not_supported`)
- `not_implemented`
- `action_not_wired`

**NUNCA mostrar al usuario:** `RPC Error`, `0A000`, `Internal Error`, `Not Implemented`, `not_implemented`, `action_not_wired`.

---

## Cierre y handoff (ruta firmada founder 2026-06-07)

```
R.5X Batch 2 (descriptor / state / permissions / capabilities deep)
  ↓
R.5X Batch 3 (founder flows end-to-end + priorización P0–P3 final)
  ↓
R.5X.fix.* slices (D primero — RPCErrorMapper, después P1 founder-priority)
  ↓
R.5Y Attention Center (NUEVO, founder pre-R.6 requirement)
  ↓
R.6 Rule Engine 2.0
```

### Por qué R.5Y entra antes de R.6 (founder rationale)

R.6 va a generar volumen de `conflicts / alerts / violations / recommendations`. Hoy no hay un lugar unificado para verlos. Audit 10 ya confirma:

- `settlement_attention` ⬛ MISSING
- `rule_attention` ⬛ MISSING
- `reservation_conflict` → lista, no detail (🟡)
- `resource_conflict` ⬛ NO surface en attention_inbox cross-context

R.5Y consolida los 7 categorías + dispatch + dedicated `ConflictDetailView`/`RuleAttentionView` antes de que R.6 los infle.

### R.5X CLOSE conditions (cierre 2026-06-07)

| Condición | Status |
|---|---|
| 1. Las 12 auditorías con status final en la matriz | ✅ |
| 2. Backlog completo P0/P1/P2/P3 con slice IDs asignados | ✅ 3 P0 · 14 P1 · 10 P2 · 7 P3 |
| 3. Founder firma orden de ejecución | ✅ 2026-06-07 orden congelado: fix.A → fix.B → fix.C → R.5Y.A1/A2 → Documents V2 → Subtype Picker → R.6 |
| 4. **3/3 P0 shipped** | ✅ fix.A (iOS 10.4s) · fix.B (iOS 6.8s) · fix.C (mig `r5x_fix_c_register_document_canonical_emit`) |
| 5. R.5Y plan (no implementación) escrito | ✅ `Plans/Active/R5Y_AttentionCenter.md` stub creado |

**✅ R.5X CLOSED 2026-06-07** — 5/5 puntos cerrados.

---

## Apéndice A — Discrepancias spec ↔ backend real

| Item | Spec founder prompt | Real backend |
|---|---|---|
| Resource actions | "~90" / "90" | **88** |
| Resource sections | "47" | **48** |
| Context sections | "10" | **11** |
| Resource widgets | "17" | **18** |
| Context widgets | "12" | **13** |
| `vehicle` subtype | esperado | **NO EXISTE** — backend usa `car` |
| `members` section context | esperado | **NO EXISTE** — backend usa `people` |
| Action dispatch wired | "16 mappings" | **16 / 88** confirmado |
| Catalog cols `requires_*` | varias | sólo `required_capability` + `required_rights[]` |
| Capabilities ⚪ NO_EFFECT | n/a | **6** (`approval_required/depreciable/monetary/rentable/sellable/usable`) |
| Documents RPCs | esperado CRUD | **1/7** (`register_document` SECURITY DEFINER, resto missing) |
| Activity event drift | n/a | `document.created` en catalog vs `document.registered` emit |

## Apéndice B — Memorias relacionadas

- `project_r5x_audit_kickoff_founder_decisions.md` (2026-06-07) — kickoff + decisión P0-01 D+C + ruta R.5Y
- `project_r5b_CLOSED.md` (2026-06-07) — Resource Conflict Model end-to-end (referencia para patrón attention)
- `project_r5a_CLOSED.md` (2026-06-07) — Detail Architecture (descriptor-driven base)
