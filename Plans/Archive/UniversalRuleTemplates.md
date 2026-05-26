# Ruul — Universal Rule Templates (doctrina canónica)

**Status:** Draft 1 — 2026-05-17. Founder spec.
**Companions:** `Vision.md` (estrategia), `Governance.md` §0.5 (doctrina híbrida Shapes/Templates), `HierarchyReference.md` (capa 8), `ConsistencyAudit_2026-05-17.md` (freeze activo).
**Scope:** Reframe completo de los rule templates de Ruul. Cómo se piensan, cómo se nombran, qué se acepta, qué se rechaza, qué ya hay que renombrar.
**Tono:** Opinionado. Marca explícita de Beta 1 / Post-Beta / NUNCA y de "renombrar" vs "construir".

> **Epígrafe que ata todo:**
> **Templates son categorías sociales universales, no features verticales.**
> Si el nombre del template incluye una vertical (dinner, soccer, palco, parking, wedding, menu, host, palco), está mal abstraído. Sube un nivel.

> **Compatibilidad con freeze 2026-05-17:** esta doctrina **no** introduce shapes nuevos, templates nuevos, ni resource_types/capabilities nuevos. Define vocabulario, taxonomía, contrato y plan de renombrado. La fase de renombrado físico (mig DB + iOS copy + tests) se ejecuta **después** del cierre de los 4 sprints del audit. Hasta entonces: doctrina escrita, no implementación.

---

## 0. Lectura ejecutiva en 60 segundos

1. **Cinco objetos distintos**, no mezclar nunca: **Shape piece** (Lego atómico ejecutable) → **Template** (receta humana universal) → **Rule instance** (publicada en un grupo con scope+params) → **Rule version** (snapshot frozen, truth) → **Rule evaluation** (audit append-only). **Atoms** son la realidad; **Projections** son interpretación; **UI** es traducción.
2. **Templates son patrones sociales universales** (allocation, obligation, governance, access, custody, transfer, money, exception). NO son casos verticales. Si aplican sólo a una vertical, no son templates — son malentendidos.
3. **Test de admisión de un template:** ¿este patrón sigue teniendo sentido en al menos 5 verticales (cenas, fútbol, palcos, roommates, coworking)? Si no — rechazar y reabstraer.
4. **Beta 1 = 5 templates universales máximo.** Recomendado: `deadline_enforcement`, `missed_obligation_consequence`, `priority_allocation`, `approval_required`, `rotating_responsibility`. Los 12 templates actuales del catálogo se **renombran y reagrupan** dentro de estos 5 (no se borran; se promueven a la categoría correcta).
5. **El usuario nunca ve los nombres técnicos.** Ve "Exigir algo antes de una fecha" / "Repartir cupos limitados" / "Pedir aprobación". Los nombres técnicos son del engine y del audit. Cada grupo puede ponerle su propio nombre instanciado ("Boletos del palco", "Titulares del partido", "Turno de manejo") sin que el template subyacente cambie.
6. **AI propone, humano publica, engine ejecuta.** El usuario nunca escribe lógica. Sólo elige template, llena 2–4 parámetros, ve el preview en lenguaje humano, publica.

---

## 1. Doctrina: Templates vs Shapes vs Rule Versions vs Evaluations vs Atoms

> Las memorias previas (`project-governance-canonical`, `project-ontology-constitution`, `project-rules-hierarchy`) ya establecen partes de esto. Aquí se consolidan **5 objetos canónicos** sin ambigüedad.

### 1.1 Cinco objetos distintos

```
┌────────────────────────────────────────────────────────────────────┐
│ 1. SHAPE PIECE  (public.rule_shapes)                               │
│    Lego atómico. 1 trigger | 1 condition | 1 consequence cada uno. │
│    Runtime-declarative; ejecutable en server-side TS evaluator.    │
│    Ejemplo: trigger `rsvpDeadlinePassed`, consequence `fine`.      │
│    Mutabilidad: nuevo = INSERT + evaluator nuevo (no client rls).  │
└────────────────────────────────────────────────────────────────────┘
                              ▲ composed by
┌────────────────────────────────────────────────────────────────────┐
│ 2. TEMPLATE  (public.rule_templates, TS canonical)                 │
│    Receta humana universal: 1 trigger + N conditions + N           │
│    consequences + scope hint + params schema + natural-language    │
│    preview. NO ejecuta nada por sí solo.                           │
│    Ejemplo: `priority_allocation` (FCFS + capacity + assign_role). │
│    Mutabilidad: catálogo curado; cambios = mig + version bump.     │
└────────────────────────────────────────────────────────────────────┘
                              ▲ instantiated by user as
┌────────────────────────────────────────────────────────────────────┐
│ 3. RULE INSTANCE  (public.rules)                                   │
│    Template + scope (group/resource/series/…) + valores de params  │
│    + label personalizado del grupo ("Boletos del palco").          │
│    Mutabilidad: cada cambio crea una nueva rule_version (abajo).   │
└────────────────────────────────────────────────────────────────────┘
                              ▲ snapshot of
┌────────────────────────────────────────────────────────────────────┐
│ 4. RULE VERSION  (public.rule_versions, append-only)               │
│    `compiled` jsonb frozen: trigger/conditions/consequences        │
│    expandidos. Source of truth para el engine.                     │
│    Mutabilidad: NUNCA. Nueva versión = nuevo row.                  │
└────────────────────────────────────────────────────────────────────┘
                              ▲ executed against
┌────────────────────────────────────────────────────────────────────┐
│ 5. RULE EVALUATION  (public.rule_evaluations, append-only)         │
│    Cada disparo: (rule_version_id, trigger_atom_id, verdict,       │
│    consequences_emitted, idempotency_key). Audit técnico.          │
│    Mutabilidad: NUNCA. NO se muestra en user feed.                 │
└────────────────────────────────────────────────────────────────────┘

ATOMS         = realidad (system_events, ledger_entries, rsvp_actions, …)
PROJECTIONS   = interpretación (balance_view, attendance_view, …)
UI            = traducción (cards, sentence formatter, gallery)
```

### 1.2 La frase doctrinal

> **Templates son UX.**
> **Compiled rule versions son truth.**
> **Rule evaluations son audit.**
> **Atoms son reality.**
> **Projections son interpretation.**
> **UI es translation.**

### 1.3 Implicaciones operativas

- **Nunca** un template se ejecuta. El engine sólo ejecuta `rule_versions.compiled`. El template es UX/contrato; el rule_version es ley.
- **Nunca** se borra un rule_version. Desactivar = nuevo version con `status='inactive'`.
- **Nunca** un rule_evaluation aparece en el feed del usuario. El feed del usuario muestra **consequence atoms** (`fine_issued`, `role_assigned`, `vote_started`). El admin puede ver evaluations en una vista técnica.
- **Nunca** una rule muta estado directo (ej. `UPDATE groups SET fund_balance`). Sólo emite atoms o arranca workflows. Esto es invariante con `ConsistencyAudit_2026-05-17.md`.

---

## 2. El criterio de abstracción (test talmúdico)

### 2.1 La pregunta única

> **"¿Este template seguiría teniendo sentido en 10 verticales distintas?"**

