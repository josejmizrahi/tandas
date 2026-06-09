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
| 1 | Crear familia | — | no | no | no | post-create no auto-push a ContextDetailV2 | OK manual | n/a | ⚠️ |
| 2 | Crear casa | — | no | no | sí (ver hallazgos) | post-create sheet no se cierra | OK manual | n/a | ⚠️ |
| 3 | Invitar miembro | — | no | no | invitado no aparece en lista pre-accept | n/a | n/a | n/a | ⚠️ |
| 4 | Crear evento | — | no | no | sí (flujo único en vez de por tipo, host rotation siempre visible) | n/a | n/a | n/a | ⚠️ |
| 5 | Reservar recurso | — | no | no | sí (granularidad fija, UX no Airbnb) | n/a | n/a | n/a | ⚠️ |
| 6 | Registrar gasto | — | no | no | tab Money tenía solo row inert (FIX SHIPPED in-flight) | n/a | n/a | n/a | ✅ post-fix |
| 7 | Generar deuda | — | no | no | sí (form genérico, falta flujo tipado por kind) | n/a | n/a | n/a | ⚠️ |
| 8 | Resolver conflicto | — | no | no | warning no daba camino subsecuente (FIX SHIPPED in-flight) | n/a | n/a | n/a | ✅ post-fix |
| 9 | Tomar decisión | — | no | no | sí (CreateDecisionView desconectado del modelo) | n/a | n/a | n/a | ⚠️ |
| 10 | Subir documento | — | no | no | sí (no en toolbar, sin docs sueltos, sin catalog tipado) | n/a | n/a | n/a | ⚠️ |

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

---

## Hallazgos founder (en vivo 2026-06-09)

### Flow #1 — Crear familia · ⚠️
- **Síntoma:** `create_context` ejecuta OK; el sheet se cierra; el usuario queda en la tab Contextos viendo la lista. Espera era ser pusheado directo a `ContextDetailViewV2` del recién creado.
- **Fix candidato:** después de `create_context` exitoso, el handler del sheet recibe `CreatedContext.contextActorId` → emitirlo al shell para que la tab Contextos pushee el detail. Pattern análogo: post-`create_child_context` ya hace push automático.
- **Triaje:** UX gap, no es regresión. Agendado como **R.5Z.fix.1** post-smoke.

### Flow #2 — Crear casa · ⚠️ (3 hallazgos)
- **#2.a Toolbar desordenado en ContextDetailV2 / ResourceDetailV2.**
  - Síntoma: el toolbar muestra una opción por sección (Menu con Sections de 1 item cada una). No hay priorización.
  - Apple HIG: Section debe tener ≥2 items O agrupar primary actions sin Section. Hoy: `Explorar { Editar }`, `Gestión { Transferir }`, `Avanzado { Vista clásica }` — cada section con 1 item.
  - Fix candidato: colapsar a un Menu plano con orden por uso (Editar > Compartir > Transferir > Avanzado) o consolidar Sections (mín 2 items).
- **#2.b "Reservaciones del contexto" aparece dentro de `ResourcesListView`** (founder precisado 2026-06-09).
  - Síntoma: la lista de recursos del contexto incluye una section/card "Reservaciones del contexto". Scope creep: `ResourcesListView` debe listar recursos, no reservaciones.
  - Fix candidato: quitar esa Section de `ResourcesListView`. Reservaciones tienen su propio surface (`ContextReservationsView` + ContextDetailV2 tab "Reservaciones").
  - Agendado **R.5Z.fix.2.b**.
- **#2.c Post-create resource: sheet no se cierra ni pushea ResourceDetailV2.**
  - Síntoma: igual que Flow #1 pero peor — el sheet queda abierto. Founder tuvo que cerrarlo manualmente.
  - Fix candidato: en `CreateResourceFlow.onCreated`, `dismiss()` + emitir `resourceId` al shell para que ResourcesListView/ContextDetailV2 pushee el detail.
  - Agendado **R.5Z.fix.1** consolidado: post-create de Context · Resource · Event · Decision · Obligation TODOS deben auto-push al detail. Hoy ninguno lo hace consistente.

