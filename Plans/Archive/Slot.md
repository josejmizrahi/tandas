# Ruul — `slot` Resource Type (Canonical Specification)

**Status:** Canónico desde 2026-05-18. Founder directive.
**Companion of:** `Plans/Active/Constitution.md` (Artículo 2 — enum congelado; Artículo 7 — atoms append-only), `Plans/Active/TalmudicGovernance.md` (8 principios cardinales), `Plans/Active/Space.md` §20 (slot = partición atómica dentro de space/asset), `Plans/Active/Asset.md` §12 (asset puede contener bookings polimórfico), `Plans/Active/Fund.md`, `Plans/Active/AtomProjection.md`, `Plans/Active/HierarchyReference.md` §2-3.
**Scope:** Define qué es `resources.resource_type = 'slot'` en Ruul, qué NO es, y cómo se modela. Toda decisión de implementación sobre `slot` consulta primero este documento.

> Ruul **NO** modela calendarios, ni booking apps tradicionales, ni assigned-seating software. Ruul modela coordinación social sobre **particiones atómicas de capacidad** mediante `resources`, `bookings` (atom), `rules`, y `projections`. Un `slot` **NO** es una reserva (ese es el `booking` atom) ni un horario abstracto — es la **unidad atómica reservable** dentro de un space o asset. El turno de 7-8pm en la cancha, el asiento 14 del palco, la mesa 5 del restaurante: cada uno es un slot.

---

## §1 — Definición ontológica

Un `slot` es:

> Una partición atómica de tiempo, asiento, o cupo dentro de un space o asset padre, sobre la cual un grupo coordina asignación, reserva, swap, expiración y consecuencias mediante reglas. El slot es **child** de su parent; la reserva es **acto sobre** el slot.

Un `slot` puede representar:

- turno horario (cancha 19:00-20:00, sala 14:00-15:00)
- asiento numerado (palco lugar 14, mesa 5)
- cupo de evento (uno de N lugares en una cena)
- mesa de restaurante asignable
- escritorio de coworking individual
- estación de equipo (máquina A en gym)
- berth en marina (lugar 7)
- spot de parking
- aula en horario específico
- ranura aérea (aviation slot)
- shift de trabajo voluntario
- turno en lineup deportivo
- lugar en rotativa (host del jueves)

---

## §2 — Principio cardinal

```
slot = partición atómica reservable de un parent persistente
```

**NO:**

```
slot = booking                (booking es el acto de claim)
slot = reservation            (reservation es projection sobre bookings + state)
slot = "una hora libre"       (slot es la unidad, no la disponibilidad)
slot = calendar event         (calendar events son projections sobre slots + bookings)
slot = turn (rotation)        (turn es projection sobre assignments)
```

La diferencia es clave. Un slot es la **unidad atómica del cupo escaso** — existe independientemente de si alguien lo reserva. Los bookings lo **claiman**, los rules lo **gobiernan**, los crons lo **expiran**, los swaps lo **intercambian**. Sin slots, el cupo escaso no tiene shape — solo tendrías un space con capacity y bookings sin granularidad.

---

## §3 — `slot` NO es

| Esto | Pertenece a | Por qué |
|------|-------------|---------|
| Reserva (claim) | `booking` atom en `public.bookings` | Es acto, no unidad |
| Cupo libre / availability | `space_availability_view` projection | Es derivado del slot + bookings |
| Cancelación | `bookingCancelled` atom | Acto, no unidad |
| Horario de un evento | `event.metadata.starts_at/duration` | Event tiene su tiempo intrínseco |
| Turn de rotation (host) | `rotation` capability + projection | Algoritmo, no unidad fija |
| Capacidad total | `space.metadata.capacity` o asset count | Cuenta, no unidad |
| Membership / asiento de grupo | `group_members` (relation) | Pertenencia, no cupo |

---

## §4 — Relación con otras entidades (multi-layer doctrine)

Slot es siempre **child** — nunca standalone. Su parent define la coordinación dominante:

```
SPACE (cancha) ──partitioned_in→ SLOTS (19:00, 20:00, 21:00)
ASSET (palco) ──partitioned_in→ SLOTS (lugar 1, lugar 2, ..., lugar 10)
EVENT (cena) ──seats_in→ SLOTS (uno por miembro confirmado)

Cada SLOT ←claimed_by── BOOKING (atom)
```

### Slot puede gobernar

- a quién se le asigna (assignment capability)
- swap entre miembros
- expiración (capability + cron)
- ventana de booking (cuánto antes/después)
- precedence (founder gets first pick)

### Slot puede usar

- rules (governance específica)
- voting (decisión colectiva sobre asignación)
- swap workflow (vote para aprobar intercambio)
- access (gating de quién puede tocar)
- recurrence (slots auto-generados por pattern)

### Slot puede generar

- atoms (`slotAssigned`, `slotDeclined`, `slotExpired`, `slotSwapRequested`, `slotSwapApproved`, + indirectamente `bookingCreated/Cancelled/Expired`)
- obligations (multa por no-show, no-cancel-on-time)
- projections (próximo turno, asignaciones pendientes)
- consequence cascade (slot expirado → release + waitlist promotion)

### Relaciones universales (vía `resource_links` o `metadata.parent_asset_id`)

```
slot --child_of--> space   (cancha tiene slots 19:00, 20:00, 21:00)
slot --child_of--> asset   (palco tiene slots lugar 1, lugar 2, ...)
slot --reserves--> space   (booking sobre slot ocupa una porción del space)
booking --claims--> slot   (atom polimórfico vía bookings.slot_id)
right --grants_access_to--> slot  (membership permite reservar esta clase de slot)
```

---

## §5 — Ejemplos canónicos

### Caso 1 — Turno de cancha de tenis

**Parent space:** `Cancha 7`

**Resources slot:** uno por window de 1h, generados por capability `recurrence`:
- `Cancha 7 - lunes 19:00-20:00`
- `Cancha 7 - lunes 20:00-21:00`
- ...

**Capabilities en cada slot:** `booking, schedule, expiration, cancellation`

**Rules:**
```
booking < 24h antes del start → require approval del founder
cancel < 4h antes → fine + libera el slot
no check-in within 15min → auto-libera (slotExpired) + waitlist promotion
```

### Caso 2 — Asiento numerado de palco

**Parent asset:** `50% Palco Mundial`

**Slot resources:** `Palco Mundial - Lugar 1` ... `Lugar 10`

**Capabilities:** `assignment, booking, swap, guest_access`

**Rules:**
```
asiento 1 reservado para founder (assignment + access)
swap entre miembros requiere consent del swap target (workflow)
```

### Caso 3 — Cupo en cena rotativa (rotation)

**Parent event:** `Cena Jueves 12-mar`

**Slot resources:** N slots = N miembros confirmados

**Capabilities:** `assignment, swap, rotation`

**Rules:**
```
rotation capability auto-asigna lugar siguiente al next host
swap entre dos miembros requiere aprobación bilateral
```

### Caso 4 — Lugar de parking

**Parent asset:** `Edificio Reforma 222`

**Slot resources:** `Lugar A1` ... `Lugar B12`

**Capabilities:** `assignment, booking`

**Rules:**
```
assignment fija a inquilino contratado (long-lived)
booking diario sobre slots vacantes (visitantes)
```

### Caso 5 — Ranura aérea (aviation slot)

**Parent space:** `Aeropuerto MEX terminal 1`

**Slot:** `MEX T1 - departure 14:30` (15-min window)

Mismo modelo — el slot es la atomic time-band; el booking es la asignación a una airline/flight.

---

## §6 — Slot NO es occurrence en el sentido event

Un `event` tiene `occurrence` (instancia social temporal). Un `slot` **no es occurrence** — el slot es **partición pura** (capacity unit). Si necesitas un evento que ocupa el slot:

- `event scheduled_in slot` (vía resource_links): la cena ocupa el turno 19:00 de la sala.