Si la respuesta es "sí, ya pensé en al menos 5" → es template universal.
Si la respuesta es "depende del caso" → reabstraer.
Si la respuesta es "no, sólo aplica a X" → no es template; es feature vertical disfrazada. **Rechazar.**

### 2.2 Lista de palabras prohibidas en `template_id`

Cualquier template id que contenga una de estas palabras está mal abstraído:

```
dinner   soccer    wedding    parking    flight    restaurant   menu
school   palco     football   trip       car       table        seat
host     guest     player     student    driver    captain      starter
match    game      class      flight     ride      ticket
```

(Excepción: cuando aparezcan **como parámetros** de un template universal — ej. `priority_allocation` con `assignment_target_label="boleto del palco"` — el label es del grupo, no del template.)

### 2.3 La regla de reabstracción

| Caso concreto (mal) | Categoría universal (bien) |
|---|---|
| `soccer_starters` | `priority_allocation` (params: capacity=11, basis=check_in_order, target_role=starter) |
| `late_dinner_fee` | `missed_obligation_consequence` (params: obligation=check_in_on_time, consequence_kind=monetary) |
| `palco_ticket_assignment` | `priority_allocation` (params: capacity=N, basis=lottery|fcfs|priority_list) |
| `wedding_guest_approval` | `transfer_requires_approval` (params: transfer_kind=guest_invite, approver=admin|host) |
| `menu_selection_lock` | `acknowledgement_required` (params: action=submit_menu, deadline=X) |
| `cleaning_duty` | `rotating_responsibility` (params: pool=members, frequency=weekly) |
| `parking_spot` | `capacity_reservation` (params: capacity=N, window=duration) |
| `school_pickup_fine` | `attendance_enforcement` (params: deadline=event_start, grace_min=5) |
| `flight_no_show_fine` | `missed_obligation_consequence` (params: obligation=check_in, consequence_kind=monetary) |
| `office_room_lottery` | `lottery_allocation` (params: pool=eligible_members, capacity=N) |

> **Talmudic frame:** las categorías universales son al sistema lo que las categorías mishnaicas (custodia, daño, préstamo, voto, herencia, exención) son al derecho. No nombran el caso — nombran la **estructura de obligación**.

---

## 3. Taxonomía canónica de templates universales

> 9 categorías × ~50 templates totales. **Beta 1 = 5.** **Post-Beta-1 = 15.** **Resto = roadmap o "nunca".**

### A. Allocation Templates  *(repartir algo escaso entre miembros)*

| template_id | one-liner |
|---|---|
| `first_come_first_served` | Asignar por orden de llegada hasta cupo. |
| `priority_allocation` | Asignar por prioridad declarada (ranking/roles/historial) hasta cupo. |
| `lottery_allocation` | Asignar por sorteo entre elegibles hasta cupo. |
| `rotation_allocation` | Asignar rotando entre miembros según último turno. |
| `quota_allocation` | Asignar respetando cuota por subgrupo/rol. |
| `manual_assignment_with_audit` | Admin asigna manualmente; queda atom. |

### B. Capacity Templates  *(qué pasa cuando hay más demanda que oferta)*

| template_id | one-liner |
|---|---|
| `capacity_limit` | Bloquear/redirigir cuando se llega al cupo. |
| `waitlist_flow` | Mandar al waitlist cuando se llena; promover cuando se libera. |
| `overflow_handling` | Tratar overflow como warning, lottery, o reject. |
| `reservation_expiration` | Expirar reservas no usadas en N tiempo. |
| `unused_capacity_release` | Liberar capacidad asignada pero no ejercida. |

### C. Obligation Templates  *(exigir un acto en un tiempo o forma)*

| template_id | one-liner |
|---|---|
| `deadline_enforcement` | Exigir un acto antes de una fecha; si no, consecuencia. |
| `missed_obligation_consequence` | Aplicar consecuencia (fine, warning, restriction) si no se cumple. |
| `attendance_enforcement` | Exigir presencia (check-in) en ventana definida. |
| `payment_enforcement` | Exigir pago de una obligación monetaria antes de fecha. |
| `acknowledgement_required` | Exigir confirmación explícita (read-receipt, ack). |
| `recurring_obligation` | Repetir una obligación con frecuencia (semanal, mensual, …). |

### D. Governance Templates  *(meta-reglas — cómo se decide)*

| template_id | one-liner |
|---|---|
| `approval_required` | Una acción requiere aprobación previa de un rol. |
| `consensus_required` | Una acción requiere acuerdo de N% miembros. |
| `quorum_required` | Una decisión necesita quórum mínimo. |
| `vote_required` | Una acción se decide por voto formal con resultado vinculante. |
| `veto_right_required` | Un rol tiene veto sobre una decisión. |
| `escalation_if_unresolved` | Si no se resuelve en N tiempo, escala (admin, voto, default). |

### E. Access Templates  *(quién puede ejercer qué)*

| template_id | one-liner |
|---|---|
| `temporary_access` | Otorgar acceso por ventana de tiempo. |
| `conditional_access` | Acceso sólo si se cumple condición (rol, pago, ack). |
| `delegated_access` | Un miembro puede delegar su acceso a otro. |
| `access_revocation` | Revocar acceso bajo condición/atom. |
| `right_based_access` | Acceso derivado de un derecho otorgado formalmente. |
| `membership_gate` | Acceso a la membresía requiere paso previo (invitación, pago, voto). |

### F. Custody / Responsibility Templates  *(quién es responsable de qué)*

| template_id | one-liner |
|---|---|
| `custody_assignment` | Asignar custodia formal (con atom) a un miembro. |
| `custody_return_required` | Exigir devolución al final de ventana. |
| `damage_liability` | Responsabilizar por daño detectado durante custodia. |
| `rotating_responsibility` | Rotar una obligación entre miembros. |
| `maintenance_responsibility` | Asignar mantenimiento periódico. |

### G. Transfer Templates  *(mover algo de un actor a otro)*

| template_id | one-liner |
|---|---|
| `transfer_requires_approval` | Transferir requiere aprobación previa. |
| `delegation_requires_approval` | Delegar requiere aprobación. |
| `right_expiration` | Un derecho expira en fecha. |
| `right_exercise_limit` | Un derecho sólo puede ejercerse N veces. |
| `transfer_with_audit` | Cualquier transfer queda como atom auditable. |

### H. Money Templates  *(circulación de dinero)*

| template_id | one-liner |
|---|---|
| `expense_threshold_approval` | Gastos arriba de N requieren aprobación. |
| `contribution_requirement` | Exigir aportación periódica. |
| `reimbursement_flow` | Reembolsar gasto reportado bajo regla. |
| `fine_or_penalty` | Aplicar penalización monetaria por incumplimiento. |
| `payout_approval` | Pagos a un miembro requieren aprobación. |
| `spending_lock` | Bloquear gastos en condición (cuota llena, deadline, voto). |

### I. Exception Templates  *(romper reglas legítimamente)*

| template_id | one-liner |
|---|---|
| `member_exemption` | Exentar a un miembro específico de una rule. |
| `role_exemption` | Exentar a un rol específico. |
| `emergency_override` | Override con atom; admin justifica; queda auditable. |
| `admin_override_with_audit` | Admin puede pasar por encima dejando atom. |
| `one_time_exception` | Exención válida una sola vez. |

