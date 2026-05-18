# Ruul — Consistency Jurisprudence Audit

**Status:** Audit doctrinal canónico — 2026-05-17. Founder-commissioned.
**Companion of:** `Plans/Active/Constitution.md` (los 12 artículos + §13 filtro), `Plans/Active/TalmudicGovernance.md` (lente operacional), `Plans/Active/AtomProjection.md` (regla mecánica), `Plans/Active/HierarchyReference.md` (tabla maestra), `Plans/Active/Governance.md` (rule engine spec), `Plans/Active/Vision.md` (estrategia), specs por resource type (`EventResource.md`, `Asset.md`, `Fund.md`, `Space.md`, `Slot.md`, `Right.md`).
**Output:** 5 nuevas doctrinas companion (`OperationalCacheDoctrine.md`, `ProjectionDoctrine.md`, `RightRules.md`, `ResourceLinkDoctrine.md`, `RuleEngineDoctrine.md`) y un remediation roadmap clasificado.

**Premisa:** Ruul ya tiene los 6 resource types canónicos, capabilities, links, rules, atoms, projections, caches, rule engine, versioning, audit trail. La pregunta no es "qué agregamos". La pregunta es **qué está mal clasificado, qué duplica verdad, qué es cache disfrazada de truth, y qué viola la doctrina ya escrita**.

---

## 0 — Executive Summary

Ruul está **doctrinalmente fuerte en superficie y débil en bordes específicos**. El núcleo (Group, Resource, atoms append-only, rule engine server-only, capability catalog) es coherente y enforced por triggers SQL. Los 6 resource types están especificados. Pero el audit de implementación contra la doctrina expone **siete violaciones reales** que necesitan corrección antes de Beta production:

1. **`pay_fine` está rota en producción.** La función live (`pg_proc.prosrc`) referencia las columnas `groups.fund_balance` y `groups.fund_enabled` que fueron dropeadas en mig 00078. Cualquier llamada a `pay_fine` falla con `record has no field`. **HERESY** — hard bug, dinero bloqueado.

2. **`right` resource: holder vive en `resources.metadata`, no en projection.** `transfer_right` hace `UPDATE resources SET metadata = metadata || '{holder_member_id:...}'` y emite `rightTransferred` como decoración. Atoms son audit shadow, no source of truth. Borrar/corromper metadata reescribe holder silenciosamente sin trail. **DOCTRINAL VIOLATION** — viola Artículo 7 (atoms = única verdad histórica) y Artículo 8 (projection ≠ truth).

3. **`fund_lock` / `fund_unlock` mutan `resources.metadata` directamente.** Atoms (`fundLocked`/`fundUnlocked`) se emiten después como decoración. `fund_balance_view` lee `locked_at` desde metadata. **DOCTRINAL VIOLATION** — mismo patrón que right: cache es truth.

4. **`slot.status` es truth mutable sin atoms recomputables.** No existe `slotCreated` ni `slotReleased` atom. `book_slot` flips `resources.status` directamente. Si la fila se corrompe, no se puede recomputar desde atoms. **DOCTRINAL VIOLATION** — viola la regla "cache aceptable IF recomputable desde atoms" (OperationalCacheDoctrine.md).

5. **`rule_evaluations` schema-correct pero write-dead.** Mig 00181 creó la tabla con `idempotency_key UNIQUE` exactamente para prevenir doble-ejecución de consequences en retry. **El engine nunca INSERT en ella.** Cada sink reimplementa su propio dedup ad-hoc; `emitWarning` no tiene ninguno. **DOCTRINAL VIOLATION** — viola la promesa de idempotency.

6. **`resource_links` solo tiene `'uses'` kind.** Los 4 kinds doctrinales (`owns`, `funds`, `scheduled_in`, `grants_access_to`) no existen en el `check_link_kind`. `grants_access_to → source must be right` no se puede verificar porque el kind no existe. Tabla nombrada genéricamente pero es `event_resource_links` semánticamente. **DOCTRINAL VIOLATION** — viola la promesa polimórfica de Link Doctrine.

7. **`archive_resource` / `unarchive_resource` mutan sin emitir atom** a pesar de `resourceArchived` estar whitelisted. `setBookingsLocked` (rule consequence en `process-system-events`) escribe `resources.metadata` directamente desde edge function code, bypaseando RPC. `transfer_asset` muta `resources.metadata.owner_id`. **DOCTRINAL VIOLATIONS** — mismo patrón sistémico que right/fund.

**Aceptables (cache documentada):** `system_events.processed_at` (partial guard mig 00162), `user_actions.resolved_at` (partial guard mig 00166), `resources.metadata.custodian_id` (asset — atom emitido por la misma RPC), `bookings.slot_id` (asset/space/slot polymorphic target), `votes.status`, `fines.status`/`paid` (instruments, no atoms).

**Doctrina sólida:** Constitution + Atom/Projection enforcement (5+2 atom tables con guards), Space resource (post-mig 00264 limpio), Event resource (post-mig 00159 limpio), Fund movement (`fund_contribute`/`fund_record_expense` → `ledger_entries` → `fund_balance_view`), rule engine server-only + deterministic + pure, ledger types CHECK constraint, vote_casts append-only post-00163.

**Veredicto:** Ruul está doctrinalmente sano para el 80% del sistema. El 20% restante (right, fund_lock, slot.status, rule_evaluations dead-write, resource_links narrow, archive missing atoms, pay_fine broken) representa **deuda crítica para Beta**. Ninguno requiere rediseño ontológico — todos son fixes localizados que aplican la doctrina ya escrita.

---

## 1 — Findings Table (clasificadas)