### Flow #3 — Invitar miembro · ⚠️
- **Síntoma:** después de invitar (`invite_member` o `create_invite`), el invitado no aparece en `MembersListView` mientras está en estado `invited` (pre-accept). El founder no sabe si la acción funcionó hasta que el invitado acepta.
- **Causa probable:** `MembersListView` filtra `actor_memberships` por `membership_status = 'active'` solo. Backend ya soporta status `invited`.
- **Fix candidato:** mostrar invited en la lista con badge "Invitado" (Theme.Tint.warning), separado en una Section "Pendientes de aceptar" o intercalado con badge visible. Pattern análogo: `PendingInvitationsView` (lado del invitee) ya existe.
- **Agendado R.5Z.fix.3.**

### Flow #4 — Crear evento · ⚠️ (2 hallazgos arquitecturales)
- **#4.a Falta flujo tipado por tipo de evento (analogía Subtype Picker para resources).**
  - Síntoma: `CreateEventView` muestra un flow único genérico. Founder espera flow específico por tipo (`gathering` · `meeting` · `ceremony` · `trip` · `appointment` · `celebration` · …) con campos relevantes a ese tipo.
  - Pattern análogo shipped: **Subtype Picker** para resources (commit `cbd6a249`) — wizard 3 pasos class → subtype → form específico por subtype.
  - Fix candidato: `CreateEventFlow` paralelo. Backend ya tiene `event_type` con taxonomy (verificar `calendar_events.event_type` enum y si existe catalog análogo a `resource_subtype_catalog`).
  - **Scope mayor** — no es R.5Z.fix simple. Agendado como **R.5Z.fix.4.a** con notación "scope = E.PICKER paralelo al Subtype Picker de R.5V".
- **#4.b Host rotation config siempre visible — debe ser conditional.**
  - Síntoma: las configuraciones de rotación de host aparecen en el form aunque el founder no quiera rotación.
  - Fix candidato: en `CreateEventView`, gating `if event.requiresHostRotation` (toggle/picker primero) → section solo si user opt-in.
  - Agendado **R.5Z.fix.4.b** (independiente de 4.a; small win).

### Flow #5 — Reservar recurso · ⚠️ (2 hallazgos arquitecturales)
- **#5.a Falta `reservation_policy` por recurso (granularidad + reglas configurables).**
  - Síntoma: hoy todas las reservaciones piden `startsAt`/`endsAt` con datetime picker genérico. Founder espera que cada recurso (o subtype) declare:
    - **Granularidad temporal:** día (casa de campo, palco, sala de fiestas) · slot horario (vehículo, cancha) · sesión nombrada (partido, función, ceremonia) · noche (hospedaje).
    - **Min/max duration:** noches mínimas, horas mínimas, etc.
    - **Advance booking window:** con cuántos días/horas se puede reservar.
    - **Requiere aprobación:** sí/no según subtype.
  - Modelo propuesto: `resources.metadata.reservation_policy` (o nueva tabla `resource_reservation_configs`) + defaults por subtype en `resource_subtype_catalog`.
  - Ejemplos founder:
    - `primary_residence`/`vacation_home` → policy=`day` (check-in / check-out fechas)
    - `palco` → policy=`event_slot` (selecciona partido del calendar, no horas)
    - `vehicle` → policy=`hour_slot` (slot de horas)
  - Fix candidato: ResourceSettingsView gana sección "Reservaciones" donde owner configura policy. `RequestReservationView` adapta UI según `resource.reservation_policy`.
  - **Scope mayor** — toca backend (policy field + defaults catalog) + iOS (settings + request view + detail view). Agendado **R.5Z.fix.5.a** = nuevo slice **R.RES.POLICY**.
- **#5.b UX `RequestReservationView` redesign estilo Airbnb.**
  - Síntoma: vista actual es Form genérico (DatePicker startsAt + DatePicker endsAt + nota). Founder espera: calendar visual mensual con días disponibles/bloqueados, tap para start → tap para end, total estimado, foto del recurso, claridad de "qué estás reservando".
  - Fix candidato: nuevo `RequestReservationView` con `RuulCalendarMonthGrid` (ya existe), hero del recurso, summary con noches + costo si aplica.
  - Bloqueo: depende de **#5.a** porque el calendar render cambia según policy (día vs slot horario vs partido). Si policy=`event_slot`, el "calendar" es una lista de eventos disponibles, no días.
  - Agendado **R.5Z.fix.5.b** dependiente de 5.a.