---

## 4. Beta 1 — 5 templates universales

> Recortados al mínimo viable que cubre cenas + fútbol + palcos + roommates con el shape catalog **ya existente** en `public.rule_shapes` post-migs 00084/00193/00194/00226/00257/00268.

### 4.1 Selección Beta 1

| # | template_id | UI label (es-MX) | Categoría | Shape pieces que compone |
|---|---|---|---|---|
| 1 | `deadline_enforcement` | "Exigir algo antes de una fecha" | C — Obligation | trigger: `hoursBeforeEvent` / `rsvpDeadlinePassed` ; consequence: `emitWarning` (existente del pilot 00193) |
| 2 | `missed_obligation_consequence` | "Aplicar consecuencia si alguien no cumple" | C — Obligation | trigger: `checkInRecorded` / `rsvpChangedSameDay` / `bookingNoCheckIn` ; condition: `checkInMinutesLate` / `cancelledWithinHours` ; consequence: `fine` |
| 3 | `priority_allocation` | "Repartir cupos limitados por prioridad" | A — Allocation | (requiere shape pieces nuevos — ver §10.3 — y por tanto entra a Beta 1 sólo si se aprueba antes del freeze close) |
| 4 | `approval_required` | "Pedir aprobación antes de una acción" | D — Governance | trigger: cualquier evento accionable ; consequence: `requireApproval` (existente) |
| 5 | `rotating_responsibility` | "Rotar una responsabilidad entre miembros" | F — Custody | (requiere shape `rotation_pick` + state projection — Post-Beta si no entra) |

> **Realismo:** sólo `deadline_enforcement`, `missed_obligation_consequence` y `approval_required` se pueden materializar **hoy sin nuevos shape pieces**. `priority_allocation` y `rotating_responsibility` requieren evaluadores nuevos en `ruleEngine.ts` y entran al backlog Post-Beta-1 / Sprint 5 del consistency audit. **Recomendación firme:** Beta 1 ship 3 templates universales (los 3 ejecutables) y se quedan los otros 2 para Post-Beta. Mejor 3 sólidos que 5 a medias.

### 4.2 Cómo cada template Beta 1 absorbe los actuales 12

| Template universal Beta 1 | Templates actuales que se reagrupan adentro |
|---|---|
| `missed_obligation_consequence` | `late_arrival_fine`, `no_show_fine`, `same_day_cancel_fine`, `no_rsvp_fine`, `host_no_menu_fine`, `not_returned_fine`, `space_cancellation_late_fine` |
| `deadline_enforcement` | `expense_threshold_warning`, `damage_logged_warning` |
| `approval_required` | `expense_threshold_vote`, `transfer_large_vote`, `space_long_booking_vote`, `space_damage_temporary_closure_vote` |
| `priority_allocation` *(post-Beta si no entra)* | — |
| `rotating_responsibility` *(post-Beta si no entra)* | — |

> **Implicación:** los 12 templates actuales **no son borrados**. Son **renombrados como instancias-por-default** de un template universal. El grupo que ya los tenía instanciados sigue viéndolos con su label actual ("multa por llegar tarde") — sólo cambia el `template_id` subyacente al universal correspondiente. Plan de renombrado: §14.

### 4.3 Lo que NO entra a Beta 1

- Custom Lego Builder (per-piece UI).
- AI rule creation (sí: AI propone draft; no: AI publica).
- Simulación / dry-run.
- Condiciones arbitrarias (`amountAbove`, `if-then-else` libres).
- Templates verticales (cualquier nombre con palabra prohibida §2.2).
- User-defined code.
- Marketplace.
- Loops, deadlocks, ambigüedad de prioridad cruzada.

---

## 5. Post-Beta — catálogo objetivo

> Orden recomendado por **valor / coste de evaluator nuevo**.

### 5.1 Wave 1 (primer trimestre post-Beta-1) — todo entra si demanda confirma

| template_id | Shapes nuevos requeridos |
|---|---|
| `priority_allocation` | `assign_participant_role`, `rank_by(projection)` condition |
| `rotating_responsibility` | `rotation_pick`, `pool_excluded` condition |
| `waitlist_flow` | `add_to_waitlist`, `promote_waitlist` |
| `quota_allocation` | `count_in_subgroup` condition |
| `lottery_allocation` | `random_pick` consequence |
| `delegation_requires_approval` | reuse `requireApproval` |
| `right_expiration` | `expire_right` cron consequence |
| `contribution_requirement` | trigger `contribution_period_passed` |
| `spending_lock` | `lock_capability` consequence |
| `admin_override_with_audit` | trigger `override_invoked`, queda audit |

### 5.2 Wave 2 (si modelos de Custody/Right/Slot maduran)

| template_id | Notas |
|---|---|
| `emergency_override` | Requiere atom `override_invoked` y journaling de razón. |
| `acknowledgement_required` | Requiere atom `acknowledgement_recorded`. |
| `recurring_obligation` | Requiere cron + atom `obligation_period_passed`. |
| `damage_liability` | Requiere modelo de daño tasado (existe parcialmente en asset). |
| `maintenance_responsibility` | Requiere cron + rotación. |
| `access_revocation` | Requiere modelo de acceso explícito (right capability maduro). |
| `right_exercise_limit` | Requiere contador por holder. |

### 5.3 NUNCA (explícito)

- `*_dinner_*`, `*_soccer_*`, `*_palco_*`, etc. — verticales.
- Custom Lego builder público.
- Templates sin shape pieces que no estén catalogados.
- Templates que muten estado directo.
- AI que publique sin humano en el loop.

---

## 6. Template Contract (definición completa por template)

> Cada template **debe** declarar los 22 campos siguientes. CI bloquea publish sin esto. Mirror del campo Shape Contract pero a nivel receta.

