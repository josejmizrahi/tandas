# R.5V.0a — UX Doctrine (single source of truth)

**Fecha:** 2026-06-07
**Status:** 🟡 IN PROGRESS — congelando definiciones antes de V.0 audit
**Bloquea:** R.5V.0 (UI Audit) · R.5V.1 (Tokens) · R.5V.2 (Componentes Ruul*) · Documents V2 · R.6 Rule Engine
**Founder rationale:** "Si no congelas esta doctrina ahora, en R.6 vas a terminar con Rule Engine View, Violation View, Policy View, Automation View — cada una con UX ligeramente distinta."

---

## Objetivo

Congelar el **lenguaje conceptual** que sostiene toda la UI de Ruul. Toda pantalla nueva (Documents V2, Rule Engine, Violations, Policies, Automations, etc.) parte de este vocabulario. Esto es **el contrato de UX**, no el plan de implementación.

---

## 1. ¿Qué es una pantalla Ruul?

Toda pantalla detail (Context, Resource, Document, Rule, Policy, Decision, etc.) sigue la **misma arquitectura ordenada**:

```
1. Hero        — identidad + estado + chips críticos
2. Attention   — qué requiere acción AHORA en este contexto (cross-context vive en HomeView)
3. Widgets     — KPIs / métricas top-of-mind, scroll horizontal
4. Sections    — secciones detalladas, agrupadas por dominio
5. Actions     — qué puedes hacer (lista intent-first, ordenada por section)
6. Activity    — qué pasó (preview + "Ver todo" a feed completo)
```

**Reglas:**

- El orden es fijo. Hero arriba SIEMPRE. Activity abajo SIEMPRE.
- Attention sólo aparece si hay items pendientes para el viewer.
- Widgets sólo si hay KPIs cargados (sin widgets → skip section).
- Sections agrupan; cada section row tappable → push detalle específico.
- Actions = `available_actions[]` filtradas + enabled honors backend.
- Activity = últimos 5 events + "Ver todo".

**Patrón aplica a:**

| Surface | Hero | Attention | Widgets | Sections | Actions | Activity |
|---|---|---|---|---|---|---|
| ResourceDetailViewV2 | ✅ | ⚠️ via Conflicts card | ✅ | ✅ | ✅ | ✅ |
| ContextDetailViewV2 | ✅ via Overview | ✅ AttentionCard | ✅ | ✅ via tabs | ✅ via quick actions menu | ✅ |
| **DocumentDetailView** (nuevo) | ✅ Hero (icon, title, type) | n/a | KPIs (size, version, status) | metadata, linked resource/event/decision, versions list | view_document/sign/approve/archive | history |
| **RuleDetailView** (R.6) | ✅ | ⚠️ violations recientes | KPIs (trigger count, last fired) | trigger, condition_tree, consequences, attachments | edit_rule/archive_rule | rule.fired events |
| **PolicyDetailView** (R.6+) | ✅ | n/a | KPIs (cumplimiento) | targets, threshold, exceptions | edit/archive | policy.* |

---

## 2. ¿Qué es una acción?

Toda acción visible tiene un estado tri-valuado **honesto**:

| Estado | UI | Trigger backend | Mostrar al user |
|---|---|---|---|
| **Visible · Enabled · Ejecutable** | row activo con chevron, tap → form/sheet/dispatch | `available_actions[].enabled = true` + RPC vivo en `resource_action_dispatch` | "Ejecutar" → executeResourceAction → success |
| **Visible · Disabled (sin permiso)** | row `.disabled(true)` con `action.reason` visible | `available_actions[].enabled = false` con `reason` | "Sin permiso para …" |
| **Visible · Próximamente** | row `.disabled(true)` con badge "Próximamente" | `available_actions[].enabled = true` PERO action_key SIN dispatcher backend | Badge "Próximamente" honest |
| **Visible · Requiere decisión** | row activa con icon de votación + label "via decisión" | `execution_mode = 'request_decision'` + `decision_template_key` | "Abrir decisión grupal" → CreateDecisionView |
| **Visible · Dangerous** | row activa con tint danger + confirmation alert post-tap | `dangerous = true` + `confirmation_required` | confirmation alert "Sí, ejecutar" destructive |

