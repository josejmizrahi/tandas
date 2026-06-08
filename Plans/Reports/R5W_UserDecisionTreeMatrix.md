# R.5W — User Decision Tree Matrix

**Fecha:** 2026-06-07
**Status:** ✅ CLOSED — Batch 1 (inventario 275 nodes) + Batch 2 (atributos + clasificación) + Batch 3 (backlog).
**Companion:** `Plans/Active/PreR6_Roadmap.md` (plan consolidado R.5X + R.5Y + R.5W)

---

## Sumario de cobertura

**275 decision nodes inventariados en 12 superficies.** Mayoría 🟢 COMPLETE. Los hallazgos críticos están listados abajo. Los nodes 🟢 NO se enumeran fila por fila (sería ruido — ver R.5X audit + R.5Y A2 memoria para los patrones que los hacen 🟢).

| Superficie | nodes | 🟢 | 🟡 | ⚠️ | ⬛ | 🔴 | Notes |
|---|---|---|---|---|---|---|---|
| S1 HomeView | 6 | 6 | 0 | 0 | 0 | 0 | Atención card / Continuar / "Ver todo" actividad — todos vía AttentionDispatcher post-R.5Y.A2 |
| S2 ContextDetailViewV2 | ~40 | 31 | 1 | 0 | 8 | 0 | 7 quick actions wired + 13 widgets (10 con destino, 3 sin) + 5 More section rows + conflicts dialog |
| S3 ResourceDetailViewV2 | ~50 | 4 | 0 | 0 | 46 | 0 | 7 INERT widgets + 44 INERT sections (P2 cleanup) ya identificados en R.5X |
| S4 AttentionDispatcher | 16 | 16 | 0 | 0 | 0 | 0 | Router 6 kinds + 7 sheet destinations + bootstrap states. Cero deuda futura R.6. |
| S5 CreateResourceView | 5 | 4 | 1 | 0 | 1 | 0 | Subtype picker MISSING (P1-11 R.5X) — `❌ NO subtype picker` |
| S6 Action sheets V2 | ~36 | 36 | 0 | 0 | 0 | 0 | Runtime form 11 field types + 4 sheets nativos. Confirmación dinámica por dangerous/decision/default |
| S7 Native sheets pre-V2 | ~74 | 74 | 0 | 0 | 0 | 0 | Create flows + InviteMembers + JoinByCode + CreateIntentSheet 7 intents (incluye R.5X.fix.B obligation) |
| S8 Conflict dialogs | ~15 | 15 | 0 | 0 | 0 | 0 | ResourceV2 ConflictsModifier 3-kind + Context list view 3-kind + post-resolve alerts. Refresh granular OK. |
| S9 Reservation flows | 18 | 16 | 1 | 1 | 0 | 0 | Conflict resolve 8 modelos. Asimetría rows (conflict pushea, reservation solo swipe). |
| S10 Money flows | 18 | 16 | 1 | 0 | 1 | 0 | Settlement batch header no tappable. Plus menu + hero CTAs OK. |
| S11 Governance flows | 61 | 58 | 0 | 2 | 1 | 0 | `cancel_decision` reusa dialog de `close_decision`. Roles "Editable próximamente" sin botón real. |
| S12 Documents fallbacks | 5 | 4 | 0 | 0 | 1 | 0 | DocumentsListView NO EXISTE (P1-01 R.5X). AttachDocumentView wired. |

**Totales:** 275 nodes · 280 🟢 (cuento dups por integración) · 4 🟡 · 3 ⚠️ · **57 ⬛** (ya catalogados en R.5X) · **0 🔴 UNSAFE**.

---

## Hallazgos críticos (filas con status ≠ 🟢)

### ⚠️ INCONSISTENT (P1)

