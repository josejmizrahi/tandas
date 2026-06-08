# R.5W — User Decision Tree Consistency Audit

**Fecha inicio:** 2026-06-07
**Status:** 🟡 IN PROGRESS — auditando (NO ejecutando features nuevas)
**Bloquea:** R.6 Rule Engine 2.0
**Precede:** Documents V2, Resource Subtype Picker (orden firmado founder se ajusta — R.5W antes que ambos)
**Companion:** `Plans/Reports/R5W_UserDecisionTreeMatrix.md` (matriz operativa)

---

## Objetivo

Auditar y cerrar la **consistencia del árbol de decisiones del usuario** antes de R.6. R.5X auditó *completeness* ("¿existe?"). R.5W audita *consistency end-to-end* ("¿es seguro, predecible, completo en sus 14 atributos por nodo decisional?").

### Definición

Un user decision tree está completo cuando **toda acción visible** tiene los 14 atributos:

| # | Atributo | Pregunta |
|---|---|---|
| 1 | **source screen** | ¿Desde qué pantalla nace? |
| 2 | **visible label** | ¿Qué lee el usuario? |
| 3 | **required permission** | ¿Qué `permission_key` exige? |
| 4 | **required right** | ¿Qué `right_kind` exige? |
| 5 | **required capability** | ¿Qué `capability_key` exige? |
| 6 | **enabled/disabled/proximamente state** | Estado tri-valuado honesto |
| 7 | **form/sheet/dialog** | ¿Cómo se ejecuta (UI)? |
| 8 | **backend RPC/dispatcher mapping** | ¿A qué RPC despacha? |
| 9 | **success result** | ¿Qué ve el user al éxito? |
| 10 | **error result** | ¿Qué ve el user al error? |
| 11 | **activity_event emitted** | ¿Qué tipo de evento emite? |
| 12 | **descriptor refresh behavior** | ¿Qué refresca tras éxito? |
| 13 | **attention/conflict impact** | ¿Genera attention item o conflict? |
| 14 | **navigation destination** | ¿A dónde lleva al user? |

---

## Reglas (founder-signed 2026-06-07)

1. **Ningún botón visible debe terminar en error técnico.**
2. **Ninguna acción ejecutable debe saltarse permisos.**
3. **Ninguna acción sin dispatcher debe parecer terminada.**
4. **Toda acción no implementada debe mostrarse como "Próximamente" o disabled honesto.**
5. **Toda acción completada debe refrescar el descriptor correcto.**
6. **Toda acción relevante debe generar `activity_event`.**
7. **`available_actions[]` es la fuente autoritativa.**
8. **iOS NO debe inventar acciones que backend no declare.**
9. **El dispatcher (`execute_resource_action`) es el único punto de ejecución.**
10. **`AttentionDispatcher` es el único punto de navegación por attention item.**

---

## Superficies a auditar

| # | Superficie | Foco |
|---|---|---|
| S1 | **HomeView** | Attention card · Continuar · Actividad · Tools (Próximamente) |
| S2 | **ContextDetailViewV2** | 5 tabs (Overview/People/Resources/Money/More) · quick actions toolbar · attention card · conflicts card · widget cards · child contexts |
| S3 | **ResourceDetailViewV2** | hero · capabilities chips · widgets · sections · actions list · relations · linkedEvents/Obligations/Decisions · conflicts card · activity preview |
| S4 | **AttentionDispatcher** | 6 kinds backend + fallback unsupported |
| S5 | **CreateResourceView** | type picker · location · estimated value · currency |
| S6 | **Action sheets (R.5A V2)** | ResourceActionFormView runtime (11 field types) · GrantRightSheet · AttachDocumentView · EditResourceView |
| S7 | **Native sheets pre-V2** | CreateEventView · CreateDecisionView · CreateObligationView · RecordExpenseView · RecordGameResultView · RequestReservationView · InviteMembersView · JoinByCodeView |
| S8 | **Conflict dialogs** | ResourceDetailViewV2 ConflictsModifier (3-kind) · ContextDetailViewV2 ContextConflictsModifier · ContextConflictsListView |
| S9 | **Reservation flows** | ReservationsListView swipeActions · RequestReservationView · ReservationConflictView · ReservationIntentLanding |
| S10 | **Money flows** | MoneyHomeView · SettlementView · ObligationDetailView · RecordExpenseView splits/eventScope |
| S11 | **Governance flows** | DecisionDetailView vote/execute/close · DecisionsListView · CreateDecisionView · ContextSettingsView |
| S12 | **Documents placeholders / fallbacks** | AttachDocumentView · ContextV2 documents row → ActivityFeedView fallback · ResourceV2 `linkedDocuments` decoded but not rendered |

---

## Clasificación canónica

| Status | Significado |
|---|---|
| 🟢 **COMPLETE** | 14/14 atributos verde end-to-end |
| 🟡 **PARTIAL** | 1+ atributos parcial (e.g. falta empty state, refresh granular, etc) |
| ⚠️ **INCONSISTENT** | Atributos contradictorios (e.g. UI gate≠RPC gate, action visible≠enabled state) |
| ⬛ **ORPHANED** | UI visible sin dispatcher backend (botón fantasma) o RPC vivo sin UI |
| 🔴 **UNSAFE** | Viola regla 1, 2, 3, 5 o 6 (puede ejecutar sin permiso / sin refresh / sin activity / con error técnico) |

