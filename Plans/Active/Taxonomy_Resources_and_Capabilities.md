# Taxonomy: Resources × Capability Blocks

**Status:** Canonical spec — fuente de verdad para Phases 1-5 de OpenPlatform.
**Fuente:** Founder directive 2026-05-10.
**Companion docs:** `OpenPlatform_Phase0_2026-05-10.md` (phasing/migration), `L1_Audit_2026-05-10.md` (deuda actual).

> **La frase clave:**
> Ruul no se construye con verticales. Ruul se construye con **Resources + Capability Blocks**.

---

## 0. Modelo mental

Ruul tiene 3 piezas principales:

```
Group → Resources → Capability Blocks
```

| Pieza | Definición | Ejemplo |
|---|---|---|
| **Group** | Comunidad persistente | "Los Cuates" |
| **Resource** | Algo que existe dentro del grupo y puede tener vida propia | Cena jueves, Viaje Valle, Casa Valle, Palco Azul, Gasto restaurante, Fondo cumpleaños, Rotación de host |
| **Capability Block** | Capacidad opcional que se le agrega a un resource | RSVP, Guests, Money, Rules, Rotation, Capacity, Booking, Approval |

**La fórmula:** `Resource Type + Capability Blocks = Caso de uso`

**Ejemplos:**
- `event + RSVP + Guests + Expenses + Rules` = Cena organizada
- `asset + Slots + Booking + Guests + Money + Rules` = Palco compartido
- `fund + Contributions + Payouts + Rules` = Tanda

---

## 1. Resources base (22 tipos)

Los sustantivos del sistema.

### 1.1 group_space
**Resource general del grupo.**
Sirve para: reglas globales, anuncios, balances generales, propuestas generales, fondos generales.
**Capabilities:** rules, voting, money, announcements, documents, history, permissions.

### 1.2 event
**Una actividad puntual.**
Ejemplos: cena, brunch, salida, workout, clase, partido, poker night, reunión.
**Capabilities:** schedule, location, capacity, rsvp, attendance, guests, assignments, expenses, voting, rules, reminders, check-in, history.

### 1.3 resource_series
**Una cosa recurrente.**
Ejemplos: cena semanal, contribución mensual, reunión mensual, booking recurrente, workout semanal.
**Capabilities:** recurrence, occurrence_generation, rotation, rsvp_defaults, rules, notifications, location_strategy, guests, money, cancellation_policy, history.

### 1.4 occurrence
**Instancia generada por una serie.**
Ejemplos: Cena #14, Pago de marzo, Workout del martes, Slot semana 3.
**Capabilities:** schedule, overrides, rsvp, attendance, assignment, expense, guests, rules, cancellation, check-in, history.

### 1.5 expense
**Un gasto pagado por alguien.**
Ejemplos: cuenta del restaurante, Airbnb, gasolina, regalo, boletos, mantenimiento.
**Capabilities:** money, split, ledger, settlement, approval, attachments, rules, history.

### 1.6 settlement
**Pago entre miembros para saldar deuda.**
Ejemplos: Daniel pagó $600 a José, Sara liquidó su parte del Airbnb.
**Capabilities:** ledger, confirmation, attachments, history, dispute.

### 1.7 fund
**Dinero compartido del grupo.**
Ejemplos: fondo cumpleaños, fondo viaje, fondo mantenimiento, pot de poker, tanda pool.
**Capabilities:** ownership, contributions, payouts, ledger, balance_projection, rules, withdrawal_approval, voting, notifications, history.

### 1.8 contribution
**Aporte a un fondo, tanda u objetivo.**
Ejemplos: aportación mensual, buy-in poker, cuota viaje, depósito.
**Capabilities:** schedule, recurrence, payment_tracking, deadline, rules, ledger, reminders, history.

### 1.9 payout
**Salida de dinero o beneficio.**
Ejemplos: payout de tanda, retiro de fondo, reembolso, premio poker.
**Capabilities:** approval, voting, ledger, confirmation, rules, history.

### 1.10 asset
**Recurso compartido persistente.**
Ejemplos: palco, casa, cancha, membresía, coche, bote, mesa, oficina.
**Capabilities:** ownership, capacity, slots, booking, access, guests, maintenance_fund, expenses, voting, rules, documents, history.