| # | Hallazgo | Tabla / RPC / Edge fn | Mig refs | Clase | Prioridad |
|---|---|---|---|---|---|
| F1 | `pay_fine` referencia columnas dropeadas (`groups.fund_balance`, `g.fund_enabled`) | `public.pay_fine` (función live) | 00078 dropped, 00148/00150/00233 still ref | **HERESY** | Must fix before Beta |
| F2 | Right holder vive en `resources.metadata`, mutado por `transfer_right`; atoms son decoración | `transfer_right`, `delegate_right`, `revoke_right`, `suspend_right`, `restore_right`, `expire_due_rights`, `right_holders_view` | 00198, 00199, 00200, 00252 | **DOCTRINAL VIOLATION** | Must fix before Beta |
| F3 | `fund_lock` / `fund_unlock` mutan `resources.metadata.locked_*`; atoms decoración | `fund_lock`, `fund_unlock`, `fund_balance_view` | 00203 | **DOCTRINAL VIOLATION** | Must fix before Beta |
| F4 | `slot.status` mutable sin atoms `slotCreated` / `slotReleased`; no recomputable | `book_slot`, `assign_slot`, `create_slot`, `SlotRepository` | 00070, 00216 | **DOCTRINAL VIOLATION** | Must fix before Beta |
| F5 | `rule_evaluations` definida pero engine nunca INSERT — dedup contract dead | `process-system-events/index.ts`, `_shared/ruleEngine.ts` | 00181 (definition), unwritten in code | **DOCTRINAL VIOLATION** | Must fix before Beta |
| F6 | `resource_links.link_kind` check constraint solo permite `'uses'`; 3 kinds doctrinales ausentes | `resource_links`, `link_resource_to_event` | 00202 | **TRANSITIONAL DEBT** | Post-Beta |
| F7 | ~~`archive_resource` / `unarchive_resource` mutan sin emitir `resourceArchived` atom~~ — **MISDIAGNOSED 2026-05-17**: trigger `on_resource_archive_toggle` → `handle_resource_archive_toggle` emite atoms atómicamente con la UPDATE. Pre-existente. Mig 00276 introdujo double-emit y se revirtió en mig 00277. | `archive_resource`, `unarchive_resource` | trigger (pre-mig) | **CLEAN (misdiagnosed)** | None — closed |
| F8 | `setBookingsLocked` (rule consequence) muta `resources.metadata` directamente desde edge function | `process-system-events/index.ts:403-446` | rule shape `lockBookings` | **DOCTRINAL VIOLATION** | Must fix before Beta |
| F9 | `transfer_asset` muta `resources.metadata.owner_id` directamente; atom solo decoración | `transfer_asset` | 00210 | **DOCTRINAL VIOLATION** | Post-Beta |
| F10 | `update_right_metadata` emite **cero atoms** para cambios en `transferable`/`expires_at`/`priority`/`exclusive` | `update_right_metadata` | 00199 | **DOCTRINAL VIOLATION** | Must fix before Beta |
| F11 | `record_ledger_entry` whitelist interna stale (7 tipos); CHECK constraint declara 11 | `record_ledger_entry` (00082) vs CHECK 00167 | 00082, 00167 | TRANSITIONAL DEBT | Post-Beta |
| F12 | `resource_links` sin atom_guard trigger; soft-delete depende de RPC discipline | `resource_links` | 00202 | TRANSITIONAL DEBT | Post-Beta |
| F13 | `notifications_outbox` mutable sin guard; podría tener partial guard | `notifications_outbox` | 00022 | DOCUMENTATION ONLY | Doc only |
| F14 | `rule_versions.status` unguarded inside guard — docstring claims "active → superseded/inactive" pero status field no está restringido | `rule_versions` | 00181 | TRANSITIONAL DEBT | Post-Beta |
| F15 | `book_slot` no idempotente — sin dup-check por (slot, member) | `book_slot` | 00216 | DOCTRINAL VIOLATION (mild) | Post-Beta |
| F16 | `member_capability_overrides` row mutable (`effective_until`) sin atom de deactivation | `member_capability_overrides` | 00181 | TRANSITIONAL DEBT | Post-Beta |
| F17 | Space `resources.status='active'` set once, never touched — dead field | `resources` (space rows) | 00207 | DOCUMENTATION ONLY | Doc only |
| F18 | Fund `metadata.target_amount_cents` mutable post-create sin DB guard (no setter hoy pero abierto) | `resources` (fund rows) | 00139 | TRANSITIONAL DEBT | Doc + add guard |
| F19 | `data_deletion_log` / `data_subject_rights_requests` referenced pero CREATE TABLE no encontrado en migrations | varias migs | 00172, 00174, 00260 | INVESTIGATE | Audit-time |
| F20 | Right resource: 9 atoms entran a `system_events` pero NO hay projection `right_state_view` que recompute desde atoms | `right_holders_view`, `system_events` | 00198 | DOCTRINAL VIOLATION | Pair con F2 |
| F21 | `vote_casts` retiene rows con `choice='pending'` pre-seeded en `start_vote`; no guard contra dup pre-seed (UNIQUE droppeado en 00163) | `start_vote`, `vote_casts` | 00163 | TRANSITIONAL DEBT | Doc only |
| F22 | Slot atom `slotCreated` ausente — slot creation is unauditable from atoms; mig 00204 lo justifica como "operational, not governance-relevant" pero contradice doctrina general | `create_slot` | 00070, 00204 | DOCTRINAL VIOLATION | Must fix before Beta |

**Conteo:** 22 hallazgos. **1 HERESY** (F1). **10 DOCTRINAL VIOLATIONS** (F2-F5, F8, F10, F15, F20, F22). **6 TRANSITIONAL DEBT**. **3 DOC ONLY**. **1 INVESTIGATE**. **1 MISDIAGNOSED→CLEAN** (F7).

---

## 2 — Axiom Catalog (jurisprudencia canónica)

Reglas doctrinales escritas en formato Talmúdico — cada axioma con definición, ejemplo correcto, ejemplo incorrecto, implicación técnica, tablas afectadas, y método de audit futuro.

### Axiom 1 — Act > State

**Definición:** Todo cambio importante deja un acto (atom append-only) antes de modificar cualquier estado. El estado es proyección del acto, no su origen.

**Correcto:** `fund_contribute` → `INSERT INTO ledger_entries (type='contribution', ...)` → trigger emite `fundDeposit` → `fund_balance_view` deriva.

**Incorrecto:** `fund_lock` → `UPDATE resources SET metadata.locked_at = now()` → `INSERT INTO system_events ('fundLocked', ...)`.

**Implicación:** Atoms se escriben PRIMERO. Estado se deriva. Cache mutable solo si recomputable desde atoms y documentada.

**Tablas afectadas:** todas las tablas con `*_atoms` semántica + tablas que tienen state mutable derivable.

**Audit:** grep en RPCs para `UPDATE ... metadata` antes de cualquier `INSERT INTO system_events`. Si existe, violación.

---

### Axiom 2 — Ownership ≠ Access

**Definición:** Owner (quien tiene el derecho legal/social) ≠ accessor (quien puede usar). Owner cambia raro, access cambia seguido.

**Correcto:** Auto compartido — owner = group; custodian (quien lo tiene esta semana) = relation mutable derivada de `custodyAssigned` atoms.

**Incorrecto:** Modelar custodian como `resources.metadata.owner_id` y mutarlo en cada cambio de custodia.

**Implicación:** Custody tiene atoms separados (custodyAssigned/Released). Owner es atom de transfer raro.

**Tablas afectadas:** `resources` (asset), `system_events` (custody.*, asset.transferred).

**Audit:** Tests verificando que `transfer_asset` no muta custodian, y que `assign_custody` no muta owner.

---

### Axiom 3 — Ownership ≠ Occupancy

**Definición:** Owner (quien posee) ≠ occupant (quien físicamente está usando).

**Correcto:** Palco propiedad del grupo (asset/space); occupant del partido del jueves = derivado de `check_in_actions`.

**Incorrecto:** `space.metadata.current_occupant = ...` flipped en cada check-in.

**Tablas afectadas:** `resources` (space, asset), `check_in_actions`, `bookings`.

**Audit:** Tests `test_check_in_does_not_mutate_resource_owner`.

---

### Axiom 4 — Booking ≠ Waitlist