Slots existen **independientemente de los eventos que los ocupan**. Una cancha tiene los mismos slots cada semana aunque nadie reserve.

---

## §7 — Slot.status — Exception canónica per Constitution §7

### El issue

`resources.status` de un slot tiene tres valores mutables: `'unassigned'` → `'assigned'` → `'booked'`. Estos se flipean directamente cuando `assign_slot` / `book_slot` / `cancel_booking` ejecutan. Esto **pareciera** violar TalmudicGovernance §4.A (Acto > Estado).

### La doctrina (justificación canónica)

`slot.status` ES **display cache derivado de booking atoms**, NO verdad independiente. La verdad es:

- `system_events WHERE resource_id = slot_id AND event_type = 'slotAssigned'` (latest unretired)
- `public.bookings WHERE slot_id = slot_id` (latest unretired)
- `system_events WHERE event_type IN ('bookingCancelled', 'bookingExpired') AND payload->>'booking_id' = ...` (retirement)

La status field es **shortcut de UI** para evitar la query polimórfica en cada slot read.

### Las reglas para que el shortcut sea legítimo (per Constitution §7)

1. **El atom siempre se emite junto** con el status flip — los dos cambios están en la misma transacción RPC. `book_slot` emite `bookingCreated` Y stampa `status='booked'`; `cancel_booking` emite `bookingCancelled` Y reverte `status='unassigned'`.
2. **El atom es la fuente** — la projection canónica (cuando exista) deriva de los atoms, no del status field.
3. **Status nunca se UPDATE-a fuera de RPCs** — RLS prohibe que clients muten el campo directo.
4. **Si la verdad y el cache divergen, la verdad gana** — re-deriving from atoms produce el state correcto.

### Remediación cuando llegue el momento (Phase 3+)

Migración futura: introducir `slot_state_view` (projection) que deriva status puro de atoms. iOS reads from view; status field se mantiene por compat pero se marca como "legacy display cache". Esto cierra completamente la §4.A debt.

**Por ahora:** documentado como Exception §7 legítima, NO violación. Mig 00216 introduce esta doctrina explícitamente (comments línea 167-168). Slot.md la canoniza.

---

## §8 — Booking lifecycle sobre slot

### Forward

```
slot.status = 'unassigned'
  ↓ assign_slot (opcional)
slot.status = 'assigned'  + slotAssigned atom
  ↓ book_slot
slot.status = 'booked'    + bookingCreated atom + bookings row
                          + metadata.booking_id stamped
```

### Cancellation (mig 00266 reversión)

```
slot.status = 'booked'
  ↓ cancel_booking (booker o admin)
slot.status = 'unassigned' + bookingCancelled atom
                          + metadata.booking_id removed
```

### Expiration (mig 00266 cron-driven)

```
slot.status = 'booked', no check_in within window
  ↓ expire_booking (service_role / cron)
slot.status = 'unassigned' + bookingExpired atom
                          + metadata.booking_id removed
```

`bookings` table es **append-only** (mig 00216 atom guard). Cancellation/expiration NUNCA borran el booking row — emiten un atom companion que la projection consume para excluir.

---

## §9 — Atoms relacionados

### Atoms canónicos (mig 00069 + 00070 + 00092 + 00216 + 00266)

```
slotAssigned          — assign_slot RPC. Payload: {assigned_by, member_id}
slotExpired           — emit-slot-system-events cron (5min). Payload:
                        {expired_at, parent_asset_id}
slotSwapRequested     — request_slot_swap RPC. Payload:
                        {target_member_id, vote_id}
```

### Atoms whitelisted PERO sin RPC (orphan — demand-pull)

```
slotDeclined          — whitelisted mig 00092 sin emitter. Reservado para
                        cuando shippe el declination workflow (member dice
                        "no quiero este slot").
slotSwapApproved      — whitelisted sin emitter. Lands cuando shippe el
                        finalize handler del swap vote.
```