### 1.11 slot
**Ventana o unidad de uso de un asset.**
Ejemplos: partido América vs Pumas, fin de semana en Valle, martes 8 PM, turno palco, asiento específico.
**Capabilities:** schedule, capacity, assignment, booking, confirmation, guests, swap, expiration, rules, reminders, history.

### 1.12 booking
**La acción de reservar/reclamar un slot/resource.**
Ejemplos: Daniel reservó el palco, Linda reservó la casa, Sara reservó cancha.
**Capabilities:** schedule, approval, guests, payment, cancellation, confirmation, rules, reminders, history.

### 1.13 rotation
**Orden rotativo para asignar algo.**
Ejemplos: host rotation, payout rotation, slot rotation, quién escoge restaurante, quién maneja, quién lleva vino.
**Capabilities:** participants, ordering, assignment_generation, swaps, skip_policy, replacement_policy, rules, history.

### 1.14 assignment
**Una responsabilidad asignada a alguien.**
Ejemplos: José reserva, David lleva vino, Sara compra regalo, Linda maneja, Daniel cobra.
**Capabilities:** assignee, deadline, acceptance, completion, reassignment, reminders, rules, history.

### 1.15 proposal
**Propuesta para decidir algo.**
Ejemplos: cambiar regla, aprobar invitado, cambiar fecha, aprobar gasto, remover miembro, elegir restaurante.
**Capabilities:** voting, discussion, approval, quorum, threshold, deadline, consequence_on_pass_fail, history.

### 1.16 vote
**Proceso formal de decisión.**
Ejemplos: sí/no, multiple choice, ranked choice, aprobar/rechazar.
**Capabilities:** electorate, anonymity, quorum, threshold, deadline, vote_casts, decision_projection, history.

### 1.17 appeal
**Disputa o defensa.**
Ejemplos: apelar multa, disputar booking, disputar pago, pedir excepción.
**Capabilities:** voting, evidence, discussion, decision, deadline, history.

### 1.18 guest_pass
**Permiso temporal para un invitado.**
Ejemplos: +1 a cena, invitado al palco, invitado recurrente, acceso temporal.
**Capabilities:** approval, expiration, capacity, payment, rules, history.

### 1.19 document
**Información compartida.**
Ejemplos: itinerario, reglas, menú, contrato, lista de compras, instrucciones.
**Capabilities:** permissions, comments, attachments, history, approval.

### 1.20 checklist
**Lista de tareas o compras.**
Ejemplos: súper del viaje, pendientes de boda, cosas para cena, tareas de casa.
**Capabilities:** assignments, completion, due_dates, comments, history.

### 1.21 commitment
**Compromiso personal/grupal.**
Ejemplos: reto fitness, estudiar, ahorrar, check-in semanal, accountability pact.
**Capabilities:** check_ins, recurrence, streaks, rules, consequences, reputation, history.

### 1.22 custom_resource
**Recurso creado libremente por el usuario.**
Capabilities: seleccionables según configuración (rules, history, assignments, voting, money, documents).

---

## 2. Capability Blocks (50 bloques en 10 categorías)

### A. Identity / Access (4)

| ID | Display | Compatible con | Campos |
|---|---|---|---|
| **ownership** | Ownership | asset, fund, group_space, document, custom_resource | owners, ownership_share?, owner_permissions, transfer_policy |
| **membership_access** | Membership Access | (casi todos) | visible_to, usable_by, editable_by, restricted_roles |
| **permission_policy** | Permission Policy | group, resource, module, rules, fund, asset | who_can_view, who_can_edit, who_can_delete, who_can_invite, who_can_approve, who_can_override |
| **approval** | Approval | booking, guest_pass, expense, payout, proposal, asset, slot | approval_required, approver_type, threshold, deadline, auto_approve_policy |

### B. Time / Schedule (5)