**Anti-reglas:**
- ❌ NUNCA error técnico (`0A000`, `not_implemented`, `Internal Error`) al usuario final.
- ❌ NUNCA label suelto sin botón implementado (regla R.5W INC-2).
- ❌ NUNCA action sin dispatcher que parezca terminada (R.5X.fix.A copy "Próximamente" cubre).
- ❌ NUNCA dispatcher iOS que invente acciones no declaradas por backend.

---

## 3. ¿Qué es un conflicto?

Estado y severidad **canónicos**:

| Tipo | Trigger backend | Severidad | UI badge |
|---|---|---|---|
| **Warning** | overlap parcial, doble booking soft, blackout violación menor | `severity = 'warning'` | naranja `triangle.fill` |
| **Critical** | doble booking hard, ownership conflict, critical_resources blocker | `severity = 'critical'` | rojo `exclamationmark.octagon.fill` |
| **Info** | nota informativa (no requiere acción inmediata) | `severity = 'info'` | azul `info.circle.fill` |

**Resoluciones canónicas (3-kind dialog, R.5B.5b):**

| Kind | Significado | Acción backend |
|---|---|---|
| **Manual resolution** | Admin resuelve inline (e.g. dar ganador a reserva A) | `resolveResourceConflict(kind: .manualResolution)` → write-through legacy si aplica |
| **Escalate to decision** | Pasar a votación del contexto | `resolveResourceConflict(kind: .escalate)` → crea decision via template |
| **Dismiss** | Marcar como descartado (audit lineage queda) | `resolveResourceConflict(kind: .dismiss)` |

**Reglas:**
- Conflictos abiertos surface en attention `resource_conflict_direct` cross-context (R.5Y.A1).
- Lista por contexto en ContextDetailViewV2 conflictsCard.
- Lista por recurso en ResourceDetailViewV2 conflictsCard.
- Resolution YA hecha con dialog inline 3-kind. **NO ConflictDetailView dedicada** (founder firmó P2-03 R.5X).

---

## 4. ¿Qué es un documento?

Tipo **canónico** (DocumentType enum):

| Tipo | Significado | Use case |
|---|---|---|
| **Contract** | Acuerdo legal | escritura, contrato de arrendamiento, NDA |
| **Receipt** | Comprobante | factura, ticket, recibo de pago |
| **ID** | Identificación | INE, pasaporte, RFC |
| **Statement** | Estado de cuenta | bank statement, billing summary |
| **Photo** | Imagen | foto de prueba, condición física, evidencia |
| **Other** | No clasificado | fallback |

**Reglas (founder FQ-1/4 firmados):**
- **Inmutables.** Documento subido = snapshot histórico. NO se edita.
- **Versions = nuevo documento + `supersedes` relation.** Lista de versiones en DocumentDetailView.
- **Status:** `archived_at IS NULL` = active; `archived_at IS NOT NULL` = archived. Sin enum lifecycle.
- **Sign/Approve:** vía Decisions (`request_decision` template). Deferred a post-Documents V2.
- **OCR:** P3, deferred post-R.6.

**Anti-reglas:**
- ❌ NO "Edit document" action.
- ❌ NO renombrar archivos físicos en Storage.
- ❌ NO permitir upload sin tipo seleccionado (forzar DocumentType en attach).

---

## 5. ¿Qué es un recurso?

Estructura **canónica** (descriptor-driven, ResourceDetailViewV2):

```
1. Header        — class · subtype · displayName · status badge · capabilities chips
2. Capabilities  — chips tappables con explicación inline (effective_capabilities)
3. Rights        — quién tiene qué derecho (OWN/MANAGE/USE/VIEW/BENEFICIARY/GOVERN)
4. Actions       — available_actions[] del descriptor (intent-first, agrupadas por section)
5. Relations     — outbound/inbound (resource_relations · contains/secures/owns/leases/...)
6. Activity      — últimos 5 events + "Ver todo"
```

Más subviews condicionales por capability:
- **Conflicts card** si `descriptor.conflicts.openCount > 0`
- **Widgets row** si `descriptor.widgets[]` no vacío
- **Linked events/obligations/decisions** si arrays no vacíos
- **Sections** del catalog filtradas por effective_capabilities

**Reglas:**
- Render 100% data-driven (no hardcode por subtype).
- Subtype-specific behavior emerge del descriptor.
- Foundation Lock (CLAUDE.md): NO crear `entity`, NO fusionar actors+resources.

---

## 6. ¿Qué es un contexto?

5 tabs canónicas (ContextDetailViewV2 segmented picker):

