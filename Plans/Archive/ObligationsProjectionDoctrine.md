# Ruul — Obligations Projection Doctrine

**Status:** Canónico desde 2026-05-18. Founder directive.
**Companion of:** `Plans/Active/RulesVsMoneyDoctrine.md` (3 axiomas que separan rule/fine/ledger), `Plans/Active/ProjectionDoctrine.md` (8 declaraciones obligatorias por projection), `Plans/Active/AtomProjection.md` (atom = truth, projection = interpretation), `Plans/Active/OperationalCacheDoctrine.md` (Prohibición 2 — money state nunca es cache), `Plans/Active/ConsequenceArchitecture.md` (consequence families que emiten los atoms que alimentan estas projections).

> Una **obligation** es la representación derivada del estado "alguien le debe algo a alguien (o al grupo)". Existe como cuenta abierta sin cierre. **No persiste.** Recomputable desde atoms (`ledger_entries`, `damageReported`, `bumpPriority`, etc.). Sirve para responder UI questions ("¿qué le falta a este miembro?") y rule conditions ("¿tiene obligations abiertas?").

> El error doctrinal a evitar: persistir una tabla `obligations` mutable con state machine propia. Eso convierte la obligation en truth paralela, opaca la auditabilidad atómica y abre la puerta a drift cache-vs-atom.

---

## §1 — Las 4 familias canónicas de obligation

Toda obligation derivable cae en una de las 4 familias. Cada familia es proyección sobre **atom set + offset atom set** (resta de "abrió" menos "cerró").

### Familia 1 — Economic obligation

**¿Qué pasa?** El miembro debe dinero al grupo o a otro miembro.

**Source atoms:**
```yaml
opens:
  - public.ledger_entries (type='fine_issued',   from_member_id=X)
  - public.ledger_entries (type='contribution_required', from_member_id=X) # futuro
  - public.ledger_entries (type='expense', from_member_id=null, to_member_id=X) # X owes
closes:
  - public.ledger_entries (type='fine_paid',    metadata.fine_id matches)
  - public.ledger_entries (type='fine_voided',  metadata.fine_id matches)
  - public.ledger_entries (type='refund',       metadata.cancels=<original>)
  - public.ledger_entries (type='settlement',   metadata.cancels=<original>)
```

**Reduction:** `sum(opens) - sum(closes) per (member, currency)`. Si > 0 → obligation abierta.

**Proyectada por:**

- `outstanding_fines_view` (futura — solo fines abiertas por miembro)
- `member_balances_per_group` (mig 00136 — neto por miembro)
- `member_balances_per_resource` (mig 00136 — neto por miembro × resource)
- `member_obligations_view` (futura — consolidado economic + non-economic)

### Familia 2 — Coordination obligation

**¿Qué pasa?** El miembro tiene un compromiso pendiente que afecta la coordinación del grupo (turno, custody, check-in pendiente).

**Source atoms:**
```yaml
opens:
  - public.system_events (event_type='rotationAssigned',  metadata.member_id=X)
  - public.system_events (event_type='custodyAssigned',   metadata.member_id=X)
  - public.bookings      (member_id=X, status implicit)
closes:
  - public.system_events (event_type='rotationCompleted')
  - public.system_events (event_type='custodyReleased')
  - public.bookings cancellation atoms / check-in atoms
```

**Reduction:** open atom sin matching close → coordination obligation abierta.

**Proyectada por:**

- `active_custody_view` (futura — quién tiene qué asset hoy)
- `pending_rotation_view` (futura — a quién le toca el próximo turno)
- `active_bookings_view` (futura — bookings sin cierre)

### Familia 3 — Damage / Liability obligation

**¿Qué pasa?** Hubo daño reportado y el miembro responsable no ha resuelto.

**Source atoms:**
```yaml
opens:
  - public.system_events (event_type='damageReported',  metadata.responsible_member_id=X)
closes:
  - public.system_events (event_type='damageResolved',  metadata.damage_id=Y)
  - public.system_events (event_type='damageWaived',    metadata.damage_id=Y)
```

**Reduction:** open `damageReported` sin matching close → liability abierta.

**Proyectada por:**

- `open_damages_view` (futura)
- Se cruzaría con economic vía la rule `damage_liability` cuando exista (Wave 2 templates).

### Familia 4 — Priority / Access deficit

**¿Qué pasa?** El miembro perdió prioridad o acceso por consequence previo (bump-priority negativo, suspend_right activo).

**Source atoms:**
```yaml
opens:
  - public.system_events (event_type='priorityBumped',  metadata.priority_delta<0)
  - public.system_events (event_type='rightSuspended')
  - public.system_events (event_type='waitlistJoined')
closes:
  - public.system_events (event_type='priorityRestored')
  - public.system_events (event_type='rightReinstated')
  - public.system_events (event_type='waitlistPromoted')
```

**Reduction:** deficit acumulado sin restoración → access obligation.

**Proyectada por:**

- `priority_deficit_view` (futura)
- `right_state_view` (planned R2 — `OperationalCacheDoctrine.md` §6)

---