| ID | Display | Compatible con | Campos |
|---|---|---|---|
| **schedule** | Schedule | event, slot, booking, assignment, contribution, occurrence | starts_at, ends_at, timezone, duration, all_day |
| **recurrence** | Recurrence | resource_series, event, contribution, assignment, slot, booking | frequency, interval, days_of_week, start_date, end_condition, exceptions |
| **occurrence_generation** | Occurrence Generation | resource_series | generation_mode, rolling_window, number_of_occurrences, auto_generate, manual_approval |
| **deadline** | Deadline | rsvp, assignment, contribution, vote, booking_confirmation, settlement | deadline_at, relative_deadline, grace_period, deadline_action |
| **expiration** | Expiration | slot, booking, guest_pass, proposal, vote | expires_at, auto_release, expiration_consequence |

### C. Participation (6)

| ID | Display | Compatible con | Campos |
|---|---|---|---|
| **participants** | Participants | event, expense, trip, fund, rotation, vote, assignment | participants, participant_source, include_all_members, exclude_members |
| **rsvp** | RSVP | event, occurrence, booking, slot, trip_event | required, deadline, allow_maybe, allow_change, visibility |
| **attendance** | Attendance | event, occurrence, slot, booking, commitment | check_in_required, manual_attendance, auto_attendance, late_threshold |
| **capacity** | Capacity | event, trip, asset, slot, booking, guest_pass | max_capacity, waitlist_enabled, overbooking_policy |
| **guest_access** | Guest Access | event, booking, slot, asset, trip | guests_allowed, guest_limit, approval_required, guest_pays, guest_expiration |
| **waitlist** | Waitlist | event, slot, booking, trip, asset | enabled, order_policy, auto_promote |

### D. Coordination (5)

| ID | Display | Compatible con | Campos |
|---|---|---|---|
| **assignment** | Assignment | event, occurrence, rotation, trip, checklist, asset, booking | assignee, task, deadline, requires_acceptance, completion_required |
| **rotation** | Rotation | resource_series, event_series, asset, slot, fund, payout, assignment | rotation_purpose, participants, order_strategy, frequency, swap_policy, replacement_policy |
| **swap** | Swap | slot, booking, rotation, assignment, payout_position | swap_allowed, approval_required, direct_swap, marketplace_mode |
| **replacement** | Replacement | rotation, assignment, booking, slot | replacement_policy, next_in_line, volunteer, admin_reassign, vote_required |
| **task_completion** | Task Completion | assignment, checklist, commitment | completion_type, proof_required, verified_by |

### E. Money (8)

| ID | Display | Compatible con | Campos |
|---|---|---|---|
| **expense** | Expense | group_space, event, trip, booking, asset, fund | amount, currency, paid_by, participants, split_method |
| **split** | Split | expense, booking, event, trip, fund | equal, custom_amount, percentage, shares, exclude_members |
| **ledger** | Ledger (atoms) | expense, fund, contribution, payout, settlement, fine | ledger_entries, debit, credit, source_resource_id |
| **balance_projection** | Balance Projection | group, event, trip, fund | from_member, to_member, amount, currency, source_entries |
| **settlement** | Settlement | balance, expense, fine, contribution | payer, receiver, amount, confirmation_required, payment_method |
| **fund** | Fund | group_space, trip, asset, event_series, poker_pot, tanda | fund_name, goal_amount, admin, contribution_policy, withdrawal_policy |
| **contribution** | Contribution | fund, tanda, trip, membership_dues | amount, due_date, recurring, required, optional |
| **payout** | Payout | fund, tanda, poker_pot, reimbursement | recipient, amount, approval_required, confirmation_required |

### F. Governance (8)

| ID | Display | Compatible con | Campos |
|---|---|---|---|
| **rules** | Rules | group, module, resource_series, resource, occurrence, membership | scope_type, scope_id, trigger, conditions, consequences, enabled, version |
| **voting** | Voting | proposal, rule, expense, guest_pass, booking, payout, slot, membership | eligible_voters, quorum, threshold, deadline, anonymous |
| **proposal** | Proposal | group, resource, rule, membership, fund, asset | proposal_type, target_resource, options, desired_change |
| **appeal** | Appeal | fine, sanction, booking_rejection, assignment_miss, payment_dispute | reason, evidence, decision_method, deadline |
| **dispute** | Dispute | expense, settlement, booking, slot, assignment, guest_pass | claim, counterparty, evidence, resolution_method |
| **consequence** | Consequence | rules | warning, fine, notification, open_vote, lose_turn, release_slot, restrict_access, reward, badge |
| **sanction** | Sanction | member, booking, slot, assignment | type, duration, scope, appealable |
| **reward** | Reward | member, assignment, commitment, reputation | reward_type, points, badge, privilege |