```yaml
template_id:             priority_allocation               # snake_case, universal, sin verticales
version:                 1                                  # bump = nuevo row en mig
doctrinal_category:      A — Allocation                     # mapeo §3
universal_pattern:       "Asignar acceso/rol/slot/derecho escaso según orden de prioridad declarado."
what_it_is_NOT:
  - soccer_lineup
  - ticket_assignment
  - parking_assignment
  - palco_seating
compatible_resource_types:
  - event
  - asset
  - space
  - slot
  - right
required_capabilities:                                       # caps del resource que deben estar prendidas
  - priority_basis_declared
supported_scopes:                                            # subset del 7-level precedence
  - resource
  - resource_type
  - series
trigger_pieces:                                              # shape pieces de kind=trigger
  - capability_demand_recorded
condition_pieces:
  - rank_above_capacity   # opcional
consequence_pieces:
  - assign_participant_role
  - emit_warning           # para los que no entraron
user_parameters:                                             # lo que el usuario llena en la UI
  - key: capacity
    type: int
    label_es: "¿Cuántos cupos?"
    min: 1
  - key: priority_basis
    type: enum
    label_es: "¿Cómo se ordenan?"
    enum_values: [check_in_order, declared_ranking, role_score, lottery]
  - key: assignment_target_role
    type: text
    label_es: "Etiqueta del rol asignado"
    placeholder: "titular | beneficiario | tenedor"
  - key: overflow_behavior
    type: enum
    label_es: "¿Qué pasa con los que no caben?"
    enum_values: [waitlist, warning, silent]
default_parameters:
  overflow_behavior: warning
natural_language_preview_template_es:
  "Cuando haya cupo limitado para {{resource.name}}, los miembros elegibles
   serán asignados según {{priority_basis_human}}. Los primeros {{capacity}}
   recibirán el rol {{assignment_target_role}}; los demás quedarán en
   {{overflow_behavior_human}}."
examples_across_verticals:
  - vertical: Fútbol
    label_grupo: "Titulares del partido"
    params: { capacity: 11, priority_basis: check_in_order, assignment_target_role: titular, overflow_behavior: warning }
  - vertical: Palco
    label_grupo: "Boletos del palco"
    params: { capacity: 5, priority_basis: declared_ranking, assignment_target_role: tenedor, overflow_behavior: waitlist }
  - vertical: Coworking
    label_grupo: "Salas privadas"
    params: { capacity: 3, priority_basis: lottery, assignment_target_role: tenedor, overflow_behavior: silent }
  - vertical: Roommates
    label_grupo: "Cuartos elegidos al mudarse"
    params: { capacity: 4, priority_basis: declared_ranking, assignment_target_role: tenedor, overflow_behavior: silent }
  - vertical: Familia
    label_grupo: "Uso del coche familiar"
    params: { capacity: 1, priority_basis: declared_ranking, assignment_target_role: conductor, overflow_behavior: waitlist }
atoms_emitted:
  - allocation_assigned
  - waitlist_joined
  - allocation_released
projections_read:
  - priority_order_view
  - current_allocation_view
projections_affected:
  - waitlist_view
  - current_allocation_view
conflicts_to_detect:
  - same_scope_overlapping             # bloqueante
  - capacity_missing                   # bloqueante
  - priority_basis_missing             # bloqueante
  - overflow_behavior_invalid          # bloqueante
  - consequence_missing_capability     # bloqueante
permissions_required:
  publish: governance.rule.publish
  modify: governance.rule.modify
beta_status:                                                  # Beta 1 | Post-Beta | Never
  classification: Post-Beta
  reason: "Requiere shape pieces nuevos (rank_above_capacity, assign_participant_role) que aún no tienen evaluator en ruleEngine.ts."
tests_required:
  - allocation_full_then_waitlist
  - allocation_release_promotes_first_waitlist
  - tie_breaker_deterministic
  - overflow_warning_only
  - inactive_rule_no_assignment
  - changed_capacity_doesnt_revoke
  - replay_idempotent_under_retry
```

---

## 7. Ejemplos cruzados a través de verticales

Para forzar la validación del criterio de §2.1, cada template Beta 1 debe declarar ≥5 verticales reales.

### 7.1 `missed_obligation_consequence`

| Vertical | Acto incumplido | Consequence |
|---|---|---|
| Cenas | RSVP=sí + no check-in | fine $100 + warning |
| Fútbol | Inscrito + no llega | fine + bench siguiente partido |
| Palco | Reservó boleto + no asistió | fine + pierde prioridad N partidos |
| Roommates | Turno limpieza + no hecho | fine + warning + rotación |
| Coworking | Reservó sala + no usó | warning + costo de no-show |
| Familia | Confirmó comida + no llegó | warning |
| Viajes | Comprometió pago + no pagó | fine + remoción del viaje |

### 7.2 `deadline_enforcement`

| Vertical | Acto requerido | Deadline |
|---|---|---|
| Cenas | RSVP confirmado | 24h antes |
| Fútbol | Confirmar lineup | 12h antes |
| Palco | Elegir boletos | 48h antes |
| Roommates | Pagar renta del mes | día 5 del mes |
| Coworking | Confirmar reserva | 2h antes |
| Asociación | Subir documento anual | fecha fija |
| Familia | Avisar ausencia comida | mediodía sábado |

### 7.3 `approval_required`

| Vertical | Acción que requiere approval | Approver |
|---|---|---|
| Cenas | Invitar a un guest | host |
| Fútbol | Transferir titularidad | captain |
| Palco | Subarrendar boleto | dueño del palco |
| Roommates | Mudar a alguien | mayoría |
| Familia | Gasto > $2000 | tesorero |
| Coworking | Reservar sala > 4h | admin |
| Viajes | Invitar a un externo | quórum |

### 7.4 `priority_allocation` *(si entra)*

(Ver §6 — ya cubierto en `examples_across_verticals`.)

### 7.5 `rotating_responsibility` *(si entra)*

| Vertical | Responsabilidad rotada | Frecuencia |
|---|---|---|
| Cenas | Cocinar / hostear | semanal |
| Roommates | Sacar basura | semanal |
| Familia | Pasear al perro | diaria |
| Asociación | Tomar minuta | por reunión |
| Viajes | Manejar | por tramo |
| Coworking | Limpiar cocineta | semanal |

---

## 8. UX flow — Template como Lego humano

### 8.1 La promesa al usuario

> **"Elige un patrón → llena los huecos → mira cómo se lee → actívalo."**

NUNCA: "elige trigger → elige condition → elige consequence". Esa UI existe pero queda admin-only/oculta (`EditRulesView` actual).

### 8.2 Las 4 fases visibles (NO 8 stages internas)

```
┌──────────────┐    ┌──────────────┐    ┌──────────────┐    ┌──────────────┐
│ 1. Gallery   │ →  │ 2. Param     │ →  │ 3. Preview   │ →  │ 4. Publish   │
│              │    │    form      │    │              │    │              │
│ tarjetas con │    │ chips/      │    │ "Así se va  │    │ "Activar"   │
│ icono +      │    │ inputs por   │    │  a leer."    │    │ + scope     │
│ una línea +  │    │ param        │    │ Sticky en   │    │  selector    │
│ chips de     │    │ dinámicos    │    │  bottom.     │    │              │
│ ejemplos     │    │              │    │              │    │              │
└──────────────┘    └──────────────┘    └──────────────┘    └──────────────┘
```

### 8.3 Anatomía de una tarjeta en Gallery

```
┌──────────────────────────────────────────────────┐
│  [icono]   Exigir algo antes de una fecha        │
│                                                  │
│  "Si alguien no hace X antes de Y, se aplica Z."│
│                                                  │
│  Ejemplos: confirmar RSVP · pagar renta ·       │
│  subir documento                                 │
│                                                  │
│  Esto NO: limitar cuántos pueden hacerlo.       │
└──────────────────────────────────────────────────┘
```

Cada tarjeta carga:

- **Icono** SF Symbol declarado en el template.
- **Título humano** (`displayNameES`).
- **Descripción de una línea** (`descriptionES`).
- **Ejemplos cortos** (3 chips, máximo 4 palabras cada uno).
- **"Esto NO" antitemplate** — una línea sobre qué confusión evitar (importante: distingue `deadline_enforcement` de `capacity_limit`).
- **Categoría** (badge: Allocation / Obligation / Governance / …).

### 8.4 Param form

- Cada parámetro = un chip o un input minimalista.
- Sin labels técnicos. ("¿Cuántas horas antes?" no "trigger.hours").
- Defaults pre-rellenados desde `default_parameters`.
- Validación inline (rangos, requeridos).
- **Preview sticky** en bottom: oración en español que se actualiza en cada cambio de param.

