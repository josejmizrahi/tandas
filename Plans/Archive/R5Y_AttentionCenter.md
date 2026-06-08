# R.5Y — Attention Center

**Fecha:** 2026-06-07
**Status:** 📝 STUB — plan inicial (no implementación). Bloquea R.6.
**Origen:** Founder firma 2026-06-07 al revisar R.5X Batch 1, insertando R.5Y entre R.5X y R.6 (memoria `project_r5x_audit_kickoff_founder_decisions.md`).
**Bloquea:** R.6 Rule Engine 2.0.
**Bloqueado por:** R.5X cierre (12 audits + backlog firmado).

---

## Por qué R.5Y entra antes de R.6

R.6 Rule Engine 2.0 va a generar **volumen** de `conflicts / alerts / violations / recommendations`. Hoy NO hay un lugar unificado para verlos. R.5X Audit 10 confirmó:

| Categoría | HomeView (cross) | ContextDetailV2 | ContextHome v1 | Verdict |
|---|---|---|---|---|
| Invitations | ✅ | ✅ | ✅ | 🟢 VISIBLE |
| Decisions (vote) | ✅ | ✅ | ✅ | 🟢 VISIBLE |
| Obligations (pay/complete) | ✅ | ✅ | ✅ | 🟢 VISIBLE |
| Reservation conflicts | 🟡 salta a contexto, no a detail | 🟡 abre lista | 🟡 abre lista | 🟡 PARCIAL |
| Resource conflicts (R.5B direct) | ⬛ NO surface en attention | ✅ via conflictsCard local | ✅ via conflictsCard local | 🟡 PARCIAL |
| Settlements | ⬛ | ⬛ | ⬛ | ⬛ MISSING |
| Rules / Rule violations | ⬛ | ⬛ | ⬛ | ⬛ MISSING |

Sólo 3/7 categorías responden la pregunta clave del founder: "¿qué requiere mi atención hoy?". Si R.6 emite 100 violations y la UI no las consolida, el producto se siente roto.

---

## Doctrina (founder-signed)

1. **Una sola pregunta:** "¿qué requiere atención?" El usuario no debe pensar en categorías; la app las consolida.
2. **Backend = autoridad.** `attention_inbox()` RPC es la fuente única; iOS sólo presenta + enruta.
3. **Cross-context y per-context.** HomeView consolida cross; ContextV2/ContextHome muestran filter por contexto.
4. **Detail real, no lista.** Tap en un item de atención abre el detail accionable (DecisionDetailView con vote UI, ObligationDetailView con pay, ReservationConflictView con resolve, etc.), no una lista intermedia.
5. **Dispatch consistente.** Una sola tabla `attention_kind → destination` en código (no switches duplicados en HomeView/ContextV2/ContextHome).

---

## Scope R.5Y (stub — completar tras cierre R.5X)

### Backend (A1)

| Slice | Cambio | Migration |
|---|---|---|
| **R.5Y.A1.0** | Ampliar `attention_kind` catalog: agregar `settlement_open`, `rule_violation`, `resource_conflict_direct` | nueva migration `r5y_a1_0_attention_kinds_extension` |
| **R.5Y.A1.1** | Extender `attention_inbox()` RPC para emitir las 3 categorías nuevas | misma migration o sub-slice |
| **R.5Y.A1.2** | Agregar `attention_item.payload.scope_id` semantics consistente: para conflict → resource_id; para settlement → batch_id; para rule_violation → rule_id + violation_id | additive |
| **R.5Y.A1.3** | Smoke tests `_smoke_r5y_a1_attention` — verificar shapes + RLS gating |

### iOS (A2)

| Slice | Cambio | Files |
|---|---|---|
| **R.5Y.A2.0** | `AttentionDispatcher` componente único — switch `attention_kind → AttentionDestination` (sheet item / push) | nuevo `Components/AttentionDispatcher.swift` (~150 LOC) |
| **R.5Y.A2.1** | Refactor `HomeView.handleTap` + `ContextDetailViewV2.handleAttentionTap` + `ContextHomeView.handleAttentionTap` para usar el dispatcher (eliminar 3 switches duplicados) | mismos files |
| **R.5Y.A2.2** | Wire `reservation_conflict` row → `ReservationConflictView(conflictId:)` (P1-05 del R.5X) | ContextHome v1 + ContextV2 |
| **R.5Y.A2.3** | Wire `settlement_open` row → `SettlementView(scrollToBatchId:)` | nuevo param SettlementView |
| **R.5Y.A2.4** | Wire `resource_conflict_direct` row → `ResourceDetailViewV2(resourceId:, scrollToConflictsCard: true)` | nuevo param Resource V2 |
| **R.5Y.A2.5** | `rule_violation` row → push `RuleViolationDetailView` (NEW) | nueva view minimal (R.6 la enriquece) |
| **R.5Y.A2.6** | Update memoria `project_r5y_attention_center_shipped.md` |

### Tests

- Mock `attention_inbox` con 7 kinds, validar dispatch a cada destination.
- Smoke iOS preview con world demo: founder ve 7 categorías consolidadas en HomeView attentionCard.

---

## Doctrina de surface (✅ FIRMADA founder 2026-06-07)

**P1-04: CROSS-CONTEXT** para las 3 nuevas categorías.

Modelo conceptual:
```
Global Attention Center
       ↓
Context Attention
```

Founder rationale literal: "el usuario piensa '¿Qué requiere mi atención?', NO '¿Qué requiere atención dentro de este contexto específico?'"

Aplica a las 3 categorías nuevas que R.5Y agrega:
- `settlement_open` cross-context
- `rule_violation` cross-context
- `resource_conflict_direct` cross-context

Las categorías existentes (invitation, decision_vote, obligation_pay/complete, reservation_conflict) ya son cross-context — R.5Y las refactoriza para usar el dispatcher único.

---

## Out of scope para R.5Y

- ❌ Rule Engine 2.0 evaluation logic (R.6).
- ❌ **Sign/Approve documents** — founder firmó FQ-2: debe pasar por Decision → Approval → Governance, deferred post-R.5Y.
- ❌ ConflictDetailView dedicada — founder firmó P2-03: dialog inline de R.5B.5b es la decisión correcta, esperar R.6.
- ❌ Notification push del attention (sería R.7).
- ❌ Snooze / dismiss inline de attention items (futuro).

---

## Cierre R.5Y handoff a R.6

R.5Y CLOSED cuando:

1. `attention_inbox()` backend devuelve 7 kinds completos con smoke verde.
2. iOS AttentionDispatcher cubre 7/7 con destination real.
3. HomeView smoke device con world demo muestra 7 categorías consolidadas.
4. Build verde.
5. Founder firma "puedo abrir Ruul un lunes y saber qué necesita mi atención sin pensar".

Después de R.5Y CLOSED:

```
R.6 Rule Engine 2.0 arranca con attention surface lista para recibir su volumen.
```