### G. Communication (4)

| ID | Display | Compatible con | Campos |
|---|---|---|---|
| **notification** | Notification | (casi todos) | notification_type, channel, timing, recipients |
| **reminder** | Reminder | rsvp, assignment, contribution, booking, vote, event | when, repeat, recipient, message |
| **announcement** | Announcement | group, event, trip, asset | message, pinned, recipients, expires_at |
| **comments** | Comments | proposal, event, booking, expense, appeal, document | thread_id, visibility, attachments |

### H. Lifecycle (4)

| ID | Display | Compatible con | Campos |
|---|---|---|---|
| **status** | Status | (todos) | draft, active, pending, confirmed, completed, cancelled, expired, archived, disputed |
| **cancellation** | Cancellation | event, booking, slot, trip, occurrence | who_can_cancel, deadline, consequence, reschedule_option |
| **check_in** | Check-in | event, booking, assignment, commitment | method, time_window, required, proof |
| **archival** | Archival | (todos) | archive_policy, retention, restore_allowed |

### I. Observability (3)

| ID | Display | Compatible con | Campos |
|---|---|---|---|
| **history** | History | (todos) | system_events, activity_feed, audit_log (NOT source of truth) |
| **analytics** | Analytics | group, resource, module | usage, attendance, payment_reliability, engagement |
| **reputation** | Reputation | member, group, resource_participation | attendance_rate, payment_reliability, assignment_completion, appeals, positive_actions |

### J. Content (3)

| ID | Display | Compatible con | Campos |
|---|---|---|---|
| **attachments** | Attachments | expense, document, appeal, booking, event, trip | file_url, type, uploaded_by, visibility |
| **notes** | Notes | (todos) | text, visibility, editable_by |
| **checklist_items** | Checklist Items | trip, event, assignment, document | items, assigned_to, completed, due_date |

---

## 3. Compatibility Matrix (Resource × Capabilities resumen)

```
event              schedule, location, participants, capacity, rsvp, attendance,
                   guests, assignments, expenses, rules, voting, notifications, history

resource_series    recurrence, occurrence_generation, participants, rotation, rules,
                   notifications, location_strategy, cancellation_policy, history

occurrence         schedule, overrides, rsvp, attendance, assignment, expenses,
                   guests, rules, cancellation, history

expense            money, split, ledger, settlement, approval, attachments,
                   rules, dispute, history

fund               ownership, contribution, payout, ledger, balance_projection,
                   rules, voting, notifications, history

asset              ownership, capacity, access, slotting, booking, guests,
                   maintenance_fund, expenses, rules, voting, documents, history

slot               schedule, capacity, assignment, booking, confirmation,
                   guests, swap, expiration, rules, reminders, history

booking            schedule, approval, capacity, guests, payment, cancellation,
                   confirmation, rules, reminders, history

rotation           participants, ordering, assignment_generation, swap, skip_policy,
                   replacement, rules, history

assignment         assignee, deadline, acceptance, completion, reassignment,
                   reminders, rules, history

proposal           voting, discussion, approval, quorum, threshold, deadline, history

guest_pass         approval, expiration, capacity, payment, rules, history

commitment         recurrence, check_in, streaks, rules, consequences, reputation, history
```

---

## 4. Capability dependencies

```
balance_projection    depends on  ledger
settlement            depends on  ledger
fine                  depends on  rules
appeal                depends on  consequence
guest_access          often depends on  capacity
booking               depends on  schedule  or  slot
rotation              depends on  participants
assignment_generation depends on  rotation
payout                depends on  fund  or  ledger
contribution          depends on  fund
occurrence_generation depends on  recurrence
attendance            depends on  rsvp  or  check_in
decision_result       depends on  vote_casts
```

---

## 5. Capability conflicts

```
fixed_host                conflicts with  rotating_host
manual_assignment         conflicts with  random_assignment   (if both canonical)
free_booking              conflicts with  assigned_only_booking
public_vote               conflicts with  anonymous_vote
auto_approve              conflicts with  approval_required
no_guests                 conflicts with  guest_access
no_money                  conflicts with  expense / fund / payment blocks
single_occurrence         conflicts with  recurrence
```