- **Triaje conjunto:** R.RES.POLICY (5.a) bloquea 5.b. Son los 2 ⚠️ más grandes del smoke hasta ahora.

### Flow #6 — Registrar gasto · ✅ post-fix
- **Síntoma pre-fix:** la tab Money de ContextDetailV2 solo mostraba "Liquidaciones abiertas: 0" en contexto vacío — un row inert sin valor. Founder: *"no me gusta la tab de money en context detail. solo veo un boton de generar liquidaciones que no es util"*.
- **Fix shipped in-flight (2026-06-09 mid-smoke):** `moneySections(_:)` rediseñado Apple-native:
  - **Empty state honesto:** icon + "Aún no hay actividad de dinero" + 2 CTAs primarias (`Registrar gasto` + `Asignar compromiso`).
  - **Estado con actividad:** Mi saldo (si > 0) → Acciones rápidas → Obligaciones recientes → Liquidaciones (solo si openSettlements > 0) → Ver historial.
  - **Settlements section solo cuando hay batches abiertos** — antes era siempre visible con "0".
  - Sheets para Record expense + Create obligation cableados directamente al body con `onDismiss → store.load()` para refresh.
- **Resultado:** founder pidió "sigue" → ack implícito. Build verde 17.5s + install iPhone JJ.