### 8.5 Preview (la oración es source-of-truth UX)

```
"Si alguien no confirma asistencia 24 horas antes de la cena de los
jueves, se le cobrará $200."
```

> **Regla cardinal:** si la oración no se puede armar de forma clara, el template está mal diseñado. La oración es el contrato visual con el usuario.

### 8.6 Publish

- Selector de scope (chips visuales: "Esta cena" / "Todas las cenas de los jueves" / "Todo el grupo").
- Click "Activar" → llama a `publish_rule_composition` (existe).
- Modal de conflictos si hay; bloquea publish si severidad=`blocking`.
- Toast confirmando y deep-link a la rule recién creada.

### 8.7 Lenguaje a usar / evitar

| NO decir | SÍ decir |
|---|---|
| trigger | cuando pase |
| condition | si aplica |
| consequence | entonces |
| projection | (no se menciona) |
| atom | (no se menciona) |
| resource_type | dónde aplica |
| capability | qué puede hacer el grupo |
| scope | dónde aplica |
| target | a quién/qué afecta |
| compile | (no se menciona) |
| evaluate | (no se menciona) |

### 8.8 Personalización por grupo (label de la instancia)

El template subyacente nunca cambia:

```
template_id: priority_allocation     ← canonical, universal
```

El grupo le pone su nombre:

```
rule_instance.label_es: "Boletos del palco"
rule_instance.label_es: "Titulares del partido"
rule_instance.label_es: "Turnos de manejo"
```

El engine sólo lee `template_id`. La UI sólo muestra `label_es`. Cero coupling entre groups y nombres de template.

---

## 9. Swift / iOS — recomendaciones de modelo

### 9.1 Modelos a tocar (todos ya existen)

- `RuleBuilderTemplate.swift` — agregar campos para soportar el contrato §6:
  - `doctrinalCategory: String` (badge en la gallery)
  - `whatItIsNot: [String]` (antitemplate para la card)
  - `examplesAcrossVerticals: [TemplateExample]` (chips en la card)
  - `naturalLanguagePreviewTemplate: String` (replaza el actual sentence formatter hardcoded en `RuleBuilderSentenceFormatter`)
  - `conflictsToDetect: [String]`
  - `betaStatus: BetaStatus` (`.beta1` / `.postBeta` / `.never`)

- `RuleBuilderSentenceFormatter.swift` — **deprecar el switch hardcoded por template_id**. Reemplazar por un **templated string interpolator** que tome el `naturalLanguagePreviewTemplate` del catálogo y sustituya `{{params}}` con los valores actuales. Mismo principio runtime-declarative del founder principle 2026-05-10 — no más Swift code per template.

- `RuleBuilderView.swift` — Gallery debe mostrar `doctrinalCategory`, `whatItIsNot`, `examplesAcrossVerticals`. ParamForm debe leer `userParameters` del template y renderizar inputs/chips dinámicamente (ya casi lo hace; consolidar para que NO haya `if template_id == X` en la view).

### 9.2 Anti-patrón a eliminar en Swift

```swift
// NO esto:
switch template.id {
case "late_arrival_fine":  return "Si alguien llega tarde…"
case "no_show_fine":       return "Si alguien no llega…"
case "expense_threshold_warning": return …
…
}

// SÍ esto:
return template.naturalLanguagePreviewTemplate.interpolate(with: params)
```

El sentence formatter actual viola el principio "no hardcoded vertical logic" (memoria `feedback_no_hardcoded_verticals`). El refactor del sentence formatter es **prerequisito** del renombrado de §14.

### 9.3 Compatibility con `EditRulesView` (per-piece, admin-only)

- Mantener tal cual. Es la red de seguridad cuando un template no cubre un caso exótico.
- Gate por permiso `governance.rule.edit_per_piece` (rol admin/owner).
- No promoverla a usuario final hasta que el shape registry muestre patrones repetidos que justifiquen otro template.

---

## 10. Server validation — recomendaciones

### 10.1 Validaciones a nivel `publish_rule_composition` / `publish_rule_version`

| Validación | Severidad | Mensaje (es-MX) |
|---|---|---|
| `template_id` no existe en `public.rule_templates` | blocking | "Template no encontrado." |
| `shape_id` referenciado por el template no existe o está deshabilitado | blocking | "Pieza de regla no disponible." |
| `required_capabilities` no están todas activas en el scope | blocking | "Faltan capabilities: X, Y." |
| `scope.type` no está en `supported_scopes` del template | blocking | "Esta regla no aplica a este nivel." |
| Falta un parámetro requerido | blocking | "Falta: {param_label}." |
| Parámetro fuera de rango/enum | blocking | "Valor inválido para {param_label}." |
| `same_scope_overlapping` con otra rule activa | warning (Beta 1) → blocking (Post-Beta para los críticos: dos rules con consecuencia `fine` sobre el mismo trigger atom) | "Ya hay una regla similar activa: {other_rule_title}." |
| `consequence_missing_capability` | blocking | "No se puede aplicar {consequence_kind} porque el grupo no tiene la capability requerida." |
| `impossible_condition` (ej. deadline después de event_end) | blocking | "La condición no se puede cumplir nunca." |

### 10.2 Validaciones a nivel template (catálogo, build-time / CI)

Para cualquier row nueva en `public.rule_templates`, CI bloquea si:

1. `template_id` contiene una palabra prohibida (§2.2).
2. `examples_across_verticals` tiene < 5 entradas.
3. `natural_language_preview_template_es` no se puede interpolar con `default_parameters` (test de smoke).
4. `conflicts_to_detect` está vacío.
5. `atoms_emitted` está vacío y `consequence_pieces` no es `emit_warning` puro.
6. Algún `shape_id` referenciado no existe o no tiene evaluator en `ruleEngine.ts`.
7. `tests_required` tiene < 5 fixtures.

### 10.3 Shape pieces nuevos necesarios para Post-Beta-1 Wave 1

Para soportar `priority_allocation`, `rotating_responsibility`, `waitlist_flow`, `quota_allocation`:

| shape_id | kind | Evaluator necesario |
|---|---|---|
| `rank_by` | condition | Leer `position(actor, ordered_projection)` |
| `assign_participant_role` | consequence | Emitir `participantRoleAssigned` atom |
| `rotation_pick` | consequence | Emitir `rotationAssigned` atom; usa `last_assigned_at` projection |
| `add_to_waitlist` | consequence | Emitir `waitlistJoined` atom |
| `promote_waitlist` | consequence | Emitir `waitlistPromoted` atom; trigger en `allocation_released` |
| `count_in_subgroup` | condition | Leer count filtrado por rol/membership |
| `random_pick` | consequence | Emitir `lotteryAllocated` atom (semilla determinística por `rule_version_id`) |
| `expire_right` | consequence | Cron-driven; emite `rightExpired` |
| `lock_capability` | consequence | Emite `capabilityLocked` atom |

Cada uno requiere: INSERT en `rule_shapes` + evaluator en `_shared/ruleEngine.ts` + fixtures + RLS + post-atom guard (`*_atom_guard` trigger en cualquier nueva atom table).

---

## 11. Data model — recomendaciones

### 11.1 Lo que ya existe y se mantiene