---

## 6. Presets (sugerencias, no arquitectura)

> Presets no son arquitectura. Son combinaciones sugeridas que la UI ofrece como atajo.

### Dinner preset
- Resource: `event` o `resource_series`
- Capabilities: schedule, location, rsvp, guests?, expenses?, rules?, rotation?, history

### Shared expense preset
- Resource: `expense`
- Capabilities: split, ledger, balance_projection, settlement, history

### Trip preset
- Resource: trip / `custom_resource`
- Capabilities: schedule, participants, expenses, fund?, bookings?, assignments?, voting?, documents, history

### Shared asset preset (palco / casa)
- Resource: `asset`
- Capabilities: ownership, capacity, slots?, booking?, guests?, money?, rules?, history

### Tanda preset
- Resources: `fund` + `resource_series` + `rotation` + `contribution` + `payout`
- Capabilities: recurrence, ledger, payout_rotation, payment_deadlines, rules, history

### Roomies preset
- Resources: `group_space` + `expense` + `assignment` + `fund?`
- Capabilities: recurring_expenses, chores_rotation, rules, settlement, history

---

## 7. Product rule

**El usuario nunca debe ver toda esta taxonomía.**

Debe ver:

```
¿Qué quieres crear?
  → Evento / Gasto / Fondo / Asset / Viaje / Custom

Crear básico
  → Agregar opciones (mostradas progresivamente)
```

**Ejemplo:**

```
Crear evento
  Required:
    - nombre
    - fecha
    - lugar

  [+ Agregar opciones]
    - RSVP
    - repetir
    - rotar host
    - gastos
    - invitados
    - reglas
```

---

## 8. Arquitectura final resumida

```
Group
├── Members
├── Modules
├── Resources
│   ├── resource_type
│   ├── capability_blocks
│   ├── capability_configs
│   ├── rules
│   ├── atoms
│   └── projections
├── Money
├── Governance
├── History
└── Settings
```

---

## 9. Notas de implementación

### Naming convention
- `resource_type` (snake_case) en SQL.
- `ResourceType` (CamelCase) enum en Swift.
- `capability_block_id` (snake_case string) tanto en SQL como en JSON Swift.
- Preset id (snake_case): `dinner_preset`, `tanda_preset`, etc.

### Storage
- `public.resources` ya existe (mig 00014). Hold.
- `public.modules` ya existe (mig 00060). Phase 1 añade `provided_capability_blocks text[]`.
- `public.capability_blocks` — opcional Phase 1 (puede vivir en código primero).
- `public.resource_capabilities` — Phase 2 (resource_id → capability_block_id → config jsonb).
- `public.resource_series` — Phase 2.
- `public.ledger_entries` — Phase 3.

### Atom/Projection invariants
- `system_events` = atoms autoritativos (existe ✓)
- `vote_ballots` = atoms (existe ✓)
- `ledger_entries` = atoms (Phase 3)
- `rsvp_actions` = atoms (Phase 2)
- `votes.status`, `fines.status`, `event_attendance` = projections (recomputable from atoms)
- `groups.fund_balance` = projection vía view (replace stored col en Phase 3)
- `History` capability nunca es source of truth — renderiza atoms.

### Resource lifecycle
- Cada resource_type tiene state machine implícito en `resources.status`.
- States canónicos del block `status`: draft, active, pending, confirmed, completed, cancelled, expired, archived, disputed.
- No todos los resource types usan todos los states. Cada type declara su sub-set válido.

### CapabilityResolver
- Per Phase 1: protocol expandido con `canCreateResource`, `canEnableCapability`, `canViewSection`, `canPerformAction`, `canManageRule`, `canInviteGuest`, `canAssignSlot`, `canRecordExpense`, `canSettleBalance`, `canVote`.
- Resolución algorithm:
  1. Capability block exists in catalog
  2. Owning module is in `groups.active_modules`
  3. Resource has capability enabled in `resource_capabilities`
  4. Member has all required permissions (via `has_permission`)
  5. Capability state allows action (e.g. not in `expired` lifecycle)