| Tab | Contiene |
|---|---|
| **Overview** | Attention card · Conflicts card (si aplica) · Metrics (members, decisions, obligations, resources by class) · Widgets row · Child contexts carousel · Activity preview |
| **People** | Members preview con avatars · Roles list |
| **Resources** | Resources preview agrupados por class |
| **Money** | My balance · Open settlements · Obligations preview |
| **More** | Pending invitations · Sections residuales (calendar/governance/documents/activity/settings) · Permissions chips |

**Reglas:**
- Tabs se filtran dinámicamente por `descriptor.sections[].visible`.
- Quick actions toolbar = `context_available_actions()` filtradas.
- Personal context (own actor) NO tiene tabs People/Resources/Money — solo Overview + More simplificado.
- Subcontextos heredan estructura.

---

## 7. ¿Qué es Attention?

**Atención** = una intención del backend de que el viewer debería actuar AHORA.

Categorías canónicas (R.5Y.A1 — 6 kinds + extensible):

| Kind | Significado | Surface | Dispatch destino |
|---|---|---|---|
| `invitation` | Tienes invitación pendiente | HomeView + ContextDetailV2 | PendingInvitationsView |
| `decision_vote` | Puedes votar una decisión abierta | HomeView + ContextDetailV2 | DecisionDetailView |
| `obligation_pay` | Debes dinero | HomeView + ContextDetailV2 | ObligationDetailView |
| `obligation_complete` | Debes completar un compromiso (no monetario) | HomeView + ContextDetailV2 | ObligationDetailView |
| `reservation_conflict` | Conflicto de reservas donde participas | HomeView + ContextDetailV2 | ReservationConflictView via Bootstrap |
| `settlement_open` | Pago pendiente de liquidación | HomeView + ContextDetailV2 | SettlementView |
| `resource_conflict_direct` | Conflicto en un recurso del contexto (open + member) | HomeView + ContextDetailV2 | ResourceDetailViewV2 + conflictsCard |
| `rule_violation` (R.6) | Una rule disparó violation requiriendo acción | HomeView + ContextDetailV2 (TODO R.6) | RuleViolationDetailView (TODO R.6) |
| `policy_violation` (R.6+) | Política violada | TODO | TODO |
| `maintenance_due` (futuro) | Mantenimiento requerido en recurso | TODO | TODO |
| `document_expiring` (futuro) | Documento por expirar | TODO | TODO |

**Reglas:**
- Backend = autoridad. iOS NO inventa kinds.
- **CROSS-CONTEXT** (founder firmado R.5Y P1-04). Modelo: Global Attention → Context Attention.
- Un único `AttentionDispatcher` (R.5Y.A2) routea TODO. Pantallas consumidoras NO duplican switches.
- Kinds futuros (rule_violation, policy_violation, etc.) **NO tocan pantallas** — solo extender el dispatcher.
- Fallback `.unsupported(kind)` muestra "Próximamente" honest si iOS no cubre aún (R.6 plug-and-play).

---

## 8. ¿Qué es Activity?

Cronología de events emitidos por backend vía `_emit_activity`. Catalog vive en `activity_event_catalog`.

**Reglas:**
- Backend autoritativo. iOS NO emite events.
- Activity feed cross-context (MyActivityFeedView) o per-context (ActivityFeedView).
- Preview de últimos 5 en cada detail screen + "Ver todo".
- Tap en row → push detail relacionado (deep-link por subject_type + subject_id).
- Event types canónicos: `domain.action_past` (e.g. `resource.created`, `decision.voted`, `obligation.completed`).
- Mapper interno `_emit_activity` cubre backwards compat (e.g. `document.registered → document.created`) — fuente única.

---

## 9. ¿Qué es una decisión?

Voting model **canónico** (Decision domain):

| Model | Voting UI | Use case |
|---|---|---|
| `yes_no_abstain` | 3 vote cards (Sí/No/Abstenerme) | propuestas simples |
| `single_choice` | option cards (1 selección) | elegir entre opciones |
| `multiple_choice` | checkboxes (N selecciones) | priorización múltiple |

Status:
- `open` — votando
- `approved` / `rejected` — votación cerrada con resultado
- `executed` — consecuencia aplicada
- `cancelled` — revocada antes de cerrar