**Definición:** Booking es claim activo. Waitlist es claim pospuesto. Al llegar a capacidad, el sistema NO promueve booking → waitlist sin consentimiento explícito.

**Correcto:** `book_space` raise excepción cuando at-capacity. UI muestra "lleno, ¿join waitlist?". Usuario click → `join_waitlist`.

**Incorrecto:** `book_space` auto-crea waitlist row si capacidad llena y devuelve "queued".

**Implicación:** Dos atoms distintos (`bookingCreated` vs `spaceWaitlistJoined`). Dos RPCs distintos. Dos UX states distintos.

**Tablas afectadas:** `bookings`, `system_events`.

**Audit:** `test_book_space_at_capacity_does_not_auto_waitlist`. Verificado limpio en mig 00266 — mantener.

---

### Axiom 5 — Request ≠ Approval

**Definición:** Solicitar una acción es un atom (`*Requested`). Aprobarla es otro atom (`*Approved`). El acto solicitado no se ejecuta hasta el approve.

**Correcto:** `request_slot_swap` → `slotSwapRequested` atom + abre vote. Vote close → `slotSwapApproved` atom → entonces swap se ejecuta.

**Incorrecto:** `swap_slot` directo que muta sin workflow.

**Tablas afectadas:** `votes`, `pending_changes`, `user_actions`, `system_events`.

---

### Axiom 6 — Right ≠ Permission

**Definición:** Right es claim transferible que vive en `resources(type=right)` con holder, scope, target. Permission es flag de role en `groups.roles[].permissions`. Right se posee; permission se gatea.

**Correcto:** "Jose tiene equity de palco" = right resource con holder=Jose. "Admins pueden crear funds" = permission `createFund` en role `admin`.

**Incorrecto:** "Jose tiene permiso de usar palco" como ACL row mutable. O modelar permission como right resource.

**Tablas afectadas:** `resources` (right), `groups.roles` (jsonb).

**Audit:** Reviewer verifica que cualquier "permission" nuevo entre como flag, no como resource. Cualquier "claim transferible" entre como `right`.

---

### Axiom 7 — Capability ≠ Surface

**Definición:** Capability es comportamiento posible declarado en `capabilities` table. Surface es UI section que renderiza si capability está activa. Capability sin surface = silenciosa. Surface sin capability = imposible.

**Correcto:** Asset con `custody` activa → `AssetCustodySection` aparece en UniversalResourceDetailView, gateado por capability flag.

**Incorrecto:** UI condicional por `resource_type` ("if asset show custody"), saltándose capability check.

**Tablas afectadas:** `resource_capabilities`, `capabilities`.

**Audit:** grep en iOS para `if resource.resource_type == .asset` que renderice secciones. Debería ser `if capabilities.contains(.custody)`.

---

### Axiom 8 — Fund ≠ Ledger

**Definición:** Fund es el resource (propósito + autoridad + governance). Ledger es el atom (movimiento). Fund balance es projection sobre ledger.

**Correcto:** `funds.metadata.target_amount_cents` es config. `ledger_entries(type='contribution', resource_id=fund.id)` es el atom. `fund_balance_view` deriva.

**Incorrecto:** `funds.metadata.balance_cents` mutado en cada contribución.

**Tablas afectadas:** `resources` (fund), `ledger_entries`, `fund_balance_view`.

**Audit:** `test_fund_balance_view_derives_from_ledger_entries_only`. Verificar `fund_balance_view` no consulta `resources.metadata.balance`.

---

### Axiom 9 — Space ≠ Asset

**Definición:** Space es lugar (ocupación, disponibilidad, capacidad). Asset es objeto (custody, valuation, transfer). Un palco puede ser cualquiera según qué domina la coordinación — pero NO ambas en la misma fila.

**Correcto:** Palco modelado como `asset` si lo que importa es custody/valuation/transfer. Modelado como `space` si lo importante es booking/capacity.

**Incorrecto:** Asset que se reserva con `book_space`. O space que tiene `transfer_asset`.

**Tablas afectadas:** `resources.resource_type`.

---

### Axiom 10 — Event ≠ Calendar Row

**Definición:** Event es coordinación temporal social — RSVP, check-in, lineup, fines, governance. Calendar row es solo "algo con fecha". Event tiene atoms y projections; calendar row no.

**Correcto:** `resources(type=event)` con `event.metadata.starts_at`, `rsvp_actions`, `check_in_actions`, `attendance_view`.

**Incorrecto:** Tabla `events` con `attendees_count` mutable.

**Tablas afectadas:** `resources` (event), `events_view`, `attendance_view`.

---

### Axiom 11 — Slot ≠ Booking

**Definición:** Slot es la unidad atómica reservable (la silla, el turno, la mesa). Booking es el claim sobre slot (atom). Slot existe siempre; booking aparece y desaparece.

**Correcto:** `resources(type=slot)` persistente + `bookings(slot_id=...)` atom.

**Incorrecto:** Crear nuevo slot row por cada booking.

**Tablas afectadas:** `resources` (slot), `bookings`.

---

### Axiom 12 — Projection ≠ Truth

**Definición:** Projection es view recomputable desde atoms. Si la projection se borrara, los atoms la regeneran. Truth está en atoms, no en projection.

**Correcto:** `fund_balance_view`, `attendance_view`, `space_availability_view`, `right_holders_view` (idealmente — ver F2).

**Incorrecto:** `fund_balance` como columna mutable. `current_occupants` como array updated en cada check-in.

**Tablas afectadas:** todas las `*_view` + cualquier projection table futura.

**Audit:** Cada projection declara source atoms + reduction logic + recompute strategy en `ProjectionDoctrine.md` registry.

---

### Axiom 13 — Cache ≠ Doctrine

**Definición:** Mutable field en una tabla atom-like o resource-like es **cache aceptable** solo si:
1. Cada cambio emite un atom canónico
2. RLS prohíbe UPDATE directo por authenticated
3. Recompute desde atoms siempre gana sobre cache divergente
4. Docs declaran explícitamente "este field es cache"
5. Tests verifican consistency cache vs atoms

Sin esos 5, el "cache" es deuda doctrinal disfrazada.

**Correcto:** `system_events.processed_at` (mig 00162 — partial guard, dedicado a cron, documentado).

**Incorrecto:** `resources.metadata.holder_member_id` mutado por `transfer_right` sin guard.

**Tablas afectadas:** Cualquier tabla con state mutable.

**Audit:** `OperationalCacheDoctrine.md` registry de cada cache field aceptado, con sus 5 condiciones cumplidas explícitamente.

---

### Axiom 14 — Rule ≠ Mutation

**Definición:** Una rule evaluada por el engine NO escribe state directamente. Emite atoms o arranca workflows. El resultado del workflow puede emitir atoms que cambien state visible.

**Correcto:** Rule "si daño > $5,000 → require approval" → engine emite `userActionAssetApprovalCreated` atom → user_actions row aparece → resolución es otro atom.