### Flow #7 — Generar deuda (compromiso) · ⚠️
- **Síntoma:** `CreateObligationView` es un form genérico con Picker de `kind` (action/approval/delivery/attendance/document/reservation/custom). Founder espera flujo específico por kind con campos relevantes.
- **Pattern consolidado** (3 hallazgos del smoke con la misma estructura — #2, #4.a, #7): TIPOS canónicos del modelo necesitan **flujo tipado per kind**.
  - Resource → Subtype Picker (✅ shipped commit `cbd6a249`).
  - Event → `E.PICKER` paralelo (⏳ R.5Z.fix.4.a).
  - Obligation → `O.PICKER` paralelo (⏳ R.5Z.fix.7).
- **Ejemplos de campos esperados por kind:**
  - `delivery` → ubicación de entrega, descripción del ítem, recipient esperado.
  - `attendance` → evento al que debe asistir, duración esperada.
  - `document` → tipo de documento, fecha de vencimiento, plantilla opcional.
  - `approval` → asunto de la aprobación, decisión vinculada (si aplica).
  - `action` → genérico (título + descripción + due) — flow más simple.
- **Slice emergente: O.PICKER** = wizard 2-step (kind picker → form específico por kind). Paralelo a Subtype Picker y E.PICKER. Catalog backend (`obligation_kind_catalog`?) si conviene.
- Agendado **R.5Z.fix.7**.

### Flow #8 — Resolver conflicto · ✅ post-fix
- **Síntoma pre-fix:** al crear una reserva con fechas solapadas, `RequestReservationView` mostraba un Label naranja inerte "Tu solicitud quedó registrada, pero hay 1 conflicto(s) de fechas. Un admin tendrá que resolverlo." — sin CTA. Founder (que ES admin/founder): *"me sale esto pero no debería haber una acción subsecuente?"*
- **Fix shipped in-flight (2026-06-09 mid-smoke):** Section reemplaza el Label inerte por:
  - Header tipográfico "Conflicto de fechas detectado" en `Theme.Tint.warning`.
  - Body con el detail del conflicto.
  - **NavigationLink "Ver y resolver el conflicto"** → push `ResourceDetailViewV2(resourceId)` dentro del mismo NavigationStack del sheet. El conflicto aparece en la `conflictsCard` arriba + tap dispara el `ConflictsModifier` 3-kind dialog (`Resolver manualmente / Escalar a decisión / Descartar`).
- **Resultado:** founder testó iPhone JJ → *"funciona"*. Build verde 14.7s + install.
- **Bonus arquitectural:** se confirmó que push de DetailV2 dentro de un sheet NavigationStack funciona limpio sin nested-sheet fragility (mismo pattern que MemberDetailView → DecisionDetailView en R.7.F).

### Flow #9 — Tomar decisión · ⚠️
- **Síntoma:** `CreateDecisionView` solo crea decisiones free-floating (título + voting model + opciones). Founder: *"las decisiones están desconectadas de todo el modelo. debería poder decidir sobre contextos, recursos, miembros, reglas, eventos, etc. y sobre decisiones que no están conectadas también."*
- **Estado backend (ya soporta el modelo correcto):**
  - `governance_actions` con `target_type` + `target_id` + `decision_id` (R.7.B).
  - Catalog `governance_action_catalog` con 12+ acciones target-scoped (R.7.A): `member.remove`/`pause`/`promote`, `resource.transfer`, `rule.archive`, `obligation.forgive`, etc.
  - `request_governance_action` ya crea decisiones target-scoped con payload custom (R.7.x.iOS shipped df255283).
- **Gap iOS:** `CreateDecisionView` no expone "decidir sobre qué". Hoy solo crea free-floating; las decisiones target-scoped solo se crean indirectamente desde detail views (MemberDetailV2 toolbar → `member.remove` → governance sheet, etc.).
- **Patrón emergente quinto** ("decision target picker"):
  - Resource Subtype Picker ✅ shipped.
  - E.PICKER (event type) ⏳ R.5Z.fix.4.a.
  - O.PICKER (obligation kind) ⏳ R.5Z.fix.7.
  - R.RES.POLICY (reservation policy per resource) ⏳ R.5Z.fix.5.
  - **D.PICKER (decision target type)** ⏳ R.5Z.fix.9 — paralelo a los anteriores.
- **Fix candidato (D.PICKER):** wizard 2-3 step en `CreateDecisionView`:
  1. **"¿Sobre qué decidir?"** — picker: Sin objetivo (free-floating) · Contexto · Recurso · Miembro · Regla · Evento · Decisión · Compromiso.
  2. **Entity picker** (si no es free-floating): lista de entidades del contexto del tipo elegido.
  3. **Acción canónica** (opcional, si target_type tiene actions en catalog): muestra acciones del `governance_action_catalog` filtradas por target_type. Si user elige una → usa `request_governance_action` (no `create_decision` directo). Si elige "Otra pregunta abierta" → free-form vote model + options.
- **Detail views relacionados** (lectura): ContextDetailV2 / ResourceDetailV2 / MemberDetailView / RuleDetailView / EventDetailView / DecisionDetailView deben mostrar Section "Decisiones relacionadas" filtrada por `target_type/id` coincidente. Lectura PostgREST sobre `decisions WHERE target_type = X AND target_id = Y`. (Hoy probablemente solo se ven en DecisionsListView del contexto.)
- **Scope:** mayor — backend probablemente OK, todo es iOS. Agendado **R.5Z.fix.9** como slice **D.PICKER**.

### Flow #10 — Subir documento · ⚠️ (3 hallazgos + AI vision)
- **#10.a "Subir documento" no surface en toolbar primario.** Hoy solo accesible desde tab Más → ContextDocumentsListView → toolbar. Founder espera que "Subir documento" sea un intent top-level del CreateIntentSheet (botón ➕) o esté en el toolbar de ContextDetailV2.
  - Fix candidato: agregar `intent.document` en `CreateIntentSheet` (paralelo a `intent.obligation` R.5X.fix.B shipped). Wire a `AttachDocumentView` con resource picker opcional (gating en #10.b shipping).
  - Agendado **R.5Z.fix.10.a**.
- **#10.b Falta soporte de documentos sueltos (sin recurso asignado).** Caso: estatutos del contexto, contratos macro, comprobantes administrativos no atados a un recurso específico. Hoy `register_document` (probablemente) requiere `resource_id`.
  - Fix candidato: backend — hacer `resource_id` nullable en `documents` table + `register_document` RPC. iOS — picker opcional "Recurso (opcional)" con default "Sin recurso → asignado al contexto".
  - Lectura: `ContextDocumentsListView` ya filtra por contexto; tras el fix mostraría sueltos + atados a recursos del contexto.
  - Agendado **R.5Z.fix.10.b** (scope: backend mig + iOS).
- **#10.c Catalog de tipos de documento tipado por resource/event type + AI vision auto-fill.**
  - Hoy `document_type` es free-form text.
  - Founder visión: catalog tipado con templates por contexto.
    - Casa (`primary_residence`) → escritura, factura predial, póliza de seguro, contrato de servicios, recibos.
    - Vehículo (`car`) → tarjeta de circulación, póliza, factura compra, mantenimientos.
    - Cena (`dinner_event`) → menú, factura restaurante, comprobante de pago.
    - Boda → contratos proveedores, presupuesto, facturas.
  - **AI vision (Apple Intelligence / FoundationModels):**
    - User sube imagen/PDF → AI detecta tipo (factura/comprobante/contrato).
    - AI sugiere: tipo de documento + recurso/evento ligado + fecha + monto si aplica.
    - Pattern análogo en repo: `ExpenseSuggestionService` ya existe (R.6.AI.7 — `ExpenseSuggestion.swift`). Aplicar mismo pattern para documentos.
  - Slice mayor: **D.CATALOG** = catalog backend `document_type_catalog` + tipado por resource_subtype/event_type + iOS picker tipado + AI service `DocumentSuggestionService`.
  - Agendado **R.5Z.fix.10.c** (escalable: empieza por catalog estático en backend, AI vision se suma cuando shipping seq lo permita).

---

## R.5Z Cierre — Resumen de la sesión (2026-06-09)

### Status final

| ✅ post-fix | ⚠️ con observación | ❌ blocker |
|---|---|---|
| 2 (Flows #6, #8) | 8 (Flows #1, #2, #3, #4, #5, #7, #9, #10) | 0 |

**Cero blockers (❌).** El stack funciona end-to-end. R.5Z **no bloquea R.6** per regla del plan (solo ❌ es blocker).

### 2 fixes shipped in-flight
- **Flow #6 — Money tab rebuild.** `moneySections(_:)` rediseñado con empty state honesto + CTAs primarias + sections condicionales. Antes mostraba solo "Liquidaciones abiertas: 0" inert.
- **Flow #8 — Reservation conflict NavigationLink.** Cuando crear reserva detecta conflicto, ahora muestra "Ver y resolver el conflicto" → push `ResourceDetailViewV2` dentro del sheet con conflictsCard + 3-kind dialog.

### Patrón mayor que emergió: **"Typed creation flows"**
5 slices con la misma estructura (Picker tipado → form específico por tipo):

| Slice | Estado | Founder rationale |
|---|---|---|
| Resource Subtype Picker | ✅ shipped (`cbd6a249`) | Casa ≠ Vehículo ≠ Palco — cada uno tiene policies y campos distintos |
| **E.PICKER** (event type) | ⏳ R.5Z.fix.4.a | Cena ≠ Boda ≠ Meeting — host rotation solo cuando aplica |
| **O.PICKER** (obligation kind) | ⏳ R.5Z.fix.7 | Delivery ≠ Attendance ≠ Document — fields per kind |
| **R.RES.POLICY** (reservation policy per resource) | ⏳ R.5Z.fix.5 | Casa = día · Palco = partido · Vehículo = hora · Airbnb-style UX |
| **D.PICKER** (decision target type) | ⏳ R.5Z.fix.9 | "Decidir sobre qué" — context/resource/member/rule/event/free-floating |
| **D.CATALOG** (document type per resource/event) | ⏳ R.5Z.fix.10.c | Casa → escritura/factura predial · vehículo → tarjeta circ · + AI vision auto-fill |

### Patrones menores
- **post-create dismiss + auto-push** (Flow #1, #2.c) — toda creación debería cerrar sheet y pushear al detail. `R.5Z.fix.1` consolidado.
- **Lista de miembros sin invitados pre-accept** (Flow #3) — Section "Pendientes" con badge. `R.5Z.fix.3`.
- **Toolbar Sections de 1 item** (Flow #2.a) — colapsar a Menu plano o agrupar. `R.5Z.fix.2.a`.
- **Widget "Reservaciones" en ResourcesListView** (Flow #2.b) — quitar. `R.5Z.fix.2.b`.

### Backlog ordenado (sugerencia para founder)

| Tier | Slice | Scope | Effort |
|---|---|---|---|
| **P0 quick wins** | `R.5Z.fix.1` (post-create push) · `R.5Z.fix.2.a` (toolbar) · `R.5Z.fix.2.b` (resources list scope) · `R.5Z.fix.3` (invited members) | iOS solo | small (~1h cada uno) |
| **P1 typed flows** | E.PICKER · O.PICKER · D.PICKER | iOS solo (backend ya soporta target_type/id en governance) | medium each |
| **P1 backend-iOS** | R.RES.POLICY (config per resource + UX Airbnb) · D.CATALOG (catalog tipado + AI vision) · #10.a (intent.document toolbar) · #10.b (docs sueltos backend mig) | mixto | large each |

### Founder rationale firmado pre-smoke

> *"Si esos 10 flujos funcionan de extremo a extremo, R.6 tendrá una base extremadamente estable."*

**Veredicto:** los 10 funcionan funcionalmente (cero ❌). Lo que falta es **pulido UX + tipado**. La base es **estable para R.6**, pero los 8 ⚠️ son alto valor y deberían ir antes de meter Rule Engine 2.0 encima para no acumular deuda compuesta.

**Decisión pendiente del founder:**
- (A) Cerrar R.5Z aquí, abrir R.6, fixes en paralelo.
- (B) Cerrar P0 quick wins + 1-2 P1 antes de abrir R.6.
- (C) Cerrar todo el backlog (typed flows + R.RES.POLICY + D.CATALOG) antes de R.6 — extiende timeline pero deja base sólida.

---

## Hallazgos cross-cutting (post-smoke 2026-06-09)

### CC.1 — ObligationDetailView: todas las acciones (excepto `forgive`) muestran "Próximamente"
- **Síntoma:** founder abre cualquier compromiso → toolbar `+` Menu muestra acciones (pay/dispute/cancel/mark_completed/edit_obligation). Al tap: todas salvo `forgive` (recién shipped R.7.x.iOS) y `mark_completed` + `edit_obligation` (legacy F.MONEY.4) muestran alert "Esta funcionalidad ya está modelada en Ruul, pero todavía no está disponible."
- **Causa:** `handleObligationAction` (R.7.x.iOS commit `df255283`) tiene branch para `forgive` + `mark_completed` + `edit_obligation`; el resto cae al `default` que dispara `comingSoonAction`. Backend tampoco tiene RPCs para `pay`/`dispute`/`cancel` aún.
- **Impacto:** ObligationDetailView se siente roto. El descriptor sigue surfaceando acciones que no funcionan.
- **Fix candidato (2 paths):**
  - (a) **Backend ships pay/dispute/cancel RPCs** + iOS los wirea siguiendo pattern R.7.x (forgive). Scope: backend + iOS per action.
  - (b) **iOS gating defensivo:** filtrar `availableActions` para esconder las que `handleObligationAction` no sabe handlear hoy. UX: el botón no aparece en vez de aparecer y fallar. Scope: iOS only (~20 LOC). Mientras backend implementa, descriptor sigue surfaceándolas.
- Agendado **R.5Z.fix.CC.1**. Recomendación: (b) ahora + (a) por slice.

### CC.2 — HomeView attention center: items muestran "Próximamente" al tap
- **Síntoma:** founder en tab Home → sección "Atención" muestra items → al tap cualquier item, sale el sheet `UnsupportedAttentionView` ("Próximamente").
- **Causa probable:** `AttentionDispatcher.destination(for:)` (R.5Y.A2 shipped) tiene catalog limitado de kinds soportados: `decision_open` · `obligation_due_soon` · `reservation_conflict` · `resource_conflict_direct` · `settlement_open`. Si los items en el inbox del founder son kinds nuevos (rule_attention_items R.6.A, document_expiring R.6.C.2, etc.) caen al fallback `UnsupportedAttentionView`.
- **Impacto:** P0 — el attention center es el "centro nervioso" de Ruul (founder lock R.5Y) y se ve roto.
- **Investigación pendiente:**
  1. Dump `attention_inbox()` para ver qué `kind` exactamente tiene el founder.
  2. Verificar AttentionDispatcher catalog vs los kinds reales en backend (`attention_inbox()` UNIONs).
- **Fix candidato:** extender AttentionDispatcher para nuevos kinds:
  - `rule_attention_items.*` (R.6.A shipped `8703ee2a`) → push a `ContextDetailViewV2` o RuleDetailView según `cta_target_type`.
  - `obligation.overdue` / `document.expiring` / `reservation.starting_soon` / `right.expiring` (R.6.C shipped) → push al detail correspondiente.
- Agendado **R.5Z.fix.CC.2**. P0 alto — el attention center es feature core.