### Atoms compartidos polimórficos (booking layer)

```
bookingCreated        — book_slot RPC + book_space RPC. Payload:
                        {booking_id, target_kind (slot|space)}
bookingCancelled      — cancel_booking RPC. Same payload.
bookingExpired        — expire_booking RPC (cron). Same payload.
checkInRecorded       — check_in_to_space + check_in_to_event RPCs.
                        Reuse para slot vía resource_id polimórfico.
```

Todos en `system_events` con `atom_no_mutation_guard`. `public.bookings` con `bookings_atom_guard` (mig 00216).

---

## §10 — Projections

### Estado actual: NONE específicas para slot

A diferencia de space (4 views) y asset (4 views), slot no tiene `slot_*_view`. El UI deriva on-demand:

- "¿este slot está libre?" → query `bookings` + filter por bookingCancelled/Expired atoms
- "¿quién lo tiene asignado?" → read `metadata.assigned_member_id` (cache stamped by assign_slot)
- "¿próximos slots libres?" → query `resources WHERE resource_type='slot' AND status='unassigned'`

### Por qué no hay projection todavía

Phase 2 demand-pull no lo justifica — el read pattern (status + metadata) es suficiente para la UI actual de slot detail. Cuando aterricen:

- multi-slot calendar views (agenda de cancha completa por semana)
- swap matching ("quién está disponible para intercambiar?")
- waitlist promotion lookups

…entonces ship una projection canónica `slot_availability_view` (similar a space_availability_view per slot).

### Futuras (Phase 3+ demand-pull)

```
slot_availability_view       — windows libres/ocupados per parent_asset/space
slot_assignment_view         — quién tiene asignado qué slot, current
slot_swap_pending_view       — swap votes abiertos
slot_calendar_view           — vista agenda multi-slot por window
```

---

## §11 — Slot como centro de governance

Rules pueden aplicar:

- al grupo (default: cualquier miembro puede reservar)
- al `resource_type='slot'` (todos los slots requieren approval)
- al parent space/asset (todos los slots de la cancha 7 solo se reservan domingos)
- a un slot específico (slot fundador-only)

### Precedencia

```
resource > resource_type > parent_resource > group > global
```

El parent_resource hop es propio de slot (slots heredan de asset/space). Asset/space directos no tienen esta capa.

---

## §12 — Capabilities slot

Catálogo aplicable:

| Capability      | Significado                                                | Status     |
|-----------------|------------------------------------------------------------|------------|
| `assignment`    | Designar un miembro como holder del slot                   | incomplete |
| `booking`       | Claim temporal del slot (libre/asignado)                   | stable     |
| `swap`          | Intercambio entre miembros (workflow + vote)               | incomplete |
| `expiration`    | Auto-libera al pasar la fecha (cron)                       | stable     |
| `cancellation`  | Quién puede cancelar y con qué anticipación                | incomplete |
| `schedule`      | Fecha/hora explícitas                                       | stable     |
| `recurrence`    | Auto-generar slots por pattern                              | stable     |
| `attendance`    | Registrar quién ocupó el slot (check-in shared con event)  | stable     |
| `voting`        | Decisión colectiva sobre asignación / swap                 | stable     |
| `rules`         | Governance específica                                       | stable     |
| `consequence`   | Multas por no-show, late cancel                             | incomplete |
| `appeal`        | Apelar slot expirado / multa                                | stable     |
| `capacity`      | Cupo per slot (1 por default, > 1 si shared)               | stable     |
| `guest_access`  | Acompañantes en el slot                                     | incomplete |
| `status`        | Display lifecycle (unassigned/assigned/booked)              | stable     |
| `description`   | Texto libre                                                 | stable     |
| `history`       | Activity feed                                               | stable     |

---

## §13 — Slot lifecycle (resumido)

```
created (status='unassigned')
  ↓ assign_slot (opcional)
status='assigned' + slotAssigned
  ↓ book_slot
status='booked'   + bookingCreated + bookings row + metadata.booking_id
  ↓ cancel_booking | expire_booking
status='unassigned' + bookingCancelled|Expired + metadata.booking_id removed
  ↓ resource.archived_at = now (admin)
status persistente + resourceArchived
```

