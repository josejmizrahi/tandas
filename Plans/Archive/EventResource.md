# Ruul — `event` Resource Type (Canonical Specification)

**Status:** Canónico desde 2026-05-15. Founder directive.
**Companion of:** `Plans/Active/Constitution.md`, `Plans/Active/HierarchyReference.md` §2 (resource types) y §3 (capabilities), `Plans/Active/AtomProjection.md`.
**Scope:** Define qué es `resources.resource_type = 'event'` en Ruul, qué NO es, y cómo se modela. Toda decisión de implementación sobre `event` consulta primero este documento.

> Ruul **NO** modela calendarios tradicionales. Ruul modela coordinación social mediante `resources`, `capabilities`, `rights`, `rules`, `atoms` y `projections`. `event` **NO** es solamente “algo con fecha”. `event` es el **resource temporal central** del sistema social.

---

## §1 — Definición ontológica

### Qué es un `event`

Un `event` es:

> Una coordinación temporal y social donde actores, recursos, reglas y acciones convergen durante una ventana de tiempo.

Un `event` puede representar:

- partido
- cena
- reunión
- viaje
- boda
- turno
- junta
- votación
- servicio religioso
- entrenamiento
- reservación
- sesión
- deadline
- mantenimiento
- check-in window
- recurring occurrence

---

## §2 — Principio cardinal

```
event = coordinación temporal
```

**NO:**

```
event = calendar row
```

La diferencia es enorme.

---

## §3 — `event` NO es solamente tiempo

Un `event` puede contener:

- participantes
- roles contextuales
- governance
- deadlines
- RSVP
- check-ins
- bookings
- rights
- obligations
- votes
- evidence
- workflows
- fines
- approvals
- ledger consequences
- recurrence
- notifications

Es el **centro operacional** de Ruul.

---

## §4 — Relación con otras entidades

### Event puede gobernar

- members
- assets
- spaces
- slots
- rights
- capabilities
- workflows

### Event puede usar

- assets
- spaces
- funds
- rights

### Event puede generar

- atoms
- obligations
- votes
- fines
- bookings
- projections

---

## §5 — Ejemplos canónicos

### Caso 1 — Partido de fútbol

**Resource:** `event: Partido jueves 8pm`

**Capabilities:**

```
rsvp
check_in
lineup
voting
fines
notifications
```

**Rules:**

```
primeros 11 → titulares
si no haces RSVP → multa
```

**Atoms:**

```
rsvp.created
check_in.created
fine.issued
role.assigned
```

### Caso 2 — Cena

**Resource:** `event: Cena semanal`

**Capabilities:**

```
rsvp
ledger
notifications
```

**Rules:**

```
si no confirmas antes del jueves → warning
```

### Caso 3 — Viaje

**Resource:** `event: Viaje Japón 2027`

**Puede contener:**

- itinerary
- bookings
- shared fund
- room assignments
- approvals
- expense governance

---

## §6 — Event vs occurrence vs series

Esto es **CRÍTICO**.

### Series

Serie conceptual:

> "Partidos de los jueves"

No es el partido específico.

### Occurrence

Instancia concreta:

> Partido del jueves 14 mayo

### Event

El resource temporal coordinador.

Un `event` puede ser:

- standalone
- occurrence de una series

---

## §7 — Event NO debe ser mutable como calendario tradicional

**NO hacer:**

```sql
UPDATE events
SET attendees_count = ...
```

El estado se **deriva** (ver §8 — atoms, §9 — projections).

---

## §8 — Atoms relacionados

### Atoms canónicos

```
event.created
event.updated
event.cancelled
event.started
event.ended
event.deadline_passed
```

### Atoms sociales

```
rsvp.created
check_in.created
participant_role.assigned
attendance.recorded
```

### Atoms económicos

```
fine.issued
payment.recorded
expense.added
```

---

## §9 — Projections derivadas

Event debe generar projections derivadas. Ejemplos:

```
attendance_view
lineup_view
rsvp_summary_view
event_balance_view
event_roles_view
event_deadlines_view
event_activity_feed
```

---

## §10 — Event como centro de governance

Rules pueden aplicar:

- al grupo
- al tipo de resource
- a una series
- a un occurrence específico

### Precedencia

```
occurrence > resource > series > group > global
```

---

## §11 — Event puede tener rights

Ejemplos:

- Jose tiene prioridad de RSVP
- Linda tiene acceso VIP
- Consejo tiene veto sobre invitados

---

## §12 — Event puede usar spaces/assets

Ejemplos:

```
event → usa cancha
event → usa palco
event → usa salón
event → usa fondo
```

El `event` **NO** posee esos resources. Los **coordina temporalmente**.

---

## §13 — Event puede contener workflows

Ejemplos:

- votaciones
- approvals
- appeals
- disputes
- lineup selection
- waitlists

---

## §14 — Event como unidad social primaria

En Ruul, muchas experiencias del usuario viven alrededor de events:

- "¿Quién va?"
- "¿Quién llegó?"
- "¿Quién paga?"
- "¿Quién juega?"
- "¿Quién tiene prioridad?"
- "¿Qué pasó?"
- "¿Qué reglas aplican?"
- "¿Qué cambió?"

---

## §15 — Arquitectura de datos

Event vive en:

```
resources.resource_type = 'event'
```

**NO crear:** una tabla `events` gigante monolítica.

---

## §16 — Event capabilities

| Capability   | Significado                  |
|--------------|------------------------------|
| `scheduling` | fechas                       |
| `rsvp`       | asistencia                   |
| `check_in`   | llegada                      |
| `lineup`     | asignación contextual        |
| `voting`     | decisiones                   |
| `fines`      | consecuencias                |
| `ledger`     | gastos                       |
| `reminders`  | notificaciones               |
| `booking`    | reservas                     |
| `recurrence` | repetición                   |
| `approvals`  | autorizaciones               |

---

## §17 — Event lifecycle

### Estados reales NO mutables

**NO usar:**

```
status = active
```

como verdad primaria.

La realidad se **deriva** de atoms.

### Ejemplo

```
event.started
event.ended
event.cancelled
```

→ projections derivan:

```
is_live
is_past
is_cancelled
```

---

## §18 — Event governance

Rules típicas:

```
si no haces RSVP → multa
primeros 11 → titulares
si llegas tarde → banca
si cupo lleno → waitlist
```

---

## §19 — Event NO es task

**Tasks:**

- trabajo individual
- completables

**Events:**

- coordinación colectiva temporal

---

## §20 — Event NO es booking

**Booking:** claim temporal sobre un resource.

**Event:** coordinación social.

Un `event` puede **crear** bookings. No son lo mismo.

---

## §21 — Event NO es workflow

**Workflow:** proceso abierto.

**Event:** contexto temporal.

Un `event` puede **contener** workflows.

---

## §22 — UI/UX correcto

La UI debe sentirse como:

> "Todo lo relacionado a este momento social"

**NO** como Google Calendar.

---

## §23 — Tabs sugeridos para Event Detail

### Header

- nombre
- tiempo
- lugar
- status derivado

### Tabs

| Tab         | Contenido                                  |
|-------------|--------------------------------------------|
| Overview    | Resumen general                            |
| People      | RSVP, check-ins, lineup, invitados         |
| Activity    | Atoms / feed                               |
| Rules       | Qué governance aplica                      |
| Finance     | Gastos, multas, balances                   |
| Resources   | Spaces / assets usados                     |
| Decisions   | Votes / approvals                          |

---

## §24 — Event y atoms

El `event` es una **agregación social**. Los atoms son la **verdad histórica**.

Ejemplo:

```
event.created
rsvp.created
check_in.created
vote.cast
fine.issued
        ↓
event_projection
```

---

## §25 — Filosofía Talmúdica / legal

La ley **no** gobierna "eventos". Gobierna:

- actos
- obligaciones
- tiempos
- presencia
- prioridades
- participación
- consecuencias

Ruul debe modelar eso correctamente. El `event` es el **recipiente temporal** de esos actos.

---

## §26 — Decisiones NO negociables

### Sí

- events como resources
- atoms append-only
- projections derivadas
- governance sobre events
- contextual roles
- recurrence separada de occurrence
- event como coordinación temporal

### No

- Google Calendar clone
- mutable status truth
- attendees arrays mutables
- lógica client-side
- event monolith table
- stateful counters manuales

---

## §27 — Resultado esperado

El sistema debe poder modelar:

- partidos
- cenas
- viajes
- bodas
- reuniones
- turnos
- servicios
- sesiones
- bookings sociales
- deadlines
- recurring events
- votaciones temporales
- workflows coordinados

**SIN crear nuevos resource types.**

---

## §28 — Definición final

### Event

> Resource temporal que coordina actores, resources, capabilities, governance y actions durante una ventana de tiempo, dejando evidencia append-only mediante atoms y derivando estado mediante projections.

Ese es el modelo canónico de `event` en Ruul.