**Incorrecto:** Rule consequence que hace `UPDATE resources SET metadata.bookings_locked = true` desde edge function (F8).

**Tablas afectadas:** `rule_evaluations`, `system_events`, todas las que rule consequences tocan.

---

### Axiom 15 — Link ≠ Automation

**Definición:** Resource link es relación estructural (`event uses asset`). NO ejecuta side effects, NO transfiere permisos automáticamente, NO crea otros atoms.

**Correcto:** `link_resource_to_event(event, palco)` → `resource_links` row + `resourceLinked` atom. Eso es todo. Si quieres que palco "permita acceso a invitados del event", eso es una rule sobre el event.

**Incorrecto:** `link_resource_to_event` que automáticamente concede `grant_space_access` a todos los confirmed RSVPs.

**Tablas afectadas:** `resource_links`, `system_events`.

---

### Axiom 16 — AI Suggestion ≠ Governance Action

**Definición:** AI propone — nunca aplica. Sugerencias de AI entran como drafts (pending_changes), votes, o user_actions. Humano confirma → entonces el acto ocurre y emite atom.

**Correcto:** AI sugiere "agrega regla X" → genera draft rule → admin publica → engine ejecuta.

**Incorrecto:** AI emite atom directo. AI muta state. AI confirma su propia propuesta.

**Tablas afectadas:** todas (AI debe ir vía workflow tables, nunca atom tables).

---

## 3 — Resource-by-Resource Audit

### 3.1 — `event`

| Dimensión | Status | Notas |
|---|---|---|
| Ontología | ✅ CLEAN | Coordinación temporal social. Spec canónica EventResource.md. |
| Atoms | ✅ CLEAN | `eventCreated`, `eventUpdated`, `eventCancelled`, `eventStarted`, `eventEnded`, `eventDeadlinePassed`. Mig 00256 agregó `eventUpdated`. |
| Projections | ✅ CLEAN | `events_view` (drop-in compat mig 00156), `attendance_view`, `vote_counts_view`. |
| Mutable fields | ⚠️ ACCEPTABLE CACHE | `resources.status` (event: scheduled/completed/cancelled) mutable, pero atoms `eventStarted`/`eventEnded`/`eventCancelled` lo respaldan y `events_view` puede recomputar. Doctrinalmente acceptable cache si OperationalCacheDoctrine.md lo registra. |
| Capabilities | ✅ CLEAN | 11 declaradas, todas stable. |
| Links | ⚠️ TRANSITIONAL | Solo `'uses'` kind existe (F6). Necesita expansión. |
| Governance | ✅ CLEAN | Rules engine integrado vía `process-system-events`. Precedence `occurrence > resource > series > group > global`. |
| Violations | F6 (link kind) — narrow but used. |
| Verdict | **CLEAN** post-mig 00159 + 00256. |

### 3.2 — `fund`

| Dimensión | Status | Notas |
|---|---|---|
| Ontología | ✅ CLEAN | Pool monetario gobernable. Spec canónica Fund.md. |
| Atoms | ✅ CLEAN para movimiento | `ledger_entries` con 7 tipos en uso + 4 reservados. `fundCreated`, `fundDeposit`, `fundThresholdReached` en `system_events`. |
| Projections | ✅ CLEAN | `fund_balance_view` puro view sobre `ledger_entries`. No materialized. |
| Mutable fields | ❌ VIOLATION | `resources.metadata.locked_at`/`locked_by`/`locked_reason` mutados por `fund_lock`/`fund_unlock` (F3). Atom es decoración. |
| Lock state | ❌ VIOLATION | Lock debería derivar de proyección sobre `system_events WHERE event_type IN ('fundLocked','fundUnlocked')` ordered by occurred_at. Hoy lock es metadata mutable. |
| `target_amount_cents` | ⚠️ TRANSITIONAL | Inmutable post-create de facto (no setter existe), pero sin DB guard. Si futura RPC lo permite mutar sin atom → violation (F18). |
| Violations | F3 (fund_lock), F18 (target unguarded), F1 (pay_fine broken referencing dropped fund_balance) |
| Verdict | **MOSTLY CLEAN — Lock state is the violation.** Movement (contribute/expense) es ejemplar. |

### 3.3 — `asset`

| Dimensión | Status | Notas |
|---|---|---|
| Ontología | ✅ CLEAN | Objeto persistente con identidad propia. Spec canónica Asset.md. |
| Atoms | ✅ CLEAN | 12 atoms canónicos (mig 00204): custody.*, maintenance.*, damage.reported, asset.*, valuation.*. |
| Projections | ✅ CLEAN | 4 vistas canónicas (mig 00212): asset_current_custodian_view, asset_valuation_view, asset_maintenance_status_view, asset_usage_history_view. |
| Mutable fields | ❌ VIOLATION | `transfer_asset` muta `resources.metadata.owner_id` directamente (F9). Mismo patrón que right. |
| Custody | ✅ CLEAN | `custodyAssigned`/`Released` atoms + `asset_current_custodian_view` projection. |
| Bookings | ✅ CLEAN | `bookings` table append-only post-mig 00216. |
| Archive | ❌ VIOLATION | `archive_resource` muta sin emitir `resourceArchived` (F7). |
| Violations | F7 (archive), F9 (transfer_asset owner mutation) |
| Verdict | **MOSTLY CLEAN — ownership transfer + archive son los puntos sucios.** Custody, maintenance, valuation son ejemplares. |

### 3.4 — `space`

| Dimensión | Status | Notas |
|---|---|---|
| Ontología | ✅ CLEAN | Lugar administrable. Spec canónica Space.md. |
| Atoms | ✅ CLEAN | 8 atoms (mig 00264): spaceCreated, spaceBooked, spaceReleased, spaceCapacityReached, spaceWaitlistJoined, spaceWaitlistPromoted, spaceAccessGranted, spaceAccessRevoked. |
| Projections | ✅ CLEAN | 4 vistas (mig 00267): space_availability_view, space_capacity_view, space_occupancy_view, space_history_view. Todas `security_invoker=on`. |
| Mutable fields | ⚠️ DEAD FIELD | `resources.status='active'` set una vez, nunca tocada (F17). Harmless pero ruidoso. |
| Booking | ✅ CLEAN | `book_space` raise at-capacity, no auto-waitlist (Axiom 4 honored). |
| Waitlist | ✅ CLEAN | Derivado de atoms (no tabla dedicada). Consent explícito. |
| Access control | ✅ CLEAN | `spaceAccessGranted/Revoked` atoms; admin-only RPCs. |
| Violations | F17 (cosmetic only). |
| Verdict | **EXEMPLARY.** Post mig 00264-00270 es el resource type más doctrinalmente sano. Modelo a seguir. |

### 3.5 — `slot`

