# Ruul — Projection Doctrine

**Status:** Canónico desde 2026-05-17. Founder directive.
**Companion of:** `Plans/Active/Constitution.md` (Artículo 8 — projections son estado derivado), `Plans/Active/AtomProjection.md` (Atom vs Projection regla mecánica), `Plans/Active/OperationalCacheDoctrine.md` (caches vs projections — distinción), `Plans/Active/ConsistencyAudit_2026-05-17.md` (F20 — right has no real projection).

> Una **projection** es interpretación derivada de atoms. Nunca persiste verdad independiente. Es recomputable, descartable, regenerable. La projection es lectura; el atom es escritura.

> El error doctrinal en Ruul al 2026-05-17: `right_holders_view` se llama view pero lee de `resources.metadata` no de atoms. Es una projection en nombre, no en sustancia. Este doc fija el contrato que toda projection debe declarar para ser canónica.

---

## §1 — Las 8 declaraciones obligatorias

Toda projection canónica declara explícitamente:

### 1. Source atoms

Qué atom tables (o atom-emitting events) alimentan la projection. Lista concreta.

```yaml
source_atoms:
  - public.ledger_entries (type IN ('contribution','expense','...'))
  - public.system_events (event_type LIKE 'fund%')
```

Si la projection lee de `resources.metadata` o de otra projection, debe declararse — y revisarse si esa otra projection es realmente la fuente atómica.

### 2. Reduction logic

Cómo los atoms se reducen al estado proyectado. SQL puro o pseudocode determinístico.

```yaml
reduction: >
  GROUP BY resource_id, currency
  SUM(amount_cents) FILTER (WHERE from_member_id IS NOT NULL) -
  SUM(amount_cents) FILTER (WHERE to_member_id IS NOT NULL)
```

Si la reducción depende de timestamps, `now()`, o random — **no es projection canónica**. Debe ser determinístico dado un set fijo de atoms.

### 3. Recompute strategy

- **lazy** (regular view): se recomputa en cada SELECT. Default.
- **eager** (materialized view): se recomputa en write trigger o cron.
- **incremental** (projection table updated by trigger on atom INSERT): para projections muy caras.

Defaults: regular view (lazy) salvo cost-of-read justifique materialization.

### 4. Invalidation trigger

Cuándo se debe recomputar (para eager / incremental).

- **lazy** → no invalidation needed (siempre fresh).
- **eager** → trigger sobre el atom table; o cron schedule.
- **incremental** → trigger sobre cada INSERT de atom relevante.

### 5. Owner resource

Qué resource type (o subject) es el contexto de la projection. Determina RLS scope.

```yaml
owner: fund   # row visible si caller is member of fund's group
```

### 6. User-facing flag

¿La projection se renderiza directamente en UI?
- **user-facing** → necesita formato consumible, RLS estricta, tests de display.
- **engine-facing** → solo lectura por rule engine; puede ser técnica.
- **audit-facing** → solo admins; expone rule_evaluations / drift / debug.

### 7. Engine-facing flag

¿La projection la lee el rule engine para evaluar conditions?
- **sí** → el engine garantiza determinismo solo si la projection es estable durante la evaluación.
- **no** → safe para mutar entre evaluations.

### 8. Cache-backed flag

¿La projection tiene una fast-path operational cache?
- **no** → siempre re-derivada.
- **sí** → debe estar registrada en `OperationalCacheDoctrine.md` §5 con sus 5 puertas.

---

## §2 — Las 4 reglas de implementación

### Regla 1 — Views, no tables

Default = SQL VIEW (`security_invoker=on`). Solo crear tabla materializada cuando read cost lo justifique.

Razón: tabla mutable = vector de drift. View = always-correct.

### Regla 2 — Rebuild es trivial

`DROP VIEW; CREATE VIEW` siempre regenera correcto. Para projection tables: `TRUNCATE projection_table; INSERT INTO projection_table SELECT ... FROM atoms ...` debe regenerar correcto.

Test concreto: `test_<projection>_recomputes_from_atoms`.

### Regla 3 — Solo lee atoms (o otras projections atom-derived)

Una projection NUNCA escribe a atoms. Nunca llama RPCs que muten. Nunca tiene side effects.

Si la projection necesita "actualizar algo", está mal modelada — eso es rule engine o RPC.

### Regla 4 — No persiste truth independiente

Si la projection tiene un campo que no se puede recomputar desde sus declared source atoms, **no es projection — es cache o truth**.

Si es cache, debe estar registrado en OperationalCacheDoctrine §5. Si es truth, no debe estar en una projection.

---

## §3 — Lo que NO es projection

- Tablas mutables con state (`votes`, `fines`, `rules`, `groups.roles`) — son **workflow** o **configuration**, no projections.
- `user_actions.resolved_at` — es **atom-ish** (terminal flip), no projection.
- `notifications_outbox` — es **outbox queue**, no projection.
- `system_events` con `processed_at` — el atom es atom; `processed_at` es operational cache; la projection sería un futuro `processed_events_view`.

---

## §4 — Registry canónico de projections

Cada entrada cumple las 8 declaraciones. Si una projection se descubre incompleta, queda flagged como **degenerate** en §5.

