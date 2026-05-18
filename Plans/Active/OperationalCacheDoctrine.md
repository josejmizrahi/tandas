# Ruul — Operational Cache Doctrine

**Status:** Canónico desde 2026-05-17. Founder directive.
**Companion of:** `Plans/Active/Constitution.md` (Artículo 8 — projection ≠ truth), `Plans/Active/AtomProjection.md` (Atom vs Projection vs Configuration), `Plans/Active/ConsistencyAudit_2026-05-17.md` (findings F2, F3, F4, F7, F8, F9, F22 todos relacionados con mutable cache disfrazada de truth), `Plans/Active/ProjectionDoctrine.md`.

> Un **operational cache** es un campo mutable en una tabla atom-like o resource-like que existe SOLO porque la lectura de la projection sería muy lenta para mostrar en pantalla. **No es truth. Es speed.**

> El error doctrinal recurrente en Ruul al 2026-05-17 ha sido: campos puestos como "cache" en `resources.metadata` que de hecho **son la verdad operativa** sin atom recomputable detrás. Este doc fija las condiciones bajo las cuales un cache mutable es aceptable, prohibido, y cómo se documenta.

---

## §1 — Las 5 condiciones (las 5 puertas)

Un campo mutable es **operational cache aceptable** SI Y SOLO SI cumple las 5:

### Puerta 1 — Atom-backed

**Cada cambio del cache emite un atom canónico ANTES de mutar el cache.**

- Si la RPC hace `INSERT INTO system_events (...) ... UPDATE resources SET metadata = ...`, OK.
- Si la RPC hace `UPDATE resources SET metadata = ... INSERT INTO system_events (...)`, **violación** — atom es decoración (caso fund_lock, transfer_right).
- Si la RPC muta sin atom alguno, **violación grave** (caso archive_resource).

### Puerta 2 — RLS-protected

**RLS revoca `UPDATE`/`DELETE` directo a `authenticated`.** Solo SECURITY DEFINER RPCs pueden escribir.

- Si cualquier usuario autenticado puede `update resources set metadata = ...`, el cache es no-trustable.
- Si solo `service_role` y RPCs whitelisted pueden mutar, OK.

### Puerta 3 — Recomputable

**La verdad sobrevive al borrado del cache.** Si dropeas el cache field y haces rebuild desde atoms, obtienes el mismo valor (o el valor correcto post-último-atom).

- Test concreto: `truncate resources.metadata.X; rebuild from atoms; assert equality`.
- Si el rebuild falla porque faltan atoms, **violación** (caso slot.status — no hay `slotCreated` ni `slotReleased`).

### Puerta 4 — Doctrinally declared

**El campo está documentado explícitamente como cache en una de:**
- Spec del resource (`Fund.md` §X)
- Comment del SQL migration (`-- cache: derived from atoms`)
- Esta doctrine doc en §5 (registry oficial)

Sin la declaración, el siguiente sesión humana o IA va a tratarlo como truth y construir features que lo asumen.

### Puerta 5 — Test-enforced

**Existe un test que verifica consistency cache vs atoms.** Mínimo:

```
test_<field>_cache_recomputes_from_atoms():
  drop the cache value
  call rebuild_from_atoms_<field>()
  assert recomputed_value == previous_cache_value
```

Sin el test, drift silencioso es inevitable.

---

## §2 — Las 3 condiciones de prohibición

Un campo mutable es **operational cache PROHIBIDO** si cumple cualquiera de las 3:

### Prohibición 1 — Es la única fuente

Si el dato NO se puede recomputar desde atoms, **NO es cache — es truth disfrazada**.

Ejemplo (violación actual F2): `resources.metadata.holder_member_id` para right. Si truncas `system_events`, el holder se pierde irrecuperable. Si truncas `resources.metadata.holder_member_id`, los `rightTransferred` atoms permiten rebuild. Pero la RPC actual hace lo opuesto — escribe metadata primero, atom después. Si fallara entre los dos pasos, atom queda incompleto y metadata es la única verdad → prohibido.

### Prohibición 2 — Es financiero

Money state nunca es cache. **Toda mutación financiera vive en `ledger_entries` y se proyecta a vistas.** Punto.

Ejemplo (violación histórica): `groups.fund_balance` mutado por `pay_fine` (dropeada en mig 00078 pero la función live aún la referencia — F1). Heresy.

### Prohibición 3 — Está protegida por governance

Lock state, suspension state, approval state, expiration state — todo lo que la rule engine necesita evaluar — debe ser projection derivada de atoms. Si fuera mutable cache, un override administrativo no-atom-backed bypaseraría la rule engine.

Ejemplo (violación F3): `fund_lock_at` en `resources.metadata`. Una rule "no contribuir si fund locked" lee mutable metadata; admin puede unlock sin atom; rule re-acepta contribuciones sin trail.

---

## §3 — Cómo nombrar

Para tablas nuevas o campos nuevos:

- **Atom**: nombre directo, sin prefijo (`ledger_entries`, `rsvp_actions`, `bookings`).
- **Projection**: sufijo `_view` (`fund_balance_view`, `attendance_view`).
- **Cache field** en tabla mutable: prefijo `cached_` o nota en comment SQL (`metadata.cached_holder_member_id`, `-- cache: derived from system_events`).

Tablas existentes que rompen la convención **no se renombran** — la doctrina es forward-only. Pero los campos nuevos deben respetarla.

---

## §4 — Recovery path

Si un cache field diverge de atoms, la **doctrina pone la verdad en atoms**:

1. Detectar drift: corre el `_cache_consistency_test`.
2. Si diverge, dispara `rebuild_from_atoms_<field>()`.
3. Logea el drift como audit event (`cacheDriftDetected` atom).
4. Investigar root cause — usualmente una RPC que muta cache sin emitir atom.

**Nunca:** "ajustar atoms para que matchee cache". Atoms son verdad, no se editan.

---

## §5 — Registry de caches aceptados (canónico)

Cada entrada cumple las 5 puertas. Si una violación se descubre, mover a §6.

| Field | Source atoms | Recompute path | Guard | Mig | Doc |
|---|---|---|---|---|---|
| `system_events.processed_at` | (self — terminal flip) | one-way null→ts | `system_events_processed_at_only_guard` (mig 00162) | 00162 | AtomProjection.md "Trigger anti-mutation" |
| `user_actions.resolved_at` | (self — terminal flip) | one-way null→ts | `user_actions_resolution_guard` (mig 00166) | 00166 | AtomProjection.md "Atom-ish" |
| `resources.metadata.custodian_id` (asset) | `custodyAssigned`/`custodyReleased` | `asset_current_custodian_view` rebuild | RPC-only (assign_custody/release_custody) | 00210 | Asset.md §7 (explicit "cache de UI") |
| `resources.status` (slot) | `slotCreated`/`slotAssigned`/`bookingCreated`(slot)/`slotReleased`/`slotExpired`/`slotDeclined` | `slot_state_view` derives canonical status | RPC-only (create_slot/assign_slot/book_slot/cancel_booking/expire_booking) | 00281-00283 | Slot.md; smoke test mig 00282 verifies recompute parity |
| `bookings.slot_id` (polymorphic target) | `bookingCreated` | row is the atom itself | `bookings_atom_guard` (mig 00216) | 00216 | Slot.md, Space.md |
| `events_view.attendees_count` | `rsvp_actions` + `check_in_actions` | view rebuild | view derived | 00156 | AtomProjection.md |
| `groups.member_count` | `group_members` insert/update | view-style derived | — | (legacy) | Use group_members directly |

---

## §6 — Registry de caches en violación (deuda doctrinal)

Cada entrada **no cumple** una o más puertas. Plan de remediation en `ConsistencyAudit_2026-05-17.md`.

| Field | Violation | Remediation | Audit ref |
|---|---|---|---|
| `resources.metadata.holder_member_id` (right) | Puertas 1, 3 — atom es decoración; recompute existe pero `right_holders_view` no lo usa | R2 — create `right_state_view` atom-derived; drop metadata mutation | F2, F20 |
| `resources.metadata.delegate_member_id` (right) | Same as above | R2 | F2 |
| `resources.metadata.locked_at`/`locked_by`/`locked_reason` (fund) | Puerta 1 — atom decoración | R3 — create `fund_lock_view` atom-derived | F3 |
| ~~`resources.status` (slot)~~ — **MOVED to accepted §5 post Sprint 3** | All 5 puertas now satisfied: atoms added (mig 00281), slot_state_view (00282), constraint fixed (00283), declared in §5, smoke-tested | CLOSED Sprint 3 | F4 (closed), F22 (closed) |
| `resources.metadata.owner_id` (asset) | Puerta 1 — atom decoración | R/P4 — derive from `assetTransferred` projection | F9 |
| `resources.archived_at` (any) | Puerta 1 — no atom emitted | R6 — emit `resourceArchived` / `resourceUnarchived` atoms | F7 |
| `resources.metadata.bookings_locked` (asset) | Puerta 1 + edge function direct write | R7 — `lock_asset_bookings` RPC with atom; consequence sink uses RPC | F8 |
| `groups.fund_balance` (referenced by `pay_fine`) | **HERESY** — column dropped but code refs it | R1 — rewrite `pay_fine` using `ledger_entries` only | F1 |

---

## §7 — Auditing future caches

Cualquier nueva propuesta de cache mutable pasa este filtro en code review:

1. ¿Cumple las 5 puertas de §1? Si no, rechazar.
2. ¿Cae en alguna prohibición de §2? Si sí, rechazar.
3. ¿Está agregada al §5 registry? Si no, agregar antes del merge.
4. ¿Tiene test que verifica recompute? Si no, agregar antes del merge.

**Mantra:** *"Si dudas si es cache o truth, asume truth — y entonces no puede ser mutable."*