| Dimensión | Status | Notas |
|---|---|---|
| Ontología | ⚠️ PARCIAL | Unidad atómica reservable. Spec canónica Slot.md. |
| Atoms | ❌ INCOMPLETE | `slotAssigned`, `slotDeclined`, `slotExpired`, `slotSwapRequested`, `slotSwapApproved` whitelisted. **NO `slotCreated`** (F22), **NO `slotReleased`**. |
| Projections | ❌ MISSING | No existe `slot_view` / `slot_availability_view`. iOS lee directo de `resources`. |
| Mutable status | ❌ VIOLATION | `resources.status` (unassigned/assigned/booked) flipped por `book_slot`/`assign_slot`. Sin atoms recomputables → no es cache aceptable (F4). |
| Booking | ⚠️ NOT IDEMPOTENT | `book_slot` sin dup-check (F15). |
| `bookings.slot_id` overloaded para spaces también — naming hazard pero no violation. |
| Violations | F4 (status non-recomputable), F15 (not idempotent), F22 (missing slotCreated). |
| Verdict | **DOCTRINAL DEBT.** Necesita slotCreated/slotReleased atoms + slot_state_view projection antes de Beta. |

### 3.6 — `right`

| Dimensión | Status | Notas |
|---|---|---|
| Ontología | ✅ CLEAN | Claim transferible. Spec canónica Right.md. |
| Atoms | ✅ CLEAN | 9 atoms: rightCreated/Transferred/Delegated/Revoked/Expired/Exercised/Suspended/Restored/ExpiringSoon. |
| Projections | ❌ DEGENERATE | `right_holders_view` **lee de `resources.metadata`**, NO de atoms (F20). Es una projection en nombre, no en sustancia. |
| Mutable fields | ❌ VIOLATION | `transfer_right`/`delegate_right`/`revoke_right`/`suspend_right`/`restore_right` mutan `resources.metadata` directamente (F2). Atom es decoración post-mutation. |
| `update_right_metadata` | ❌ VIOLATION | No emite atom para cambios en `transferable`, `expires_at`, `priority`, `exclusive`, `target_resource_id` (F10). Knobs normativos pueden cambiar silenciosamente. |
| Expiration | ⚠️ HYBRID | Cron-driven (lee `metadata.expires_at`) + status flip + atom emit. Decision basada en metadata mutable; resultado es atom (acceptable). |
| Possession vs exercise | ✅ CLEAN | `exercise_right` no muta holder. Solo escribe `last_exercised_at` cache + emite `rightExercised`. Atom es la verdad. |
| Right vs Permission | ✅ CLEAN | Mig 00255 introduce 5 permission flags (transferRight/delegateRight/etc) en `groups.roles`. Naming collision pero no structural — permissions gate RPCs, rights son claims. |
| Violations | F2 (holder mutation), F10 (update_right_metadata silent), F20 (no atom-derived projection) |
| Verdict | **DOCTRINAL VIOLATION GRAVE.** Atoms se escriben pero son audit shadow. Para honrar Axiom 12 necesita `right_state_view` rebuilt from `system_events`. |

---

## 4 — RPC Audit (los críticos)

### Clean (atom-backed, idempotent o defensible)

| RPC | Atom emit | Mutation | Idempotent | Verdict |
|---|---|---|---|---|
| `fund_contribute` | `ledger_entries(contribution)` → trigger `fundDeposit` | — | Soft | ✅ CLEAN |
| `fund_record_expense` | `ledger_entries(expense)` | — | Soft | ✅ CLEAN |
| `create_event_v2` | `eventCreated` + insert resource | INSERT | Y | ✅ CLEAN |
| `set_rsvp_v2` | `rsvp_actions` row | — | INSERT-only | ✅ CLEAN |
| `check_in_v2` | `check_in_actions` row | — | INSERT-only | ✅ CLEAN |
| `book_space` | `bookings` + `bookingCreated` + `spaceBooked` (+ `spaceCapacityReached` cond.) | — | Soft | ✅ CLEAN |
| `cancel_booking` (space) | `bookingCancelled` + `spaceReleased` | — | Y (atom dedup) | ✅ CLEAN |
| `join_waitlist` (space) | `spaceWaitlistJoined` | — | Y | ✅ CLEAN |
| `promote_space_from_waitlist` | `spaceWaitlistPromoted` | — | Implicit | ✅ CLEAN |
| `log_maintenance` (asset) | `maintenanceLogged` | — | N | ✅ CLEAN |
| `complete_maintenance` (asset) | `maintenanceCompleted` | — | N | ✅ CLEAN |
| `report_damage` (asset) | `damageReported` | — | N | ✅ CLEAN |
| `record_valuation` (asset) | `valuationRecorded` | — | N | ✅ CLEAN |
| `assign_custody` (asset) | `custodyAssigned` | — | N | ✅ CLEAN |
| `link_resource_to_event` | `resourceLinked` + insert resource_links | — | Y | ✅ CLEAN (within narrow kind) |
| `unlink_resource_from_event` | `resourceUnlinked` + UPDATE unlinked_at | UPDATE (soft delete) | Y | ✅ ACCEPTABLE CACHE |
| `exercise_right` | `rightExercised` | UPDATE last_exercised_at | N | ✅ ACCEPTABLE CACHE (timestamp only) |

### Doctrinal violations

| RPC | Problem | Fix |
|---|---|---|
| `pay_fine` | References dropped columns `groups.fund_balance` / `g.fund_enabled` | **F1 critical** — rewrite to emit `ledger_entries(type='fine_paid', resource_id=fine.fund_id, ...)` if fund_enabled (look up from `fund` resource by group_id); remove direct mutation. |
| `fund_lock` / `fund_unlock` | Mutate `resources.metadata.locked_*` directly | **F3** — derive `fund_locked` from projection on `system_events WHERE event_type IN ('fundLocked','fundUnlocked')`. Drop metadata write. |
| `transfer_right` / `delegate_right` / `revoke_right` / `suspend_right` / `restore_right` | Mutate `resources.metadata` for holder/delegate/suspension | **F2** — create `right_state_view` derived from `system_events`. Drop metadata writes (keep only as fast-path cache marked deprecation). |
| `update_right_metadata` | No atom emitted for knob changes | **F10** — emit `rightMetadataUpdated` atom with diff payload. Or split into per-knob RPCs each with own atom. |
| `expire_due_rights` | UPDATE status directly (cron) | **F2 followup** — emit `rightExpired` atom; let projection derive status. |
| `archive_resource` / `unarchive_resource` | UPDATE archived_at without emitting `resourceArchived` atom | **F7** — emit atoms. |
| `transfer_asset` | Mutate `resources.metadata.owner_id` | **F9** — derive ownership from `assetTransferred` atom projection. |
| `book_slot` / `assign_slot` / `create_slot` | Flip `resources.status` without recomputable atom set | **F4, F22** — add `slotCreated` and `slotReleased` atoms; create `slot_state_view`; drop status mutation. |
| `book_slot` | Not idempotent | **F15** — add dup-check by (slot_id, booker_id, status). |
| `record_ledger_entry` | Stale internal whitelist (7 types vs 11 CHECK) | **F11** — sync to canonical 11 list. |
| `setBookingsLocked` (edge fn, rule consequence) | Mutates `resources.metadata.bookings_locked` from edge function | **F8** — introduce `lock_asset_bookings(asset_id, rule_id, reason)` RPC that emits `assetBookingsLocked` atom; consequence sink calls RPC instead. |