### Variantes

- **swap workflow**: request_slot_swap → vote → finalize → slot reassigned (atom slotSwapApproved cuando shippe finalize handler).
- **recurrence-generated**: slots aparecen en lotes por pattern (`recurrence` capability config). Lifecycle del slot individual igual.
- **declination**: member dice "no quiero" → slotDeclined atom (pending RPC).

---

## §14 — Bookings polymorphism (slot_id reuse)

`public.bookings.slot_id` es polimórfico: holds either slot OR space resource id (mig 00216 + mig 00266).

- Para slot booking: `metadata = {booked_at}`. Heredamos starts_at/ends_at del slot resource directamente.
- Para space booking: `metadata = {target_kind:'space', starts_at, ends_at, notes, booked_at}` (el space no tiene tiempo intrínseco, vive en booking metadata).

### Por qué el reuse

- mismo append-only atom guard (mig 00216)
- mismas RPCs lifecycle (cancel_booking / expire_booking) trabajan polimórficamente
- mismo `space_availability_view` puede derivar de cualquier target
- evita tabla `bookings_space` paralela (TalmudicGovernance §4.H)

### Futuro rename

El column name `slot_id` es legacy del primer caller. Cuando el blast radius permita, rename a `target_resource_id`. Esto requiere coordinar RLS + edge fns + iOS callers. **No es urgente** — el código actual funciona; el comentario en el schema lo documenta.

---

## §15 — Slot governance — rule templates canónicos

Ejemplos (no exhaustivo):

```
booking < 24h antes del slot start         → require approval del founder
cancel < N horas antes                      → fine
no check_in within X min                    → release (auto-promotion del waitlist)
booking outside allowed_window              → deny (rule consequence denyAction)
swap aprobado                                → emit slotSwapApproved + reassign
miembro X excluido de slot type Y           → relation override + scoped rule
slot recurrente sin reservas en N semanas   → emit warning "slot inactivo"
```

Cada template es `WHEN <atom> → IF <conditions> → THEN <consequences>`. Reutiliza los shapes shipped para space (mig 00268): `cancelledWithinHours`, `outsideAllowedHours`, `bookingDurationAbove`, `releaseBooking`, `denyAction`, `bumpPriority` — todos `valid_resource_types` ya incluyen slot (mig 00268).

---

## §16 — Slot NO es event / asset / space / fund / right

**Event:** occurrence temporal. Slot puede ser cupo de un event (event tiene N slots = N seats).
**Asset:** objeto persistente. Slot es partición de un asset (palco → lugares).
**Space:** lugar persistente. Slot es partición de un space (cancha → turnos).
**Fund:** pool monetario. Slot no es financial — pero un slot puede tener `ledger` capability para fees.
**Right:** entitlement. Slot puede ser `grants_access_to` por un right (membership → derecho a reservar slot class X).

---

## §17 — Arquitectura de datos

Slot vive en:

```
resources.resource_type = 'slot'
metadata.parent_asset_id (UUID, opcional pero típico)
metadata.starts_at / ends_at (para slots temporales)
metadata.seat_number (para slots de asiento numerado)
metadata.assigned_member_id (cache stamped by assign_slot)
metadata.booking_id (cache stamped by book_slot)
status text → 'unassigned' | 'assigned' | 'booked' (cache per §7)
```

**NO crear:** tabla `slots` paralela. **NO crear:** subtype tables (`time_slots`, `seat_slots`). Toda diferencia entre tipos de slot vive en `metadata` (jsonb) + capabilities activadas.

Bookings polimórficos vía `public.bookings.slot_id` (mig 00216).

---

## §18 — UI/UX correcto

Slot renderiza dentro de `UniversalResourceDetailView` (mismo frame universal post-`b01f8fb`), igual que event/asset/fund/space/right.