- `public.rule_shapes` (mig 00084) — runtime catalog de Legos atómicos.
- `public.rule_templates` (mig 00181) — mirror del catálogo TS.
- `public.rules` — instancia.
- `public.rule_versions` (mig 00181) — snapshots append-only.
- `public.rule_evaluations` (mig 00181) — audit append-only.

### 11.2 Columnas a agregar a `public.rule_templates`

```sql
alter table public.rule_templates
  add column if not exists doctrinal_category text not null default 'uncategorized',
  add column if not exists what_it_is_not text[] not null default '{}',
  add column if not exists examples_across_verticals jsonb not null default '[]'::jsonb,
  add column if not exists natural_language_preview_template_es text,
  add column if not exists conflicts_to_detect text[] not null default '{}',
  add column if not exists beta_status text not null default 'post_beta'
    check (beta_status in ('beta1','post_beta','never')),
  add column if not exists supported_scopes text[] not null default '{}',
  add column if not exists tests_required text[] not null default '{}';

create index if not exists idx_rule_templates_category
  on public.rule_templates(doctrinal_category)
  where status = 'active';
```

Plus CI check (TS lint task) que valida los 7 puntos de §10.2 antes de aceptar PR.

### 11.3 Instancia: label personalizado

```sql
-- public.rules ya tiene title; promoverla a campo de UX explícito
alter table public.rules
  add column if not exists label_es text;

-- Backfill: title actual → label_es donde label_es is null
update public.rules set label_es = title where label_es is null;

comment on column public.rules.label_es is
  'Nombre humano que el grupo le pone a la rule (ej. "Boletos del palco"). NO confundir con template_id (universal canonical).';
```

### 11.4 NO crear

- `template_categories` tabla separada — categorías son enum cerrado en código (`doctrinal_category text` en `rule_templates` basta).
- `vertical_templates` tabla — no existe el concepto de "template vertical".
- `template_marketplace` — out of scope, posiblemente nunca.

---

## 12. Conflict detection — estrategia

### 12.1 Conflictos detectados Beta 1 (publish-time)

- `same_scope_overlapping` — warning.
- `consequence_missing_capability` — blocking.
- `impossible_condition` — blocking.

### 12.2 Conflictos detectados Post-Beta-1 (publish-time)

- `contradictory_consequences` — blocking (dos rules sobre mismo trigger, una `fine`, otra `lottery_winner` sobre el mismo atom).
- `priority_ambiguity` — warning (dos rules `priority_allocation` en mismo scope con basis distinto).
- `quota_overlap` — warning (dos `quota_allocation` con subgrupos solapados).
- `approval_loop` — blocking (A requiere approval de B; B de C; C de A).

### 12.3 Conflictos detectados Post-Beta-2 (runtime)

- `loop_detected` — un consequence atom dispara su propio trigger ad infinitum. El engine corta a N=10 niveles y emite `rule_loop_aborted` atom. El admin ve el incidente y el version inculpado se marca `status='quarantined'`.
- `evaluation_storm` — > 100 evaluations en < 1s sobre el mismo rule_version_id. Emite `evaluation_storm_detected` y rate-limita.

### 12.4 No detectados (humano decide)

- "¿Esta rule es justa?" — no es trabajo del engine.
- "¿Esta rule contradice el espíritu del grupo?" — no es trabajo del engine.

---

## 13. Test strategy

### 13.1 Fixtures obligatorios por template (≥ 5)

Cada template publica `tests_required: [...]` en su contract (§6). Tipos canónicos:

- **Happy path** — trigger ocurre, condition pasa, consequence se emite, atom queda.
- **Condition fails** — trigger ocurre, condition NO pasa, consequence NO se emite.
- **Idempotency** — mismo trigger 3 veces → 1 consequence atom (no 3).
- **Rule deactivated** — rule inactiva, trigger ocurre, nada se emite.
- **Conflict** — dos rules en mismo scope, publish bloquea con conflict signature.
- **Replay** — re-ejecutar todos los atoms históricos contra `rule_version_id` produce mismo estado final.

### 13.2 Suite a nivel iOS

- Snapshot test del Gallery (12 templates universales — render correcto).
- Snapshot test del ParamForm por template (defaults rellenan, validación falla con valores inválidos).
- Sentence formatter — test que toda combinación de defaults produce oración bien formada en es-MX.

### 13.3 Suite a nivel server

- `_shared/ruleEngine.test.ts` — por cada shape piece, tests del evaluator.
- `publish_rule_composition` — tests de validaciones §10.1.
- CI lint — tests de §10.2.

### 13.4 Manual smoke por release

- Founder demo dry-run en device: crear 1 rule de cada template universal, verificar oración, publicar, disparar trigger, ver consequence.

---

## 14. Migration plan — renombrado de los 12 templates actuales

> **Ejecutar SOLO después del cierre de los 4 sprints del `ConsistencyAudit_2026-05-17.md`.** Mientras tanto: doctrina escrita, código sin tocar.

### 14.1 Mapeo template actual → template universal

| Actual | Universal | Acción |
|---|---|---|
| `late_arrival_fine` | `missed_obligation_consequence` | Renombrar `template_id`; alias en mig; UI sigue mostrando label-de-grupo. |
| `no_show_fine` | `missed_obligation_consequence` | Mismo. Default params distintos. |
| `same_day_cancel_fine` | `missed_obligation_consequence` | Mismo. |
| `no_rsvp_fine` | `missed_obligation_consequence` | Mismo. |
| `host_no_menu_fine` | `acknowledgement_required` *(Wave 2)* o `missed_obligation_consequence` *(transitorio)* | Por ahora: dentro de `missed_obligation_consequence` con `obligation_kind=submit_menu`. Wave 2 lo promueve. |
| `expense_threshold_warning` | `deadline_enforcement` (warning-only branch) | Renombrar; el threshold = "deadline" en sentido amplio. |
| `expense_threshold_vote` | `approval_required` (vote variant) | Renombrar. |
| `not_returned_fine` | `missed_obligation_consequence` | Renombrar; `obligation_kind=return_asset`. |
| `transfer_large_vote` | `approval_required` | Renombrar. |
| `damage_logged_warning` | `deadline_enforcement` (warning-only branch) o `damage_liability` *(Wave 2)* | Transitorio: `deadline_enforcement`. Wave 2 promueve. |
| `space_cancellation_late_fine` | `missed_obligation_consequence` | Renombrar. |
| `space_long_booking_vote` | `approval_required` | Renombrar. |
| `space_damage_temporary_closure_vote` | `approval_required` (con consequence `lock_capability` — Post-Beta) | Renombrar. |

### 14.2 Mecánica de renombrado (sin romper instancias existentes)