**Reglas:**
- Quorum / majority rule definidos por contexto (ContextSettingsView).
- `vote_delegation` (D.3) permite delegar voto a otro actor.
- Action `cancel_decision` debe tener dialog propio (R.5W.fix INC-1 — pendiente).
- Founder lock (F.DECISION.1): hero → estado → tu decisión → resultados → participantes → consecuencias → actividad → subscripción → admin → auditoría.

---

## 10. ¿Qué es dinero?

Domain canónico:

| Concepto | Significado |
|---|---|
| **Expense** | Gasto registrado (record_expense → genera obligations split) |
| **Obligation** | Compromiso (money: pagar / action: hacer algo) |
| **Settlement Batch** | Conjunto de transferencias netas para liquidar |
| **Settlement Item** | Transferencia individual `from_actor → to_actor` |
| **Balance** | Balance neto del actor en el contexto |

**Reglas:**
- `record_expense` autoritativo para crear obligations monetarias.
- `kind=money` rechazado en `CreateObligationView` (vía record_expense).
- Settlement neteo min-cashflow por novación (backend, no iOS).
- `mark_paid` por item.
- Currency per-batch (no per-item).

---

## 11. ¿Qué es Storage?

(Documents V2 prep)

**Reglas (founder FQ-1 firmado):**
- Supabase Storage bucket `documents` privado, 50MB máx por archivo.
- Whitelist: PDF, imagen (JPG/PNG/HEIC), texto, CSV.
- Inmutable v1: NO UPDATE/DELETE policy en Storage.
- `archive_document` RPC SECURITY DEFINER setea `archived_at` (soft delete). Blob permanece.
- Signed URLs con TTL 3600s para QuickLook preview.
- Path convention: `{context_id}/{resource_id}/{document_id}/{filename}` (TBD verify backend).

---

## 12. Diccionario UI

| Término | Significado en Ruul |
|---|---|
| **Decision node** | Cualquier UI tappable que cambie state (button/row/swipe/dialog button). Form fields NO son decision nodes. |
| **Dispatch** | Routing de intención (action_key, attention kind) a destino (sheet/push/RPC). |
| **Descriptor** | Output de RPC `*_detail_descriptor` que renderea UI 100% data-driven (B.6 Resource, B.7 Context). |
| **available_actions** | Lista enriquecida emitida por backend con `enabled`/`reason`/`form_schema_present`/`execution_mode`. |
| **action_key** | Identificador canónico (e.g. `record_expense`, `grant_right`) que el dispatcher mapea a RPC. |
| **capability** | Atributo declarado del recurso (e.g. `reservable`, `documentable`) que filtra sections/widgets/actions. |
| **right** | Derecho de un actor sobre un recurso (OWN/MANAGE/USE/VIEW/BENEFICIARY/GOVERN). |
| **permission** | `permission_key` (e.g. `decisions.vote`) que un role concede al actor en un contexto. |
| **Hero** | Sección superior de cualquier detail screen (identidad + status). |
| **Attention** | Sección que muestra qué requiere acción del viewer ahora. |
| **Widget** | KPI/métrica top-of-mind (scroll horizontal). |
| **Section** | Sección detallada de un detail screen (e.g. `documents`, `insurance`, `maintenance`). |
| **Próximamente** | Copy oficial cuando un action_key del catalog no tiene RPC dispatch backend (R.5X.fix.A). |

---

## 13. Reglas de coherencia futura (anti-drift para R.6)

Toda pantalla nueva del Rule Engine 2.0 sigue:

- **Hero → Attention → Widgets → Sections → Actions → Activity** (regla §1).
- **Action states tri-valuados** (regla §2).
- **Conflict severities canónicas** si aplica (regla §3).
- **AttentionDispatcher** para cualquier item de atención nuevo (regla §7).
- **Backend autoritativo** para activity_events (regla §8).
- **Componentes Ruul*** (R.5V.2 cherry-pick 7) — NUNCA custom si nativo cubre.

Cualquier deviation requiere founder ack en este doc (§13) antes de merge.

---

## Cierre

Este documento marca `Status: ✅ FROZEN` cuando:

1. ✅ §1–§11 firmados founder (no edits sin firma).
2. ✅ R.5V.0 audit cita este doc como base.
3. ✅ Documents V2 cita §4 (documento) + §11 (storage) en su spec.
4. ✅ R.6 plan cita §7 (attention kinds futuros) + §9 (decisión) + §13 (anti-drift) en su spec.

Cualquier slice post-Documents V2 que cree pantalla nueva debe agregar fila al §1 mapping table.