### Secciones slot-específicas (tentativas; ship cuando demand-pull)

| Sección                  | Capability     | Proyección base                |
|--------------------------|----------------|--------------------------------|
| `SlotAssignmentSection`  | `assignment`   | metadata.assigned_member_id    |
| `SlotBookingSection`     | `booking`      | bookings table per slot        |
| `SlotSwapSection`        | `swap`         | active swap votes              |
| Activity / Rules / Money | shared         | universal sections             |

### Lo que el usuario debe ver

```
Cancha 7 — Lunes 19:00-20:00
[Status: Reservado por Jose]

PRÓXIMA ACCIÓN
Hacer check-in (faltan 15 min)

SWAP
¿Quieres intercambiar? Pide a otro miembro

REGLAS
Cancelar antes de 4h o se cobra multa
No check-in en 15min → libera al siguiente

ACTIVIDAD
Hace 2h: Jose reservó este slot
Hace 4h: Slot generado por horario semanal
```

**NO** debe ver: `status='booked'`, `metadata.booking_id`, `payload`, JSON.

---

## §19 — Slot y atoms

```
slot creado (resources INSERT, status='unassigned')
  ↓
slotAssigned (Maria asignada)
  ↓
bookingCreated (booking_id stamped)
  ↓
checkInRecorded (Jose llegó)
  ↓
bookingCancelled (Maria cancela)
  ↓
slotExpired (cron 5min después)
        ↓
projection (status derivable + history feed)
```

---

## §20 — Filosofía Talmúdica / legal

La ley **no** gobierna "cupos abstractos". Gobierna:

- asignación (a quién corresponde el lugar)
- prioridad (orden de preferencia)
- intercambio (swap regulado)
- expiración (cuándo libera)
- compensación (multa por no-show)
- continuidad (rotación, recurrence)

Ruul modela exactamente eso. El `slot` es el **recipiente de cupo escaso**; los `bookings` son los actos; las `rules` son las consecuencias.

---

## §21 — Decisiones NO negociables

### Sí

- slots como resources polimórficos (no tabla propia)
- bookings como atom append-only polimórfico (slot/space comparten tabla)
- status como display cache derivado de atoms (Exception §7 documentada)
- governance heredada del parent_resource (precedencia §11)
- swap como workflow real (vote + atoms), no auto-magic
- expiration via cron + atom (no `status='expired'` mágico)

### No

- tabla `slots` separada
- mutable status independiente de atoms (sin sync RPC)
- arrays JSON de bookings dentro del slot
- slot sin parent (slot debe ser child de asset/space/event)
- slot inventado per vertical (`tennis_slots`, `parking_spots`)
- soft delete de bookings (atom es eterno)

---

## §22 — Resultado esperado

El sistema debe poder modelar:

- canchas con turnos horarios
- palcos con asientos numerados
- restaurantes con mesas
- parkings con lugares
- coworkings con escritorios
- gyms con estaciones
- marinas con berths
- airports con ranuras
- cenas con lugares
- rotativas con turnos
- shifts de voluntariado

**SIN crear nuevos resource types** y **SIN inventar tablas paralelas**.

---

## §23 — Backend reference (canónico al 2026-05-18)

| Pieza                                | Migración              | Detalle                                                  |
|--------------------------------------|------------------------|----------------------------------------------------------|
| RPCs lifecycle slot (5)              | `00070`                | create_slot / assign_slot / book_slot (refactored 00216) / request_slot_swap |
| Cron `slotExpired` emit              | `00069`                | emit-slot-system-events (5min)                          |
| Atoms whitelisted (5)                | `00069` + `00092`      | slotAssigned / slotDeclined / slotExpired / slotSwapRequested / slotSwapApproved |
| `bookings` atom table                | `00216`                | Polimórfica (slot_id reused as target_resource_id)      |
| `book_slot` refactor → bookings      | `00216`                | Drops resource_type='booking' anti-pattern              |
| `cancel_booking` / `expire_booking`  | `00266`                | Polimórfico — slot revierte status='unassigned'         |
| `build_resource_from_draft` (slot)   | `00218`                | Wizard atomic submit (post Space.md launch)             |
| Slot wizard branch                   | `00218`                | Requires parent_asset_id selection                       |