| screen | decision_node | file:line | finding | slice |
|---|---|---|---|---|
| S11 DecisionDetailView | `cancel_decision` admin action | DecisionDetailView.swift:973 | Action `cancel_decision` route a `isConfirmingClose = true` reusando dialog de `close_decision`. User ve "¿Cerrar votación?" cuando quería cancelar. Backend quirk debe tener su propia confirmación. | R.5W.fix.cancel_decision_dialog |
| S11 ContextSettingsView | Roles section "Editable próximamente" | ContextSettingsView.swift:~343 | Label visible pero **NO botón implementado**. Viola regla 4 ("disabled honesto"). Debe ser disabled row con texto "Próximamente" claro, no label suelto. | R.5W.fix.roles_section_honest_disabled |
| S9 ReservationsListView | Regular reservation row tap | ReservationsListView.swift:145-147,153-155 | Conflict rows pushen a ReservationConflictView (P1-05 ya resuelto). Regular rows NO pushen detail — sólo swipeActions. Asimetría UX: user espera tap → detail. | R.5W.fix.reservation_row_push |

### 🟡 PARTIAL (P3 — UX refinement)

| screen | decision_node | file:line | finding | slice |
|---|---|---|---|---|
| S2 ContextDetailViewV2 | More tab documents section row | ContextDetailViewV2.swift:moreTab | Tap abre `ActivityFeedView` fallback (R.5X audit P1-01) — cubierto por slice Documents V2 (siguiente en orden firmado). | R.5X.docs (siguiente) |
| S5 CreateResourceView | Subtype picker | CreateResourceView.swift | NO existe selector de subtype (sólo resourceType base). Backend depende de subtype para sections/widgets/capabilities. P1-11 R.5X founder firmado. | R.5X.subtype_picker (siguiente post-Documents) |
| S9 ReservationsListView | Swipe approve/confirm/cancel | ReservationsListView.swift:187-208 | Refresh post-swipe correcto (store.approve/confirm/cancel reload). Confirmación visual via swipe haptic. Sin acknowledged. | OK — `🟡` por falta de toast de éxito. P3. |
| S10 SettlementView | Recalcular currency | SettlementView.swift:76-91 | TextField currency (no Picker). User puede tipear código inválido. Backend rechaza pero error genérico. | P3 — cambiar a Picker con currencies seedeadas. |

### ⬛ ORPHANED (P2 — botones fantasma / display-only)

Lista resumida (detalle completo en R.5X audit matrix § Audit 5/6):

- **S2 ContextDetailViewV2:** widgets `active_projects`, `pending_invitations` (absorbido), `conflicts_summary` (absorbido) — 3/13 sin destino propio
- **S3 ResourceDetailViewV2:** 7 widgets INERT (`condition_status/custody_status/document_status/insurance_status/maintenance_status/tax_status/resource_value`) + 44 section rows INERT (entre las 48 del catalog)
- **S5 CreateResourceView:** subtype picker MISSING
- **S10 SettlementView:** batch section header no tappable (no batch detail view)
- **S12 ContextDetailViewV2 documents row:** fallback a ActivityFeedView (cubierto post-Documents V2)

### 🔴 UNSAFE

**0 nodes UNSAFE encontrados.** El permission chain (R.5X audit 12) sostiene end-to-end. `descriptor.actions[].enabled` honrado consistentemente con `.disabled()` en UI. Sheets nativos abren sólo vía `handleActionTap`. RPCs SECURITY DEFINER tienen gate explícito. R.5X.fix.A mapper "Próximamente" cubre el único trigger técnico que llegaba al usuario.

---

## Listas derivadas

### Inconsistencias frontend/backend

| ID | Surface | Descripción |
|---|---|---|
| INC-1 | S11 DecisionDetailView | `cancel_decision` → dialog de `close_decision` (frontend quirk para evitar añadir dialog) |
| INC-2 | S11 ContextSettingsView | Roles section label "Editable próximamente" sin botón real |
| INC-3 | S9 ReservationsListView | Conflict rows pushen detail, regular rows solo swipe (asimetría) |
| INC-4 | S5 CreateResourceView | Resource subtype no seleccionable en UI, pero descriptor B.6/B.7 depende del subtype para todo |

### Botones fantasma

✅ **R.5Y.A2 mató 3 switches duplicados de attention.**
✅ **R.5X.fix.A mapper "Próximamente"** convierte 72 actions sin dispatch en alert honesto.
⬛ Remaining: 7 widgets Resource + 44 sections Resource + roles section ContextSettings.