```sql
-- Paso 1: agregar alias_of column al catálogo
alter table public.rule_templates
  add column if not exists alias_of text references public.rule_templates(id);

-- Paso 2: insertar templates universales nuevos
insert into public.rule_templates (id, display_name_es, description_es, doctrinal_category, ...)
values
  ('missed_obligation_consequence', 'Consecuencia por incumplir', ..., 'C — Obligation', ...),
  ('deadline_enforcement', 'Exigir algo antes de una fecha', ..., 'C — Obligation', ...),
  ('approval_required', 'Pedir aprobación antes de una acción', ..., 'D — Governance', ...);

-- Paso 3: marcar templates actuales como alias
update public.rule_templates set alias_of = 'missed_obligation_consequence'
  where id in ('late_arrival_fine', 'no_show_fine', 'same_day_cancel_fine',
               'no_rsvp_fine', 'host_no_menu_fine', 'not_returned_fine',
               'space_cancellation_late_fine');

update public.rule_templates set alias_of = 'deadline_enforcement'
  where id in ('expense_threshold_warning', 'damage_logged_warning');

update public.rule_templates set alias_of = 'approval_required'
  where id in ('expense_threshold_vote', 'transfer_large_vote',
               'space_long_booking_vote', 'space_damage_temporary_closure_vote');

-- Paso 4: las rules existentes siguen apuntando al template_id antiguo;
-- el engine resuelve alias en publish_rule_composition.
-- Nuevas rules apuntan directo al universal.

-- Paso 5 (deprecación graceful, +1 mes): UI deja de mostrar aliased
-- templates en Gallery. Sólo aparecen los universales.
-- Las instancias antiguas siguen funcionando — el engine resuelve.

-- Paso 6 (cleanup, +3 meses): drop alias rows si zero rules dependen.
```

### 14.3 Cambios en iOS

- `RuleBuilderSentenceFormatter` — eliminar el switch hardcoded; usar `naturalLanguagePreviewTemplate` del template (template universal lo carga).
- `RuleBuilderView` — Gallery filtra `where alias_of is null` para mostrar sólo universales.
- `RulesView` (lista de rules de un grupo) — sigue mostrando `rule.label_es`; cero impacto.
- Codegen — re-correr para generar TS types de las nuevas columnas.

### 14.4 Comunicación al usuario

Nada. El usuario nunca conoció los template_ids. Sigue viendo "Multa por llegar tarde" — la palanca subyacente cambió, la experiencia no.

### 14.5 Schedule estimado (post audit-close)

| Semana | Trabajo |
|---|---|
| W+1 | Migs: nuevas columnas + universales seeded + alias map |
| W+2 | iOS: sentence formatter declarativo + Gallery filter |
| W+3 | Tests (fixtures por universal + smoke) |
| W+4 | Founder demo + freeze de catálogo Beta 1 |

### 14.6 Estado de implementación 2026-05-18 (refresh post-mig 00325 + pipeline unification)

Implementadas migs 00295/00296/00297/00320/00321/00325 + Swift refactor + Wizard pipeline unification + step 4 dedupe. Commits relevantes: `d018966`, `63d3aa2`, `40f5be6`, `dc2ee4b`, `668b5ea`, `1ad50d1`, `a579c24`, `8c4a678`, `871d443`.

**Gallery actual: 16 universales beta1.**

| # | template_id | doctrinal | trigger | consequence |
|---|---|---|---|---|
| 1 | `deadline_enforcement` | C — Obligation | `hoursBeforeEvent` | `emitWarning` |
| 2 | `missed_obligation_consequence` | C — Obligation | `checkInRecorded` | `fine` |
| 3 | `no_show_consequence` | C — Obligation | `eventClosed` | `fine` |
| 4 | `late_cancellation_consequence` | C — Obligation | `rsvpChangedSameDay` | `fine` |
| 5 | `no_rsvp_consequence` | C — Obligation | `rsvpDeadlinePassed` | `fine` |
| 6 | `cancellation_consequence` | C — Obligation | `eventCancelled` | `fine` |
| 7 | `deadline_consequence` | C — Obligation | `hoursBeforeEvent` | `fine` |
| 8 | `booking_cancellation_consequence` | C — Obligation | `bookingCancelled` | `fine` |
| 9 | `approval_required` | D — Governance | `ledgerEntryCreated` | `requireApproval` |
| 10 | `damage_approval` | D — Governance | `damageReported` | `requireApproval` |
| 11 | `damage_vote_required` | D — Governance | `damageReported` | `startVote` |
| 12 | `vote_required` | D — Governance | `ledgerEntryCreated` | `startVote` |
| 13 | `booking_vote_required` | D — Governance | `bookingCreated` | `startVote` |
| 14 | `expiration_warning` | D — Governance | `rightExpiringSoon` | `emitWarning` |
| 15 | `late_return_consequence` | F — Custody | `checkoutOverdue` | `fine` |
| 16 | `transfer_vote_required` | G — Transfer | `assetTransferred` | `startVote` |

**Alias status (14 legacy templates): 14 correctos, 0 mismatches.**

Verificación: `select count(*) from public.rule_templates legacy join public.rule_templates u on u.id = legacy.alias_of where legacy.alias_of is not null and legacy.composition->>'trigger_shape_id' <> u.composition->>'trigger_shape_id'` devuelve **0**.

**iOS:**
- `AppState.ruleTemplatesForGallery` filtra `aliasOf == nil && status == "active" && betaStatus == "beta1"` (16 rows hoy).
- `UniversalTemplateGallerySheet` renderiza cards canónicas con badge doctrinal + preview interpolado + antitemplate + chips por vertical. Reachable desde `RulesView` empty-state CTA y desde `RuleComposerView` toolbar.
- `ResourceWizardSheet` step 4 separa **PATRONES UNIVERSALES** (canónico, render desde catálogo) de **Acciones adicionales** (legacy `CapabilityRuleOption` sin universal counterpart — 2 opciones hoy).
- `publishSelectedUniversals(resourceId:)` publica vía `ruleTemplateRepo.publishRuleVersion` para 2 sources: picks explícitos del universals section + picks de capabilities que mapean a universal (cf. `selectedCapabilityUniversalPublishes`).
- Step 5 (review) consolida los 3 buckets en una sola lista ordenada — sin duplicados.

### 14.7 ~~Wave-1 followup migs~~ — CERRADO

Tabla original anticipaba migs 00322-00328. **Todo absorbido en mig 00325** (un solo mig que ship 10 universales + re-alias 9 legacies + valida 0 mismatches via do-block). Detalle de cobertura:

| Universal shipped | Cierra alias mismatch del legacy |
|---|---|
| `cancellation_consequence` | `cancellation_fee` |
| `late_return_consequence` | `not_returned_fine` |
| `deadline_consequence` | `host_no_menu_fine` |
| `expiration_warning` | `right_expiration_warning` |
| `booking_cancellation_consequence` | `space_cancellation_late_fine` |
| `damage_approval` | `damage_approval_required` |
| `damage_vote_required` | `space_damage_temporary_closure_vote` |
| `vote_required` | `expense_threshold_vote` |
| `transfer_vote_required` | `transfer_large_vote` |
| `booking_vote_required` | `space_long_booking_vote` |

### 14.8 Wave-2 followup (pendiente — bloqueado por audit-close)

Quedan 2 universales sin cubrir porque requieren shape pieces que no existen en el catálogo:

| Universal pendiente | Composición esperada | Shape piece nuevo necesario | Bloquea |
|---|---|---|---|
| `notification_reminder` | `rsvpDeadlinePassed` o `hoursBeforeEvent` + `sendNotification` | `sendNotification` consequence + evaluator en `ruleEngine.ts` | Cubrir `rsvp_no_response_reminder` legacy option |
| `rotation_skip_consequence` | `rsvpChangedSameDay` (host) + `loseTurn` | `loseTurn` consequence + evaluator + atom type (`turnSkipped`?) | Cubrir `rotation_auto_skip_late_cancel` legacy option |