### iOS surface

- Model: `Slot` (`PlatformModels/Slot.swift`) — typed view sobre ResourceRow metadata
- Repo: `SlotRepository` (read-only) + `SlotLifecycleRepository` (writes: create/assign/book/swap)
- Wizard: `SlotResourceBuilder` requires parent asset selection
- UI: `SlotDetailView` (las únicas detail views type-specific que sobrevivieron — pendiente migrar a UniversalResourceDetailView)
- Tests: `SlotRepositoryTests.swift`

---

## §24 — Definición final

### Slot

> Resource child de un asset, space o event que representa una partición atómica reservable (turno, asiento, cupo), con status como display cache derivado de booking atoms append-only — NO verdad independiente. Distinto de `booking` (acto), distinto de `reservation` (projection), distinto de `event` (occurrence completa), distinto de `asset` / `space` (parent persistentes).

Ese es el modelo canónico de `slot` en Ruul.

---

## §25 — Definition of Done

Slot.md está canónico cuando:

- [x] Definición ontológica + cardinal principle + qué NO es
- [x] Multi-layer doctrine (slot como child de asset/space/event)
- [x] 5+ ejemplos canónicos (cancha, palco, cena, parking, aviation)
- [x] Atoms documentados (3 emitidos + 2 orphan + 3-4 shared booking)
- [x] Status mutability — Exception §7 documentada explícitamente con 4 reglas
- [x] Booking lifecycle (forward + cancellation + expiration) documentada
- [x] Bookings polymorphism (slot_id reuse) documentado con justificación + rename plan
- [x] Capabilities listadas con status
- [x] Rule templates listados (reusando los de SpaceRules)
- [x] Backend reference table
- [x] TalmudicGovernance §4 audit: 7/8 pass + 1 documented exception (status cache per §7)
- [x] Definición final one-sentence
- [ ] **Phase 3 follow-up**: ship `slot_availability_view` projection cuando lleguen multi-slot calendar views
- [ ] **Phase 2 follow-up**: ship `decline_slot` RPC (atom whitelisted, RPC missing)
- [ ] **Phase 2 follow-up**: ship `slotSwapApproved` finalize handler

---

## §26 — Known Issues (canonical doctrine debt)

### #1 — Orphan atoms whitelisted sin RPC

**Síntoma:** `slotDeclined` y `slotSwapApproved` están en `is_known_system_event_type` whitelist (mig 00092) pero ningún RPC los emite. Insertarlos manualmente pasaría el guard pero nada en producción los crea.

**Doctrina afectada:** TalmudicGovernance §4.H (no duplicar / reutilizar conceptos) está OK — los atoms son válidos, solo faltan implementarse. Pero §3 (filtro ontológico) sugiere que código muerto debe documentarse o removerse.

**Remediación:** documentar como pending demand-pull (este §26) o remover del whitelist hasta que sus RPCs aterricen. Decisión deferred a Phase 2 cleanup.

### #2 — No projection canónica

**Síntoma:** A diferencia de asset (4 views), space (4 views), fund (1 view), slot no tiene `slot_*_view`. Multi-slot calendar UI requiere on-demand polymorphic query.

**Remediación:** Ship `slot_availability_view` cuando la UI lo pida. Por ahora el read pattern actual es funcional.

### #3 — SlotDetailView type-specific superviviente

**Síntoma:** Post-`b01f8fb` refactor (universal detail frame), todos los resource types renderizan en `UniversalResourceDetailView` excepto slot, que aún tiene `SlotDetailView`. Inconsistencia con doctrine §22.

**Remediación:** Migrate slot a UniversalResourceDetailView con inline sections (SlotAssignmentSection, SlotBookingSection, etc.). Phase 2 polish slice.