| Projection | Source atoms | Reduction | Strategy | Invalidation | Owner | User-facing | Engine-facing | Cache-backed | Mig | Spec |
|---|---|---|---|---|---|---|---|---|---|---|
| `fund_balance_view` | `ledger_entries` | sum in - sum out per (fund, currency) | lazy view | — | fund resource | yes | yes | no | 00203 | Fund.md |
| `attendance_view` | `rsvp_actions` + `check_in_actions` | latest-per-(resource,member) | lazy view | — | event resource | yes | yes | no | 00154 | EventResource.md |
| `events_view` | `resources(type=event).metadata` (drop-in for legacy `events`) | column projection | lazy view | — | event resource | yes | no | no | 00156 | EventResource.md |
| `fines_view` | `ledger_entries` (fine_*) + `votes` + `fine_review_periods` | dedupe by (rule_id, target_id, source_event_id) | lazy view | — | group | yes | yes | no | 00149 | Constitution §14 step 3 |
| `vote_counts_view` | `vote_casts` | count latest-per-(vote,member) by choice | lazy view | — | vote workflow | yes | yes | no | 00163 | AtomProjection.md |
| `asset_current_custodian_view` | `custodyAssigned`/`custodyReleased` | latest-per-asset | lazy view | — | asset resource | yes | yes | yes (metadata.custodian_id) | 00212 | Asset.md §9 |
| `asset_valuation_view` | `valuationRecorded` | latest-per-asset | lazy view | — | asset resource | yes | yes | no | 00212 | Asset.md §9 |
| `asset_maintenance_status_view` | `maintenanceLogged`/`maintenanceCompleted`/`damageReported` | open maintenance per asset | lazy view | — | asset resource | yes | yes | no | 00212 | Asset.md §9 |
| `asset_usage_history_view` | `assetCheckedOut`/`assetCheckedIn`/`assetUsed` | feed | lazy view | — | asset resource | yes | no | no | 00212 | Asset.md §9 |
| `space_availability_view` | `bookings` minus `bookingCancelled`/`bookingExpired` | active bookings per space | lazy view | — | space resource | yes | yes | no | 00267 | Space.md |
| `space_capacity_view` | `bookings` + `spaceWaitlistJoined`/`spaceWaitlistPromoted` | active vs cap, derives is_full | lazy view | — | space resource | yes | yes | no | 00267 | Space.md |
| `space_occupancy_view` | `check_in_actions` | latest per (space, member) | lazy view | — | space resource | yes | yes | no | 00267 | Space.md |
| `space_history_view` | various spaceX atoms | feed | lazy view | — | space resource | yes | no | no | 00267 | Space.md |
| `member_balances_per_group` | `ledger_entries` | sum from - sum to per member | lazy view | — | group | yes | yes | no | 00136 | — |
| `member_balances_per_resource` | `ledger_entries` | per (resource, member) | lazy view | — | resource | yes | yes | no | 00136 | — |
| `group_members_with_founder` | `group_members` + `groups.created_by` | join | lazy view | — | group | yes | no | no | (legacy) | — |

---

## §5 — Projections degenerate (deuda doctrinal)

Cada entrada **no cumple** Regla 4 (lee state que no es atom-derived).

| Projection | Problem | Remediation | Audit ref |
|---|---|---|---|
| `right_holders_view` | Lee `resources.metadata.holder_member_id` — NO de atoms. La "transfer chain reconstructible from system_events" mencionada en su comment NO es lo que la view consulta. | R2 — create `right_state_view` que SÍ lee de `system_events`; `right_holders_view` reads from `right_state_view`. | F20 |
| (none planned) | Slot lacks projection entirely; SlotRepository reads direct `resources`. | R4 — create `slot_state_view` atom-derived. | F4 |
| (none planned) | Fund lock state read from `metadata.locked_at`. | R3 — create `fund_lock_view` atom-derived. | F3 |

---

## §6 — Futuras projections planeadas

| Projection | Source atoms | Owner | Why | Status |
|---|---|---|---|---|
| `right_state_view` | `system_events WHERE event_type LIKE 'right%'` | right resource | replace metadata-based holder lookup | planned R2 |
| `slot_state_view` | `slotCreated`/`slotAssigned`/`slotReleased`/`bookingCreated`/`bookingCancelled` for slot | slot resource | recomputable slot status | planned R4 |
| `fund_lock_view` | `fundLocked`/`fundUnlocked` | fund resource | recomputable lock | planned R3 |
| `asset_booking_lock_view` | `assetBookingsLocked`/`assetBookingsUnlocked` (new atoms) | asset resource | replace setBookingsLocked direct write | planned R7 |
| `resource_links_active_view` | `resourceLinked`/`resourceUnlinked` | group | atom-derived active links | planned P2 |
| `attendance_summary_view` | `rsvp_actions` + `check_in_actions` aggregated | event resource | summary tiles | future |
| `right_holder_history_view` | `system_events WHERE event_type LIKE 'right%'` | right resource | full transfer/delegation chain | future (R2 enables) |

---

## §7 — Auditing future projections

Code review checklist:

1. ¿Las 8 declaraciones están escritas en el PR description o spec doc? Si no, rechazar.
2. ¿La projection lee SOLO de source atoms declarados? grep diff — si lee de `resources.metadata.X` y X no está en source atoms, rechazar.
3. ¿Existe test `test_<projection>_recomputes_from_atoms`? Si no, agregar antes del merge.
4. ¿Aparece en §4 registry? Si no, agregar.
5. ¿Si tiene cache field paralelo, está registrado en OperationalCacheDoctrine §5? Si no, agregar o eliminar cache.

**Mantra:** *"Si truncar la tabla X cambia lo que la projection devuelve, X es la verdad — no la projection."*
