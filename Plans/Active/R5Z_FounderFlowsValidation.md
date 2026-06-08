# R.5Z — Founder Flows Validation

**Fecha:** 2026-06-07
**Status:** ⏳ PENDING — entre Resource Subtype Picker y R.6 Rule Engine 2.0
**Bloquea:** R.6 Rule Engine 2.0
**Founder rationale (2026-06-07):** *"Si esos 10 flujos funcionan de extremo a extremo, R.6 tendrá una base extremadamente estable."*

---

## Objetivo

Antes de abrir R.6 Rule Engine 2.0, **validar end-to-end en device** los 10 flows founder-canónicos. Si esos 10 pasan sin fricción, la base está sólida para meter Rules + Policies + Violations + Automations encima.

Esto NO es auditoría (R.5X cubrió). Esto NO es testing automatizado (out of scope). Esto es **smoke device founder-driven** donde el founder ejecuta los 10 flows en su iPhone JJ y firma cada uno como ✅/⚠️/❌.

---

## 10 Founder Flows (canónicos)

| # | Flow | Trigger | RPC backend | Detail view destino | Activity event esperado |
|---|---|---|---|---|---|
| 1 | **Crear familia** | CreateIntentSheet → "Crear contexto" | `create_context(subtype='family')` | ContextDetailViewV2 | `context.created` |
| 2 | **Crear casa** | CreateIntentSheet → "Agregar recurso" → context family → subtype picker → `primary_residence` o `vacation_home` | `create_resource(subtype_key='primary_residence')` (post Subtype Picker R.5V) | ResourceDetailViewV2 | `resource.created` |
| 3 | **Invitar miembro** | ContextDetailV2 toolbar → `invite_member` quick action | `create_invite()` | InviteMembersView | `member.invited` / `membership.invited` |
| 4 | **Crear evento** | CreateIntentSheet → "Programar algo" → context | `create_calendar_event()` | EventDetailView | `event.created` |
| 5 | **Reservar recurso** | CreateIntentSheet → "Hacer reservación" → context → casa → fechas | `request_resource_reservation()` | ReservationsListView (+ approval flow) | `reservation.requested` |
| 6 | **Registrar gasto** | CreateIntentSheet → "Registrar movimiento" → context | `record_expense()` | MoneyHomeView | `expense.recorded` |
| 7 | **Generar deuda (obligación)** | CreateIntentSheet → "Asignar compromiso" → context (R.5X.fix.B shipped) | `create_action_obligation()` | ObligationDetailView | `obligation.created` |
| 8 | **Resolver conflicto** | HomeView attention `resource_conflict_direct` o `reservation_conflict` → ResourceDetailV2/ReservationConflictView → 3-kind dialog | `resolve_resource_conflict()` / `resolve_reservation_conflict()` | resolved status update | `resource.conflict_resolved` / `reservation.conflict_resolved` |
| 9 | **Tomar decisión** | CreateIntentSheet → "Crear propuesta" → context → tipo + voting model + opciones → "Proponer" | `create_decision()` + `create_decision_option()` + `vote_decision()` | DecisionDetailView | `decision.created` + `decision.voted` |
| 10 | **Subir documento** | CreateIntentSheet → "Subir documento" → context → recurso → fileImporter → tipo → "Adjuntar" | `register_document()` | (post Documents V2) DocumentDetailView | `document.created` |

---

## Smoke matrix

Founder ejecuta cada flow en iPhone JJ y marca:

| # | Flow | Clic count | Pantallas vacías | Errores user-visible | Acciones ocultas | Nav rota | Refresh post-éxito | Activity event surface | Status founder |
|---|---|---|---|---|---|---|---|---|---|
| 1 | Crear familia | | | | | | | | ⏳ |
| 2 | Crear casa | | | | | | | | ⏳ |
| 3 | Invitar miembro | | | | | | | | ⏳ |
| 4 | Crear evento | | | | | | | | ⏳ |
| 5 | Reservar recurso | | | | | | | | ⏳ |
| 6 | Registrar gasto | | | | | | | | ⏳ |
| 7 | Generar deuda | | | | | | | | ⏳ |
| 8 | Resolver conflicto | | | | | | | | ⏳ |
| 9 | Tomar decisión | | | | | | | | ⏳ |
| 10 | Subir documento | | | | | | | | ⏳ |

**Status founder:** ✅ pasa sin fricción · ⚠️ pasa con observación · ❌ blocker

---

## Reglas

- **No bypass.** Founder usa la app como user real (no debug, no fixtures). Si necesita data, la genera en el flow.
- **iPhone JJ device físico**, no simulator.
- **Cada flow se mide:** clics, latencia visible, claridad copy, native feel.
- **Cualquier ❌ es blocker para R.6.** Cualquier ⚠️ se trianjula con backlog R.5W / R.5V / R.5X.

---

## Pre-requisitos (todos shipped antes de R.5Z)

| Pre-req | Status |
|---|---|
| R.5X.fix.A/B/C (mapper "Próximamente", intent.obligation, document.created) | ✅ shipped |
| R.5Y.A1/A2 (Attention Center cross-context + dispatcher único) | ✅ shipped |
| R.5V.0a UX Doctrine (vocabulario) | ⏳ pendiente |
| R.5V.0 UI Audit + R.5V.1 Tokens + R.5V.2 Componentes (8 cherry-pick) | ⏳ |
| Documents V2 (sin esto el flow 10 falla) | ⏳ |
| Resource Subtype Picker (sin esto el flow 2 falla — no se puede elegir `primary_residence`/`vacation_home`) | ⏳ |
| R.5V.3–V.5 migración mínima HomeView + ContextDetailV2 + ResourceDetailV2 (para native feel) | ⏳ paralelo |
| R.5W.fix.* (3 P1 cosméticos) | ⏳ |

---

## Cierre

R.5Z marca `Status: ✅ CLOSED` cuando:

1. ✅ 10/10 flows con status ✅ del founder.
2. ✅ Smoke matrix completa con clics + observaciones.
3. ✅ Cualquier ⚠️ documentado y agendado para post-R.6 (o fix inmediato si ack).
4. ✅ Founder firma: "puedo abrir Ruul un lunes y hacer cualquiera de estos 10 flujos sin pensar".

Si hay 1+ ❌, slice de fix corre antes de R.6.

R.6 Rule Engine 2.0 arranca cuando R.5Z CLOSED.