---

## Reusable inputs de R.5X (no re-auditar)

Para no duplicar trabajo, R.5W parte de los siguientes hallazgos cerrados en R.5X:

| R.5X finding | R.5W aprovecha |
|---|---|
| 88 actions catalog · 16 dispatch wired | sabe qué actions son ejecutables vs "Próximamente" |
| 42 capabilities · 6 ⚪ NO_EFFECT | sabe qué caps gating son fantasmas |
| 18 widgets resource · 7 INERT | sabe widgets sin destino (consistency falla en navigation) |
| 47 sections resource · 37 INERT | sabe sections sin destino |
| Permission chain SOLID (R.5X audit 12) | sabe que descriptor.actions[].enabled honrado en `.disabled()` |
| Backend RPC gates 100% (R.5X audit 12) | sabe que `has_actor_authority/actor_has_right/_can_*` cubre las 6 RPCs auditadas |
| R.5X.fix.A `RPCErrorMapper` `0A000→"Próximamente"` shipped | sabe que regla 1 está cubierta para action runtime form (resta validar otras superficies) |
| R.5Y.A2 `AttentionDispatcher` único | sabe que regla 10 está cubierta |

R.5W **agrega** la dimensión de:
- **Refresh strategy** correcto post-acción (regla 5)
- **Activity event emisión** por acción (regla 6)
- **Consistencia UI gate ↔ RPC gate ↔ visible state ↔ refresh** (regla 5+6+atributos 11+12)
- **Detección de botones fantasma fuera del action runtime form** (sheets nativos, swipe actions, toolbar quick actions, dialogs)

---

## Metodología

```
1. Inventario       — listar TODOS los decision nodes por superficie (botones, swipes, action rows, dialog buttons, sheet submit buttons)
2. Atributos        — para cada nodo, llenar los 14 atributos (file:line refs)
3. Cruce reglas     — validar contra las 10 reglas; marcar UNSAFE/INCONSISTENT/ORPHANED
4. Clasificación    — COMPLETE / PARTIAL / INCONSISTENT / ORPHANED / UNSAFE
5. Priorización     — P0 (UNSAFE) · P1 (INCONSISTENT) · P2 (ORPHANED nav) · P3 (PARTIAL refinement)
```

---

## Batches de ejecución

### Batch 1 — Inventario por superficie

Dispatch 3 agentes paralelos para enumerar TODOS los decision nodes:
- **B1.a S1+S2+S4** — HomeView + ContextDetailViewV2 + AttentionDispatcher
- **B1.b S3+S6+S8** — ResourceDetailViewV2 + Action/Native sheets + Conflict dialogs
- **B1.c S5+S7+S9+S10+S11+S12** — Create flows + Reservation + Money + Governance + Documents

Cada agente devuelve por nodo: `screen · decision_node · action_key · visible_to_user_text · file:line`.

### Batch 2 — Atributos + clasificación + reglas

Sintetizar nodos del Batch 1 con los datos backend ya conocidos de R.5X (no re-auditar). Llenar los 14 atributos. Cruzar contra las 10 reglas.

### Batch 3 — Backlog priorizado

P0 UNSAFE → fix immediate. P1 INCONSISTENT → fix slice. P2 ORPHANED → cleanup. P3 PARTIAL → refinement.

---

## Entregables

| Documento | Función |
|---|---|
| `Plans/Active/R5W_UserDecisionTreeConsistency.md` (este) | Metodología, reglas, decisiones, backlog final |
| `Plans/Reports/R5W_UserDecisionTreeMatrix.md` | Matriz operativa fila por nodo (16 columnas: screen·node·action_key·visible·enabled·dispatch·permission·capability·right·flow·success·error·refresh·activity·status·priority) |

Más listas derivadas:
- Lista de **inconsistencias frontend/backend**
- Lista de **botones fantasma** (UI visible sin dispatcher)
- Lista de **acciones visibles no ejecutables** (regla 3)
- Lista de **acciones backend no expuestas en UI** (ORPHANED inverso)
- Lista de **acciones con refresh incorrecto** (regla 5)

---

## Cierre y handoff

R.5W marca `Status: ✅ CLOSED` cuando:

1. Las 12 superficies con todos los nodes inventariados.
2. Matriz con 14 atributos llenos por nodo.
3. Backlog P0/P1/P2 con slice IDs asignados.
4. Founder firma orden de ejecución.
5. P0 (UNSAFE) shipped.

Post-R.5W close, retoma orden firmado:

```
→ Documents V2
  Resource Subtype Picker
  R.6 Rule Engine 2.0
```

---

## Pre-cierre (a poblar en Batch 3)

| Categoría | Conteo | Slice propuesto |
|---|---|---|
| 🔴 UNSAFE P0 | — | — |
| ⚠️ INCONSISTENT P1 | — | — |
| ⬛ ORPHANED P2 | — | — |
| 🟡 PARTIAL P3 | — | — |