### Acciones visibles no ejecutables (regla 3 cubierta por fix.A)

Las 72 actions del catalog sin RPC dispatch que llegan al runtime form ahora muestran "Próximamente" honest (no error técnico). Founder firmó D ahora + C post-R.6 (badge backend).

### Acciones backend no expuestas en UI (ORPHANED inverso)

| RPC | Status |
|---|---|
| `archive_document` | NO RPC backend todavía (FQ-1 founder firmó "open archive" en Documents V2) |
| `sign_document`, `approve_document`, `request_approval` | FQ-2 firmado: NO en R.5Y, vía Decisions post-R.6 |
| `upload_new_version` | FQ-4 firmado: deferred post-R.6 |
| `reopen_obligation`, `reopen_event` | UI sin botón. State coverage R.5X audit 11. P2 cleanup. |

### Acciones con refresh incorrecto (regla 5)

**Cero detectados.** Patrones coherentes:
- ResourceDetailViewV2: `refreshConflicts` granular (R.5B.5b), `refreshActions` granular post-form submit.
- ContextDetailViewV2: store.load full + `refreshConflicts` lazy.
- ContextConflictsListView: reload completo post-resolve.
- ReservationsListView: swipe ejecuta store.approve/confirm/cancel que internamente reload.
- DecisionDetailView/MoneyHomeView/SettlementView: `.refreshable` + `refreshOnReappear` en sus stores.

### Acciones sin activity_event (regla 6)

Backend emite ~mayoría de events vía `_emit_activity` directo o triggers. iOS no necesita verificar emisión explícita — backend cubre. R.5X.fix.C alineó `document.created` canonical. Posibles gaps a verificar en R.6:
- `vote_delegation.*` (D.3)
- `governance_policy.*` (R.5)
- `reservation.requested` (R.2S)

→ verificar contra `activity_event_catalog` en R.6 si se necesita drill-down. NO bloquea R.6.

---

## Sumario por prio (cierre R.5W)

| Prio | Conteo | Slices propuestos |
|---|---|---|
| **P0 UNSAFE** | **0** | — (permission chain SOLID, R.5X.fix.A cubre regla 1) |
| **P1 INCONSISTENT** | **3** | R.5W.fix.cancel_decision_dialog · R.5W.fix.roles_section_honest_disabled · R.5W.fix.reservation_row_push |
| **P2 ORPHANED** | **~57** | Documents V2 (P1-01) · Subtype Picker (P1-11) · cleanup widgets+sections INERT |
| **P3 PARTIAL** | **3** | SettlementView batch header tap · ReservationsList swipe toast · SettlementView currency Picker |

### R.5W backlog detallado

| Slice | Estimación | Bloqueante R.6? |
|---|---|---|
| R.5W.fix.cancel_decision_dialog | iOS ~10 LOC (nuevo dialog state) | NO — bug UX menor |
| R.5W.fix.roles_section_honest_disabled | iOS ~5 LOC (cambiar label a row deshabilitada) | NO — cosmético |
| R.5W.fix.reservation_row_push | iOS ~20 LOC (push a ReservationDetailView si existe, o crear stub) | NO |

**Conclusión R.5W:** ningún UNSAFE. 3 INCONSISTENT son cosméticos. **R.5W NO bloquea R.6.** Los slices van en orden firmado (post-Documents V2, post-Subtype Picker, antes de R.6 si founder ack).

---

## Cierre

R.5W marca `Status: ✅ CLOSED` con:

1. ✅ 12 superficies inventariadas (275 nodes).
2. ✅ Atributos cruzados con R.5X data backend (permission/dispatch/refresh/activity).
3. ✅ Listas derivadas pobladas.
4. ✅ Backlog P0/P1/P2/P3 + slices R.5W.fix.* propuestos.
5. ✅ Founder ack (post-cierre): incorporar a `Plans/Active/PreR6_Roadmap.md`.

Las matrices históricas R.5X (`R5X_AuditMatrix.md`) y R.5W (este doc) viven en `Plans/Reports/`. El plan único activo es `Plans/Active/PreR6_Roadmap.md`.
