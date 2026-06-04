# R.2T — Reservation ≠ Event (Doctrina)

**Founder lock 2026-06-03.** Formaliza que `Reservation` y `Event` son primitivas
distintas y NUNCA deben colapsarse en una sola tabla, vista, ni modelo iOS.

Aplica a: backend (`resource_reservations`, `calendar_events`, `event_participants`),
iOS (`Reservation*`, `CalendarEvent*`, `EventParticipant`), RPCs y UI.

---

## Definiciones

### Event

Responde:

- ¿Qué ocurre?
- ¿Cuándo ocurre?
- ¿Quién participa?

Ejemplos: México vs Brasil · Comida Miércoles · Viaje Japón · Asamblea Familiar ·
Junta de Consejo.

**Un evento existe aunque nadie reserve nada.**

### Reservation

Responde:

- ¿Quién obtiene acceso a un recurso durante un periodo?

Ejemplos: José reserva Casa Valle · Isaac reserva el coche · Abuelo usa el palco ·
Pepe obtiene 2 asientos.

**Una reservación existe aunque no haya evento.**

### Regla universal

| Primitiva | Pregunta |
|---|---|
| Event | Algo ocurre. |
| Reservation | Alguien obtiene acceso. |

Son conceptos distintos. No se infiere uno del otro.

---

## Casos canónicos

### Casa Valle (Reservation sin Event)

```
Resource:      Casa Valle
Reservation:   José (10-12 julio)
Event:         NINGUNO
```

Válido.

### Mundial (Event con Reservations asociadas)

```
Event:         México vs Brasil
Resource:      Palco Azteca
Reservations:  José 1 asiento
               Papá 2 asientos
               Abuelo 2 asientos
               Pepe 2 asientos
```

Válido. Cada reservación referencia el evento via `source_event_id`.

### Viaje (Event + Resource con Reservation)

```
Event:         Viaje Japón
Resource:      Hotel
Reservation:   Habitación 301
```

Válido.

---

## Modelo canónico

```
Resource
   ↓
Reservation         (opcional → source_event_id)
   ↓
Conflict            (opcional, por overlap)
   ↓
Decision            (opcional, resuelve conflicto)
```

Separadamente:

```
Event
   ↓
Participants
```

`Reservation.source_event_id` es el ÚNICO puente — nullable, no obligatorio en
ninguna dirección.

---

## Relación permitida (única)

`resource_reservations.source_event_id uuid NULL REFERENCES calendar_events(id)`

- Reservation puede referenciar Event.
- Event NUNCA contiene reservaciones.
- Reservation NO requiere Event.
- Event NO requiere Reservation.

---

## Available Actions (distintos)

| Primitiva | Acciones canónicas |
|---|---|
| Reservation | `approve` · `reject` · `confirm` · `cancel` · `resolve_conflict` |
| Event | `rsvp` · `check_in` · `cancel_participation` · `record_expense` |

**No se comparten.** Si una acción aplica a ambas, modelarla en cada primitiva
por separado — no inventar un canal compartido.

---

## Resource Detail (UI)

`ResourceDetailView` debe mostrar:

- Reservaciones del recurso
- Conflictos abiertos
- Calendario de uso

**NO debe mostrar:**

- Participantes de eventos (pertenecen al Event, no al Resource)

---

## Event Detail (UI)

`EventDetailView` debe mostrar:

- Participantes
- Fecha / lugar
- Reservaciones asociadas (sólo si existen, vía `source_event_id`)

**NO debe asumir** que las reservaciones SON los participantes.

---

## Smokes (blindaje contra regresión)

| Smoke | Asserts |
|---|---|
| `_smoke_r2t_event_without_reservation()` | Crear evento sin reservaciones. 0 filas en `resource_reservations` con `source_event_id = event_id`. |
| `_smoke_r2t_reservation_without_event()` | Crear reservación sobre recurso reservable. `source_event_id IS NULL`. |
| `_smoke_r2t_event_with_reservations()` | Mundial: 1 evento + 4 reservaciones con `source_event_id` cargado. |
| `_smoke_r2t_reservation_conflict_world_cup()` | 4 reservations overlapping en mismo recurso → `detect_reservation_conflicts` produce ≥1 conflict. |
| `_smoke_r2t_decision_resolves_conflict()` | `create_decision` (single_choice) → `vote_decision` → `execute_decision` → conflicto resuelto. |

---

## Definition of Done

1. Reservation y Event permanecen separados (tablas, modelos iOS, vistas).
2. Reservation puede referenciar Event opcionalmente via `source_event_id`.
3. Event no contiene Reservation.
4. Reservation no contiene Event obligatorio.
5. Casa Valle funciona (reservación sin evento).
6. Mundial funciona (evento con reservaciones).
7. Viaje funciona (evento + recurso + reservación).
8. Available Actions distintos entre primitivas.
9. Los 5 smokes R.2T PASS.

---

## Fuera de scope (deliberadamente)

Lo siguiente NO es parte de R.2T-FIX. Queda diferido a slices futuros:

### R.2T-CAPACITY — Reservable Capacity / Seat Allocation

Modela:

- `resources.capacity_total`
- `allocation_by_owner` / `allocation_by_context`
- `requested_units` / `requested_seats`
- `approved_units` / `approved_seats`
- Conflictos por **cupos** (no por overlap)
- Overbooking semántico

Cuando se necesite validar "7 lugares solicitados vs 5 disponibles" como
semántica de cupos (no como overlap de tiempo), se abre R.2T-CAPACITY.

Mientras tanto, el smoke del Mundial valida sólo:

- el evento existe
- las reservaciones con `source_event_id` existen
- el overlap conflict se detecta
- una decision puede resolverlo

NO valida cupos ni asignación parcial.

---

## Anti-patrones (bannados)

1. **`event_reservations`** como tabla aparte. No.
2. **Inferir** que el participante de un evento "automáticamente" reserva el recurso. No.
3. **Compartir** `available_actions` entre primitivas. No.
4. **Mostrar** participantes del evento en `ResourceDetailView`. No.
5. **Mostrar** la lista de reservaciones como "los participantes" en `EventDetailView`. No.
6. **Renombrar** `source_event_id` a `event_id` (sugiere relación obligatoria). No — el prefijo `source_` documenta opcionalidad.