### Process-system-events

| Aspect | Status |
|---|---|
| Server-only | ✅ |
| Deterministic (`context.now`, no `Date.now()`) | ✅ |
| Reads only system_events | ✅ |
| Writes via atom INSERT / RPC / workflow | ✅ (except `setBookingsLocked` — F8) |
| Idempotency via `rule_evaluations` | ❌ **F5 — never INSERTs** |
| Retry-safe | ⚠️ Marks-processed only on success; lacks per-consequence dedup |

---

## 5 — Known Issues (consolidado)

**HARD BUGS:**
- F1 `pay_fine` broken in production (columns dropped, function references them)

**DOCTRINAL VIOLATIONS (all closed):**
- F2 right.holder mutable metadata — **CLOSED Sprint 2.5 (mig 00279)** atom-only RPCs; metadata writes dropped; right_state_view (mig 00278) is source of truth
- F3 fund_lock mutable metadata — **CLOSED Sprint 1.2 (migs 00274 + 00275)** fund_lock_view atom-derived; RPCs emit atom only
- F4 slot.status non-recomputable — **CLOSED Sprint 3.7-3.9 (migs 00281, 00282, 00283)** slot_state_view atom-derived; status registered as documented operational cache
- F5 rule_evaluations dead-write — **CLOSED Sprint 4.10** post-run audit rows in process-system-events/index.ts with idempotency_key + ON CONFLICT DO NOTHING (engine code change saved to disk; redeploy via supabase functions deploy)
- ~~F7 archive_resource silent~~ — **MISDIAGNOSED, CLOSED 2026-05-17** (trigger handles emit)
- F8 setBookingsLocked direct mutation — **CLOSED Sprint 4.12 (mig 00284)** lock_asset_bookings RPC; sink rewired; asset_booking_lock_view atom-derived
- F10 update_right_metadata silent — **CLOSED Sprint 2.6 (mig 00280)** emits rightMetadataUpdated atom with `{updated_by, diff}` payload; no-op patches emit nothing
- F20 right has no atom-derived projection — **CLOSED Sprint 2.4 (mig 00278)** right_state_view derives holder/delegate/status from system_events ordered by seq DESC
- F22 slotCreated missing atom — **CLOSED Sprint 3.7 (mig 00281)** slotCreated + slotReleased atoms whitelisted + emitted

**HERESY (closed):**
- F1 pay_fine broken — **CLOSED Sprint 1.1 (mig 00273)** ledger-driven; void_fine also rebuilt

**Sprint 4.11 note (consequence sink dedup):** Per-sink dedup checks (`proposeFine` → fines_view, `createUserAction` → user_actions, `bumpWaitlistPriority` → system_events filter) **retained as defense-in-depth**. They protect against duplicates across rule runs that the rule_evaluations dedup (post-run write) would miss. Engine-level pre-dispatch dedup via `tryRecordEvaluation` sink remains as v1.1 follow-up (requires ruleEngine.ts core refactor; safer to do after rule_evaluations write has burn-in time in production).

---

## Operational: deploy step ✅ DEPLOYED

Sprint 4.10 + 4.12 patches **deployed 2026-05-18** — `process-system-events` edge function v20 → **v21** live in production (project `fpfvlrwcskhgsjuhrjpz`). ezbr_sha256: `c9733ece2b48fd0b17da7f383606ce6e09e2763c70c9e82cc04c7e1f166273bd`.

Patches now active:
- INSERT one `rule_evaluations` row per ExecutionResult with `idempotency_key` + ON CONFLICT DO NOTHING (Sprint 4.10).
- Call `lock_asset_bookings` RPC instead of UPDATE'ing `resources.metadata` directly when the `lockBookings` rule consequence fires (Sprint 4.12).

Note: 8 pre-existing TypeScript errors on the file (supabase-js generic typing drift across `markProcessed`, `buildContext`, member id coercions) were shipping in v20 already; the Sprint 4 patches do not introduce any new typing issues. Tracked separately as TS strictness debt.

---

## Freeze plan closed

All 12 sprint tasks + 1 bonus + 1 operational deploy: **DONE**.

Migration sequence (00273 → 00284) applied. Edge function deployed (v21). Doctrinal audit + 5 companion docs canonized. Memory persisted.

Truth > Projection > Cache > UI — restored across the 6 resource types, rule engine, and audit trail. Beta is unblocked from doctrinal posture.

**TRANSITIONAL DEBT (all closed Post-Beta):**
- ~~F6 resource_links narrow kind~~ — **MISDIAGNOSED, CLOSED 2026-05-18**: live state has 8 kinds in CHECK + 24-tuple `resource_link_kinds` catalog + `is_valid_resource_link()` semantic validator. `grants_access_to` correctly requires from=right. Audit agent missed the catalog table.
- F9 transfer_asset owner mutation — **CLOSED Post-Beta (mig 00288)** asset_ownership_view atom-derived; transfer_asset is atom-only; metadata.owner_id no longer written. Same pattern as Sprint 2 right_state_view.
- F11 record_ledger_entry stale whitelist — **CLOSED Post-Beta (mig 00285 P6)** whitelist synced to 11 canonical types
- F12 resource_links sin atom_guard — **CLOSED Post-Beta (mig 00287)** partial guard: DELETE rejected; UPDATE only of unlinked_at+unlinked_by paired null→set with set-once
- F14 rule_versions.status weak guard — **CLOSED Post-Beta (mig 00285 P3)** transitions enforced active→superseded/inactive
- F15 book_slot non-idempotent — **CLOSED Post-Beta (mig 00286 P5)** short-circuits to existing active booking for (slot, caller)
- F16 member_capability_overrides mutable — **CLOSED Post-Beta (mig 00286 P7)** emits memberCapabilityOverrideDeactivated atom on effective_until null→ts
- F18 fund.target unguarded mutability — **CLOSED Post-Beta (mig 00286 P8)** trigger blocks value→value mutation of metadata.target_amount_cents

**DOCUMENTATION ONLY:**
- F13 notifications_outbox guard option — **CLOSED Post-Beta (mig 00285 P9)** partial guard: only dispatched_at/status/error mutable, no DELETE
- F17 space.status dead field
- F21 vote_casts pending pre-seed not dup-guarded

**INVESTIGATE:**
- F19 data_deletion_log / data_subject_rights_requests creation source — **CLOSED Post-Beta (mig 00294)**. Tables verified to exist in `public` (live query 2026-05-18) with correct doctrine: data_deletion_log has atom_guard (append-only), both have RLS self-read policies, FK chain to auth.users intact, enums (data_right_kind / data_right_status) present. Root cause: tables were created out-of-band (likely hand-applied DDL or removed migration). Retroactive mig 00294 captures the live schema with `IF NOT EXISTS` so fresh dev/staging environments materialize them correctly. No-op in production.