Estos 2 universales no se pueden shippear durante el audit freeze porque introducen código de evaluator nuevo (= "new feature" del lente del freeze). Post audit-close:

1. Mig: añadir shape pieces `sendNotification` y `loseTurn` a `public.rule_shapes` (catalog rows + config_fields).
2. Evaluators TS: implementar en `_shared/ruleEngine.ts`.
3. Atoms: si `loseTurn` requiere atom propio (`turnSkipped`), añadirlo al `is_known_system_event_type` whitelist + emisor.
4. Mig: seed `notification_reminder` y `rotation_skip_consequence` como templates universal beta1.
5. Wizard: re-alias `rsvp_no_response_reminder` → `notification_reminder` y `rotation_auto_skip_late_cancel` → `rotation_skip_consequence`. Universal templates atrapan los 2 últimos casos legacy.
6. Wizard step 4: `additionalOptionsSection` colapsa a vacío (nada que renderizar) → step potencialmente se skip si universals son los únicos.
7. Cleanup: borrar `CapabilityRuleOption.suggestedRules` arrays vacíos en `CapabilityCatalog.swift`; potencialmente borrar struct entera si nada más la usa.

Post-Wave-2: pipeline 100% unificada, legacy `createInitialRules` path eliminable.

### 14.9 Wave-3 followup (post-Beta-1)

Universales adicionales del catálogo §3 que requieren shape pieces nuevos (no existentes en `public.rule_shapes`):

| Universal | Shape pieces nuevos requeridos |
|---|---|
| `priority_allocation` | `rank_by` condition + `assign_participant_role` consequence |
| `rotating_responsibility` | `rotation_pick` + `pool_excluded` |
| `waitlist_flow` | `add_to_waitlist` + `promote_waitlist` |
| `quota_allocation` | `count_in_subgroup` |
| `lottery_allocation` | `random_pick` |
| `right_expiration` | `expire_right` cron consequence |
| `contribution_requirement` | trigger `contribution_period_passed` |
| `spending_lock` | `lock_capability` (parcialmente existe via `lockBookings`) |
| `admin_override_with_audit` | trigger `override_invoked` |

Cada uno = INSERT en `rule_shapes` + evaluator + fixtures + RLS + atom guard si emite a tabla nueva. Sin urgencia hasta que el grupo founder pida algo que requiera estos patrones.

---

## 15. What NOT to build (explícito)

1. **Templates con nombres verticales.** Ya cubierto §2.2. Cualquier PR con `template_id` que contenga palabra prohibida = revert.
2. **Custom Lego Builder público.** Mantener `EditRulesView` admin-only. No promover a usuario final hasta que el shape registry muestre patrones repetidos (≥3 grupos pidiendo la misma combinación no-cubierta).
3. **AI que publique rules sin humano.** AI puede draftear shape + params; humano siempre confirma vía Template gallery → preview → publish.
4. **Simulación / dry-run en Beta 1.** Demanda escasa; coste de eng alto.
5. **Marketplace de templates.** Anti-doctrina: si el template es universal, no necesita marketplace.
6. **Templates que muten estado directo** (`UPDATE groups SET …`). Viola Article 7 + cardinal rule 2. Bloqueado a nivel CI.
7. **Templates con condiciones arbitrarias** (`amountAbove`, `if (x > y) { … }` libre). Sólo condiciones del shape catalog.
8. **Templates per resource_type** (ej. `event_late_arrival_fine`, `asset_late_arrival_fine`, `space_late_arrival_fine`). Es ineficiente y rompe abstracción. Un solo `missed_obligation_consequence` con `compatible_resource_types: [event, asset, space]` cubre todo.
9. **Subdivisiones de grupo por vertical.** El group es la primitiva; los templates son universales; las instancias se nombran como el grupo quiera.
10. **Hardcoded sentence formatters por template** en Swift. Declarativo o nada.

---

## 16. Doctrina final canónica

> **Rule templates are universal social/legal patterns.**
> **They are not vertical features.**
>
> **Templates help humans configure governance without programming.**
> **Templates compile into rule versions.**
>
> **Rule versions are truth.**
> **Rule evaluations are audit.**
> **Atoms are reality.**
> **Projections are interpretation.**
> **UI is translation.**
>
> **No template should exist merely because one vertical requested it.**
> **It should exist because it captures a recurring human coordination pattern.**

### 16.1 Las 10 reglas constitucionales de templates

1. **Universalidad obligatoria** — un template debe aplicar a ≥5 verticales o no es template.
2. **Sin palabras verticales en `template_id`** — lista prohibida §2.2.
3. **Una receta, muchas instancias** — el template subyacente no cambia cuando el grupo le pone su nombre.
4. **Catálogo curado, no abierto** — admisión de templates pasa por test §2 y CI §10.2.
5. **Shape pieces son el límite de ejecución** — un template no puede componer pieces que no existen.
6. **Engine sólo ejecuta rule_versions** — el template es UX; el version es ley.
7. **Cero hardcoded vertical logic en cliente** — sentence formatter declarativo, gallery declarativa, validación declarativa.
8. **Personalización es label, no template** — el grupo nombra su instancia; el catálogo se queda quieto.
9. **AI propone, humano publica, engine ejecuta** — no se rompe en ningún caso.
10. **Cuando hay duda, sube de abstracción** — si dos templates parecen distintos pero comparten estructura, son uno solo con params distintos.

---

## 17. Estado y siguientes pasos

- **Hoy (2026-05-17):** doctrina escrita. Freeze del audit activo. No se toca código de templates ni shapes hasta cierre.
- **Post audit-close:** ejecutar §14 (renombrado) en 4 semanas.
- **Wave 1 post-Beta-1:** `priority_allocation` + `rotating_responsibility` + `waitlist_flow` (requieren shape pieces nuevos §10.3).
- **Wave 2:** `acknowledgement_required`, `damage_liability`, `recurring_obligation`, `right_expiration`, `right_exercise_limit`.
- **Cada nuevo template:** PR debe incluir contract completo §6, ≥5 ejemplos en verticales, fixtures §13, validaciones §10.

---

**Companions y back-references:**
- `Vision.md` §AI-proposes-never-executes — alineado.
- `Governance.md` §0.5 — esta doctrina extiende la capa Template del modelo híbrido.
- `HierarchyReference.md` §3 capabilities catalog — los `required_capabilities` de cada template referencian este catálogo.
- `ConsistencyAudit_2026-05-17.md` — freeze respetado; renombrado va después.
- `RuleEngineDoctrine.md` — esta doctrina especifica QUÉ se ofrece al usuario; aquélla especifica CÓMO se ejecuta.
- Memorias relacionadas: `[[project-governance-canonical]]`, `[[project-ontology-constitution]]`, `[[project-rules-hierarchy]]`, `[[feedback-no-hardcoded-verticals]]`, `[[feedback-rules-ux-human]]`, `[[feedback-rule-template-explicit-trigger]]`, `[[project-capabilities-vs-rules]]`.