## §2 — Las 6 propiedades obligatorias de toda obligation projection

Sobre las 8 declaraciones de `ProjectionDoctrine.md` §1, una projection de obligation declara 6 propiedades adicionales:

### 1. `subject_member_id` (UUID)

Sobre quién pesa la obligation. Cada row apunta a un miembro singular. (Si la obligation es grupal, se materializa una row por miembro.)

### 2. `creditor` (`group | member_id | resource_id`)

A quién le debe. Tres clases:

- `group` — debe al pot común (multas, contributions).
- `member_id` — debe a un peer (IOU pendiente).
- `resource_id` — debe a un fund/asset/space específico.

### 3. `obligation_kind` (enum)

Una de: `monetary | coordination | liability | access`. Mirror exact de §1 families.

### 4. `opened_at` (timestamptz)

Timestamp del atom que abrió la obligation. Sirve para SLA, prescripción y orden cronológico.

### 5. `expected_resolution_by` (timestamptz, nullable)

Cuándo "se vuelve incumplida". Para una multa: now() + grace_period. Para una rotation: turn_end_date. Para custody: return_due_date. Si NULL → no hay deadline.

### 6. `source_atom_id` (UUID)

Pointer al atom que abrió la obligation. Cierra el ciclo atom → projection → UI → atom. Facilita drilling y debugging.

---

## §3 — Las 5 prohibiciones

### Prohibición 1 — No persistir obligation como tabla mutable

**NUNCA** crear `public.obligations` table con state machine `open / paid / resolved / waived` mutable. Esto convierte la obligation en truth paralela.

Si futuro release necesita "obligation con SLA tracking", la SLA vive en projection (`expected_resolution_by - now()`). El "resolved" estado se infiere del atom de cierre. NO se persiste.

### Prohibición 2 — No bypass de ledger_entries para economic obligations

Toda economic obligation reduce a contar atoms `ledger_entries`. Si una RPC nueva quiere "abrir una obligation sin ledger entry" (por ejemplo "pre-fine" o "pending charge"), se rechaza: si no hay movimiento monetario aún, no hay obligation — hay rule pending con scheduled consequence.

Pre-fines no existen. Existen rules que aún no han evaluado, o consequences emitidas que aún no se han pagado (fine_issued sin fine_paid).

### Prohibición 3 — No mezclar familias en una misma projection

Cada family vive en su propia view base. Si el UI quiere mostrar "todo lo que José tiene pendiente", existe `member_obligations_view` que es **UNION ALL** de las 4 family views. NUNCA se construye una single view monolítica.

Razón: cuando una family cambia su shape de atoms (Wave 2 introduce custody con sub-states), aislamos el blast radius a esa view sin tocar las demás.

### Prohibición 4 — No leer obligations desde rule engine si la rule las emite

Anti-feedback-loop. Una rule cuya consequence es `issueFine` no debe leer en su condition `outstanding_fines_view` calculado pre-emisión — el engine garantiza determinismo solo si la projection es estable durante la evaluación (`RuleEngineDoctrine.md` §1 Regla 7).

Si necesitas "no emitir fine si ya hay 3 outstanding", la condition lee `count(ledger_entries WHERE type='fine_issued' AND from_member_id=actor AND not paid)` directo de atom, NO de la projection que se actualizaría con la nueva fine en flight.

### Prohibición 5 — No exponer obligation drift como UI feature

Si la projection retorna 0 obligations pero el usuario "siente" que debería tener una, el flujo es:

1. Drilling: clic en "Pagar" mostraría 0 fines, eso confirma drift.
2. Investigation: ¿atoms existen? ¿projection los lee?
3. Fix: corregir reduction logic en la view.

NUNCA: agregar "manual obligation override" en UI o RPC. La projection no se ajusta — se debugea hasta que es correcta.

---

## §4 — Registry de obligation projections (target post-refactor)

Cada entrada cumple `ProjectionDoctrine.md` §1 + las 6 propiedades §2 de este doc.

| Projection | Family | Status | Source atoms (close) | Mig | UI surface |
|---|---|---|---|---|---|
| `fines_view` | economic | **shipped (mig 00149)** | `ledger_entries(fine_paid/fine_voided)` | 00149 | `MyFinesView`, Fine detail |
| `member_balances_per_group` | economic | **shipped (mig 00136)** | `ledger_entries` net per member | 00136 | Group settle screen |
| `member_balances_per_resource` | economic | **shipped (mig 00136)** | `ledger_entries` net per (member, resource) | 00136 | Resource Money tab |
| `outstanding_fines_view` | economic | **planned** | sum(fine_issued) - sum(fine_paid) - sum(fine_voided) per member | TBD | Resource Obligations tab, Inbox |
| `member_obligations_view` | union | **planned** | UNION ALL of 4 family views | TBD | Resource Obligations tab, Member profile |
| `pending_rotation_view` | coordination | **future** | `rotationAssigned` - `rotationCompleted` | TBD | Rotation screens |
| `active_custody_view` | coordination | **future** (parte hoy en `asset_current_custodian_view`) | `custodyAssigned` - `custodyReleased` | 00212 | Asset detail |
| `active_bookings_view` | coordination | **future** | open `bookings` rows | TBD | Space detail |
| `open_damages_view` | liability | **future** (Wave 2 templates) | `damageReported` - `damageResolved` | TBD | Asset detail, Inbox |
| `priority_deficit_view` | access | **future** | `priorityBumped(delta<0)` sin restore | TBD | Member profile |
| `right_state_view` | access | **planned R2** | `system_events` LIKE `right%` | TBD | Right detail |