---

## 6 — Remediation Roadmap

### A) Must fix before Beta (prioridad 1)

| # | Acción | Effort | Blast radius |
|---|---|---|---|
| R1 | Fix `pay_fine` — rewrite to use `ledger_entries(type='fine_paid')` + lookup fund via `resources WHERE group_id=...` AND resource_type='fund' AND archived_at IS NULL. Drop refs to dropped columns. | M | Money flow — verify all fine.paid display paths read from `fines_view` (atom-derived) not legacy `fines.paid`. |
| R2 | Right state projection — create `right_state_view` rebuilt from `system_events`. Each right-mutating RPC (`transfer_right`, `delegate_right`, etc.) drops `metadata.holder_*` write; keeps only atom emit. `right_holders_view` reads from `right_state_view`. `update_right_metadata` split into per-knob RPCs each with `rightMetadataUpdated` atom. | L | Right resource cross-cuts events/asset/fund — verify all readers of right state. |
| R3 | Fund lock projection — create `fund_lock_view` rebuilt from `system_events WHERE event_type IN ('fundLocked','fundUnlocked')` (latest per fund_id). `fund_lock`/`fund_unlock` drop metadata write. `fund_balance_view` reads `locked_at` from `fund_lock_view` instead of metadata. | S | Localized to fund. |
| R4 | Slot atom completion — add `slotCreated`, `slotReleased` atoms to whitelist. `create_slot` emits `slotCreated`; `cancel_booking`/`expire_booking` for slot emits `slotReleased`. Create `slot_state_view` recomputing status from atom stream. Drop `resources.status` mutation for slots (or mark as cache derived from view). | M | Slot lifecycle — verify SlotRepository reads. |
| R5 | rule_evaluations wire-up — `process-system-events` INSERT row per (rule_version_id, event_id, target_id, consequence_index) with computed idempotency_key BEFORE executing consequence. Rely on UNIQUE violation to short-circuit retries. Each `ConsequenceSink` method becomes a single INSERT-then-execute pattern. | M | Reliability — eliminates a class of duplicate fines/warnings on retry. |
| R6 | Archive atoms — `archive_resource` emits `resourceArchived`. `unarchive_resource` emits `resourceUnarchived`. | S | Localized. |
| R7 | setBookingsLocked refactor — introduce `lock_asset_bookings(asset_id, rule_id, reason)` SECURITY DEFINER RPC. Emits `assetBookingsLocked` atom. Edge function consequence sink calls RPC instead of direct UPDATE. Add `asset_booking_lock_view` projection. | M | Rule engine consequence path. |
| R8 | Permission test for `update_right_metadata` — must require holder-or-admin (currently any caller with whitelisted knobs). And emit atoms. | S | Right governance. |

**Estimate:** ~3-4 sprints if 1 engineer; 1-2 sprints if 2 engineers in parallel (R2, R3, R4 are independent; R1, R5, R6, R7, R8 mostly independent).

### B) Post-Beta safe (prioridad 2)

| # | Acción |
|---|---|
| P1 | resource_links polymorphic expansion — add `owns`, `funds`, `scheduled_in`, `grants_access_to` kinds. Generic `link_resources(from, to, kind)` RPC. Kind-specific validators (`grants_access_to ⇒ from.resource_type='right'`). |
| P2 | resource_links atom guard (partial: unlinked_at one-way). |
| P3 | rule_versions.status guard tighten — only allow `active → superseded` or `active → inactive` transitions. |
| P4 | transfer_asset → derive owner from `assetTransferred` projection; drop metadata mutation. |
| P5 | book_slot idempotency (dedup by (slot_id, booker_id, active)). |
| P6 | record_ledger_entry whitelist sync to 11 canonical. |
| P7 | member_capability_overrides — emit `memberCapabilityOverrideDeactivated` atom on `effective_until` flip. |
| P8 | fund.target_amount_cents — add CHECK to enforce immutability post-create, or introduce `update_fund_target` RPC that emits atom. |
| P9 | notifications_outbox partial guard (dispatched_at one-way, status whitelist). |

### C) Documentation only (prioridad 3)

| # | Acción |
|---|---|
| D1 | OperationalCacheDoctrine.md — registry de cada cache field aceptado con sus 5 condiciones cumplidas. |
| D2 | ProjectionDoctrine.md — registry de cada projection con source atoms, reduction logic, invalidation. |
| D3 | RightRules.md — companion para right resource (claim semantics, not permission). |
| D4 | ResourceLinkDoctrine.md — link kind catalog closed, atom-as-truth, unlink semantics. |
| D5 | RuleEngineDoctrine.md — engine contract, idempotency, rule_evaluations protocol. |
| D6 | TalmudicGovernance.md (existe) — agregar §con axiomas 1-16 de §2. |
| D7 | Update Constitution §14 step 6 — agregar item: "address Consistency Audit findings F1-F22". |
| D8 | Space.md §17 — clarify `resources.status='active'` is set-once historical noise. |

### D) Never build

| # | Heresy |
|---|---|
| N1 | Mutable balance column en cualquier resource (groups.fund_balance, funds.metadata.balance). |
| N2 | Right `holder_id` direct mutation post-create sin atom. |
| N3 | Auto-waitlist promotion sin consentimiento explícito. |
| N4 | Rule engine que muta state tables directamente. |
| N5 | AI que emite atoms o muta state. |
| N6 | Vertical-specific tables (events_attendance, fund_balances). |
| N7 | `resources.metadata.balance` o cualquier estado calculable como cache mutable. |

---

## 7 — Tests to Add (atom guards + doctrinal contracts)

### Atom guard tests

- `test_ledger_entries_reject_update` — UPDATE ledger_entries SET amount_cents=0 should raise check_violation.
- `test_ledger_entries_reject_delete` — DELETE FROM ledger_entries should raise.
- `test_system_events_only_processed_at_mutable` — UPDATE system_events SET event_type='x' raises; UPDATE system_events SET processed_at=now() WHERE processed_at IS NULL succeeds; UPDATE system_events SET processed_at=now()+'1h' WHERE processed_at IS NOT NULL raises.
- `test_user_actions_only_resolved_at_mutable` — analogous.
- `test_vote_casts_reject_update` — re-cast should INSERT new row.
- `test_bookings_reject_update_after_insert` — bookings_atom_guard verification.
- `test_resource_links_should_get_guard` — PENDING fix; once added, test partial guard.

### Projection recompute tests

- `test_fund_balance_view_derives_from_ledger_entries_only` — INSERT fake ledger entries; verify view sum matches. Verify view does NOT query `resources.metadata.balance`.
- `test_attendance_view_recomputes_from_rsvp_and_checkin_actions` — same.
- `test_right_state_view_recomputes_from_system_events` — POST-FIX R2 — full transfer chain reconstructible from atoms.
- `test_slot_state_view_recomputes_from_atoms` — POST-FIX R4.
- `test_fund_lock_view_derives_from_atoms_only` — POST-FIX R3.

### Cache divergence tests

- `test_resources_metadata_holder_diverges_from_atoms` — corrupt `metadata.holder_member_id`, verify `right_state_view` (post-R2) returns atom-derived holder, not metadata.
- `test_fund_balance_view_ignores_resources_metadata_balance` — pre-existing should pass.

### RPC emits atom tests

- `test_transfer_right_emits_atom` — verify `rightTransferred` row appears.
- `test_transfer_right_does_not_mutate_holder_directly` — POST-FIX R2.
- `test_update_right_metadata_emits_atom` — POST-FIX R8.
- `test_archive_resource_emits_resource_archived_atom` — POST-FIX R6.
- `test_fund_lock_emits_fund_locked_atom` — exists, but POST-FIX R3 also verify no metadata mutation.

### Rule does not mutate state tests

- `test_rule_engine_consequences_only_emit_atoms_or_call_rpcs` — scan `ConsequenceSink` methods for direct `.update(...)` calls; should fail until R7.
- `test_rule_evaluation_idempotency_key_inserted` — POST-FIX R5 — second run of same event does not duplicate fines.
- `test_emit_warning_does_not_duplicate_on_retry` — POST-FIX R5.

### Link consistency tests

- `test_link_resources_emits_atom_and_creates_row` — exists.
- `test_unlink_does_not_hard_delete` — exists.
- `test_link_kind_grants_access_to_requires_right_source` — POST-FIX P1.
- `test_link_resources_polymorphic_source` — POST-FIX P1.

### Booking vs waitlist consent

- `test_book_space_at_capacity_raises_not_auto_waitlists` — exists conceptually, formalize.
- `test_book_space_must_call_join_waitlist_explicitly` — same.
- `test_book_slot_idempotent_for_same_caller` — POST-FIX P5.

### Right doctrine

- `test_right_transfer_does_not_mutate_holder_directly` — POST-FIX R2.
- `test_right_exercise_does_not_change_holder` — exists in spec.
- `test_right_expiration_emits_atom_and_derives_status` — POST-FIX R2 followup.
- `test_right_metadata_update_emits_diff_atom` — POST-FIX R8.

### Fund doctrine

- `test_pay_fine_uses_ledger_entries_not_groups_fund_balance` — POST-FIX R1.
- `test_fund_lock_state_derives_from_atoms` — POST-FIX R3.

---

## 8 — Docs to Update / Create

| Doc | Action | Owner |
|---|---|---|
| `Plans/Active/Constitution.md` | Add §14 step 7: "address Consistency Audit findings F1-F22 per remediation roadmap" | founder |
| `Plans/Active/AtomProjection.md` | Update guard coverage matrix: add `bookings`, `identity_atoms`, `rule_evaluations`. Add `right_state_view`, `slot_state_view`, `fund_lock_view` as planned projections | founder |
| `Plans/Active/HierarchyReference.md` | §10 (mutability table) — flag `resources.metadata.holder_*`, `resources.metadata.locked_*`, `resources.status` for slot as deuda doctrinal | founder |
| `Plans/Active/Fund.md` | Update §lock to declare fund_lock as projection-derived post-R3 | founder |
| `Plans/Active/Right.md` | Update §holder + §expiration to declare projection-derived post-R2 | founder |
| `Plans/Active/Slot.md` | Add §atoms with slotCreated/slotReleased post-R4 | founder |
| `Plans/Active/Asset.md` | §17 — flag transfer_asset metadata mutation as TRANSITIONAL DEBT (P4) | founder |
| `Plans/Active/EventResource.md` | §10 — clarify link kinds expanded post-P1 | founder |
| `Plans/Active/OperationalCacheDoctrine.md` | **CREATE** — registry de cada cache field aceptado | this audit |
| `Plans/Active/ProjectionDoctrine.md` | **CREATE** — registry de cada projection | this audit |
| `Plans/Active/RightRules.md` | **CREATE** — claim vs permission, transferability, exercise, exhaustion | this audit |
| `Plans/Active/ResourceLinkDoctrine.md` | **CREATE** — link kind catalog, atom-as-truth, polymorphic source | this audit |
| `Plans/Active/RuleEngineDoctrine.md` | **CREATE** — engine contract, idempotency, rule_evaluations protocol | this audit |
| `Plans/Active/Governance.md` | §15.2 — flag rule_evaluations dead-write as known issue + remediation in R5 | founder |

---

## 9 — Final Doctrine (la frase que ata todo)

> **Ruul es doctrinalmente sano cuando: todo acto importante deja atom; todo estado importante se deriva de atoms; toda cache mutable está justificada y recomputable; toda rule emite atoms o arranca workflows; todo right es claim posesivo no permiso; todo link es relación estructural no automation; toda projection es regenerable desde atoms; toda UI es surface no truth.**

Cada hallazgo de este audit se mide contra esa frase. Los 11 DOCTRINAL VIOLATIONS la violan en al menos uno de sus 8 verbos. Las 9 fixes Must-Before-Beta restauran la frase.

> *Constitution.md fija el QUÉ (12 artículos). TalmudicGovernance.md fija el CÓMO PENSAR (lente). Este audit fija el ESTADO ACTUAL (qué está sano, qué está roto). Las 5 doctrinas companion fijan el CONTRATO DETALLADO (cache, projection, right, link, rule engine).*

> *El sistema funciona como sistema jurídico/talmúdico computacional cuando: hechos → atoms; interpretación → projections; reglas → engine determinístico; excepciones → overrides scoped; precedentes → rule_versions; resolución → workflows + atom de cierre; memoria → todo lo anterior queryable.*

---

## 10 — Anexo: criterio final por componente

```
Constitution + Vision + HierarchyReference   → ✅ DOCTRINALLY SOUND
AtomProjection (5+2 guards)                  → ✅ ENFORCED
Group / Membership / Identity                → ✅ CLEAN
Event resource                               → ✅ CLEAN
Asset resource                               → ⚠️ 2 violations (archive, transfer owner)
Fund resource                                → ⚠️ 1 violation (lock) + 1 hard bug (pay_fine)
Space resource                               → ✅ EXEMPLARY (modelo a seguir)
Slot resource                                → ❌ 3 violations (status, atoms, idempotency)
Right resource                               → ❌ 3 violations (holder, projection, silent updates)
Rule engine                                  → ⚠️ 2 violations (rule_evaluations dead, setBookingsLocked direct)
Resource links                               → ⚠️ 2 violations (narrow kind, no guard)
Ledger discipline                            → ✅ CLEAN (CHECK constraint enforced)
RPC mutation discipline                      → ⚠️ ~10 RPCs need atom-emit refactor
```

**Final verdict:** Ruul está listo para Beta una vez R1-R8 cierren. Los Post-Beta items (P1-P9) son seguros de dejar para v1.1. Las heresies (N1-N7) deben quedar prohibidas explícitamente en code review.

---

**End of audit.**