---

## §5 — Recompute strategy y performance

Reglas operacionales:

1. **Default = lazy view (regular SQL VIEW).** Recompute en cada SELECT. No invalidation.
2. **Si query plan muestra >100ms con datos production-realistic**, considerar:
   - Index en atom table sobre los campos de filter (ej. `ledger_entries.from_member_id`, `system_events.event_type`).
   - Materialized view + cron refresh (eager strategy, declarado en `ProjectionDoctrine.md` §1.3).
3. **NUNCA** mover a "projection table updated by trigger" sin agregar entrada en `OperationalCacheDoctrine.md` §5 con las 5 puertas cumplidas. Esa ruta es cache, no projection.
4. **Indexes recomendados ya creados:**
   - `ledger_entries_fine_id_atoms_idx` (mig 00149) — para `fines_view` y `outstanding_fines_view`.
   - `ledger_entries_member_id_*` indexes — verificar si existen para `member_balances_*`; agregar si no.

---

## §6 — UI doctrine — surfaces para obligation projections

### §6.1 — Resource Detail tab "Money" (nueva — sección dentro de overview hoy)

Hoy: el módulo Money vive como sheet (`EventLedgerSheet`, `AddLedgerEntrySheet`) gatillado desde `overview`. Doctrina:

- Promover a tab dedicado `.money` en `ResourceDetailTab` (`ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/ResourceDetailTab.swift`).
- Contenido del tab:
  - **Saldo** del usuario actual en este resource (lee `member_balances_per_resource`).
  - **Movimientos recientes** (lee `ledger_entries` polymorphic por resource_id, recent N).
  - **Fines del resource** — agrupadas por estado (proposed / officialized / paid / voided), lee `fines_view`.
  - **Pago / Aportación** CTA — gatilla `AddLedgerEntrySheet`.

### §6.2 — Resource Detail tab "Obligations" (futura)

Una vez `member_obligations_view` exista:

- Tab `.obligations` muestra todas las obligations abiertas del **caller** (`auth.uid()`) sobre este resource.
- Group by `obligation_kind` (Pendientes financieros / Pendientes de coordinación / Daños sin resolver / Restricciones activas).
- Para admins: toggle "Ver obligations de todos" → lista por miembro.

### §6.3 — Inbox

`Inbox` ya consume `user_actions` (Atom-ish, mig 00166). Las obligation projections **no reemplazan** Inbox — son complementarias:

- Inbox = "lo que requiere mi acción **ahora**" (atom-driven).
- Obligations = "estado abierto que pesa sobre mí" (projection).

Una multa pending: aparece como `user_action(action_type='fineProposed')` en Inbox + `outstanding_fines_view` row en Obligations. Cuando se paga: `user_action.resolved_at = now()`, obligation row desaparece.

### §6.4 — Member profile

Sección "Obligations con el grupo": lee `member_obligations_view WHERE subject_member_id = profile.member_id`. Solo visible a admin (RLS) o al miembro mismo.

---

## §7 — Tests obligatorios (CI gates)

Para cada projection nueva:

| Test | Cubre |
|---|---|
| `test_<projection>_recomputes_from_atoms` | Regla 2 de `ProjectionDoctrine.md` — drop + rebuild produce mismo set. |
| `test_<projection>_returns_zero_when_no_atoms` | Edge — no opens → no obligations. |
| `test_<projection>_offset_closes_open` | Sanity — issue + pay → 0 outstanding. |
| `test_<projection>_only_reads_declared_atom_tables` | Grep view definition contra declared source_atoms list. |
| `test_<projection>_idempotent_under_atom_replay` | Re-aplicar mismo atom no inflates obligation. |
| `test_<projection>_subject_member_id_present` | §2.1 — toda row tiene subject. |

Para `member_obligations_view` (cuando exista):

- `test_member_obligations_view_unions_4_families_no_dedup_within_family`
- `test_member_obligations_view_filters_by_subject_member_id`

---

## §8 — Doctrina final

> **An obligation is what the atoms say is still open.**
> **It has no independent identity, no state machine, no persistence.**
>
> **When the atoms say "closed", the obligation disappears.**
> **When the atoms say "open", it shows up.**
>
> **If you can't recompute it from atoms, it's not an obligation — it's a leak.**

Cuando hay duda:

- ¿Existe un atom que abre esto? ¿Existe un atom que lo cierra? Si sí ambos → es obligation projection.
- ¿La RPC nueva quiere persistir un campo `is_resolved`? Detén — el atom de cierre lo deriva.
- ¿La UI quiere mostrar "hace 5 días pendiente"? `now() - opened_at`, ya tienes los datos.
