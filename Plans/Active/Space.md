# Ruul — `space` Resource Type (Canonical Specification)

**Status:** Canónico desde 2026-05-18. Founder directive.
**Companion of:** `Plans/Active/Constitution.md` (Artículo 2 — enum congelado), `Plans/Active/EventResource.md` (spec hermana — coordinación temporal), `Plans/Active/Asset.md` (spec hermana — objeto persistente con custody/valuation), `Plans/Active/HierarchyReference.md` §2 (resource types) y §3 (capabilities), `Plans/Active/AtomProjection.md` (atoms y projections).
**Scope:** Define qué es `resources.resource_type = 'space'` en Ruul, qué NO es, y cómo se modela. Toda decisión de implementación sobre `space` consulta primero este documento.

> Ruul **NO** modela calendarios, ni booking software tradicional, ni room management systems. Ruul modela coordinación social sobre **lugares, capacidades y superficies ocupables/gobernables en el tiempo** mediante `resources`, `capabilities`, `bookings`, `rules`, `atoms` y `projections`. Un `space` **NO** es solamente "un lugar que puede reservarse". Un `space` es el **resource persistente central** del sistema social cuando lo que se coordina es ocupación, disponibilidad, acceso y capacidad — distinto de **asset** (cuya coordinación es custody/valuation/transfer) y distinto de **event** (cuya coordinación es momento social específico).

---

## §1 — Definición ontológica

### Qué es un `space`

Un `space` es:

> Un lugar, capacidad o superficie persistente sobre el cual un grupo coordina ocupación, disponibilidad, acceso, capacidad, scheduling y consecuencias mediante reglas.

Un `space` puede representar:

- palco
- cancha
- sala de juntas
- oficina
- escritorio (hot-desk)
- departamento
- hotel room
- quirófano
- estacionamiento
- mesa de restaurante
- yacht berth
- coworking desk
- bodega
- locker (cuando lo principal es ocupación, no custody)
- aula
- cabina
- estudio
- venue

---

## §2 — Principio cardinal

```
space = lugar / capacidad / superficie ocupable persistente
```

**NO:**

```
space = calendario
space = booking table
space = event container
space = "thing with an address"
space = mutable {is_booked, waitlist[]}
```

La diferencia es enorme. Un `space` es **continuo** — existe entre los actos de uso. Los eventos lo **ocupan**, los slots lo **particionan**, los rights le **dan acceso**, los bookings lo **reservan** temporalmente. La verdad de ocupación nunca vive en una columna mutable de `spaces` (de hecho: la tabla `spaces` no existe). Toda derivación de "libre / ocupado / aforo / waitlist" proviene de projections sobre atoms.

---

## §3 — `space` NO es

| Esto | Pertenece a | Por qué |
|------|-------------|---------|
| Evento que ocurre en el palco | `event` | El evento es la ocurrencia temporal; el palco persiste |
| Dinero del fondo del palco | `fund` | Movimiento monetario, no superficie |
| Propiedad legal del palco | `asset` | Custody + valuation + transfer, no ocupación |
| Derecho de acceso al palco | `right` | Derecho normativo del miembro, no la superficie |
| Horario 19:00-20:00 en la cancha | `slot` | Partición temporal/atómica del espacio |
| Una reserva del palco | `booking` (atom) | Acto de reservar, no objeto |

**Ejemplo concreto del "palco" (capas, no alternativas):**

Asset y Space NO son alternativas mutuamente excluyentes — son **capas distintas** que el grupo coordina sobre la misma realidad. Lo correcto es **vincularlas** cuando ambas existen:

| Capa | Pregunta que responde | En el caso del palco |
|------|-----------------------|----------------------|
| **Asset** | "¿Quién posee esto económicamente?" | `asset: 50% Palco Mundial` — ownership, valuación, equity, herencia, venta, impuestos |
| **Space** | "¿Quién usa esto, cuándo, cómo?" | `space: Palco Mundial` — ocupación, partidos, reservas, asignación, reglas de uso |
| **Event** | "¿Qué pasa en él en este momento?" | `event: Final Mundial` — momento social específico |
| **Right** | "¿Quién tiene derecho a entrar?" | `right: Uso preferente semifinales` — acceso, boletos |

**Vínculo canónico:**

```
ASSET                                  SPACE                          EVENT                       RIGHT
50% Palco Mundial    —owns→     Palco Mundial    —scheduled_in→   Final Mundial    ←grants_access_to—  Boleto VIP
(layer económico/legal)          (layer operativo)                  (layer temporal)            (layer entitlement)
```

Esto refleja la distinción jurídica clásica entre **propiedad**, **posesión**, **usufructo**, **acceso**, **uso**, **ocupación**, **licencia** y **temporalidad** — Ruul las separa porque son operacionalmente distintas:

| Caso real         | Asset (ownership)              | Space (occupancy)               |
|-------------------|--------------------------------|----------------------------------|
| Oficina           | propiedad del inmueble         | oficina usable                   |
| Avión             | ownership financiero           | asientos / vuelos                |
| Yate              | ownership                      | camarotes / slots                |
| Hotel             | edificio                       | habitaciones                     |
| Estadio           | propiedad                      | palco / asientos                 |
| Coworking         | lease / propiedad              | desks / salas                    |
| Parking           | propiedad del lote             | lugares específicos              |
| Hospital          | propiedad del edificio         | quirófanos                       |

Un mismo `space` puede tener múltiples `assets` (fractional ownership), múltiples `rights` (entitlements), múltiples `events` (timeline), múltiples `funds` (sub-pools) y múltiples `slots` (partition) sobre él. El space es el **operational layer central** que orquesta el uso real; el asset es el **ownership ledger** que orquesta el valor económico.

El wizard de iOS debe permitir crear ambos con un solo flow cuando aplica ("Crear palco" = `space` + `asset` linked vía `resource_links` con kind `owns`) — no forzar al usuario a elegir entre dos primitivas que el mundo real combina.

---

## §4 — Relación con otras entidades

### Space puede gobernar

- bookings sobre sí mismo
- waitlist cuando se llena
- capacity rules
- access rules (quién puede reservar/entrar)

### Space puede usar

- funds (mantenimiento, limpieza, utilities)
- rules (governance específica del espacio)
- rights (granting access)

### Space puede generar

- atoms (`space.booked`, `space.released`, `space.capacity_reached`, `space.waitlist_joined`, `space.waitlist_promoted`, `space.access_granted`, `space.access_revoked`)
- bookings (atom: `bookings` table)
- obligations (multa por cancelación tardía, fee por no-show)
- availability projection
- occupancy projection
- capacity projection
- waitlist projection
- usage history projection
- ledger entries (mantenimiento, daños)

### Relaciones universales que Space debe soportar

```
event   --scheduled_in--> space        # "Final Mundial scheduled_in Palco Mundial"
space   --located_in --> space         # "Locker Room located_in Clubhouse"
asset   --located_in --> space         # "Proyector located_in Sala de Juntas"
fund    --owns       --> space         # "Shamiz Park Fund owns Palco Mundial"
asset   --owns       --> space         # (composite ownership)
right   --grants_access_to--> space    # "Membership grants_access_to Coworking Floor"
slot    --reserves   --> space         # "Cancha 19:00-20:00 reserves Cancha 7"
booking --reserves   --> space|slot    # booking atom carries the claim
```

`resource_links` (mig `resource_links_polymorphic` en prod) materializa estas relaciones polimórficamente. Space no inventa link kinds — usa los canónicos.

---

## §5 — Ejemplos canónicos

### Caso 1 — Palco compartido del grupo (multi-layer)

**Resources (3 vinculados):**

```
asset: 50% Palco Mundial Estadio Azteca   (ownership: custody + valuation + transfer)
  └─owns→
space: Palco Mundial Estadio Azteca       (occupancy: booking + waitlist + check-in)
  ├─scheduled_in←
  │   event: Final Mundial 2026           (occurrence)
  └─grants_access_to←
      right: Boleto VIP Semifinales       (entitlement)
```

El space coordina **operación**; el asset coordina **propiedad**. Vinculados via `resource_links` con kind `owns`.

**Capabilities:**

```
booking
schedule
check_in
capacity
location
guest_access
access_control
voting
rules
ledger
history
```

**Rules:**

```
si occupancy >= capacity → waitlist
si member.role == founder → priority +100
si booking outside allowed_hours → deny
si cancellation <24h → fine $200
si no check_in within 30m → release booking
```

**Atoms:**

```
spaceCreated
booking.created (slot 19:00 del partido, Jose)
checkInRecorded (al entrar)
space.booked (palco entero, Maria, viernes)
space.waitlist_joined (Daniel, cuando se llena)
space.waitlist_promoted (Daniel, al liberarse)
space.access_granted (Pedro, guest pass)
space.released (al terminar)
```

### Caso 2 — Sala de coworking

**Resource:** `space: Coworking Floor 3`

**Capabilities:**

```
booking
availability
capacity
check_in
access_control
ledger
```

**Rules:**

```
capacity = 24
si member.tier == "premium" → priority booking
si no check_in within 15m → release
si overflow → waitlist promoted automáticamente
```

### Caso 3 — Cancha multi-deporte

**Resource:** `space: Cancha 7`

**Capabilities:**

```
booking
schedule
capacity
check_in
maintenance
```

**Rules:**

```
capacity varies by sport (futbol=22, tenis=4)
mantenimiento overdue → bloquea bookings nuevos
booking >2h continuous → vote
```

### Caso 4 — Sala de juntas corporativa

**Resource:** `space: Sala Reforma`

**Capabilities:**

```
booking
schedule
capacity
check_in
location
```

**Rules:**

```
capacity = 12
booking outside 08:00-20:00 → deny
booking <30m antes → permitir solo si vacío
```

### Caso 5 — Hotel room / hospitality

**Resource:** `space: Habitación 204`

**Capabilities:**

```
booking
availability
check_in
ledger
maintenance
capacity
```

**Rules:**

```
booking requires payment
late check-out → fee per hour
damage report → block until inspected
```

---

## §6 — Space NO es occurrence

Un `event` tiene `occurrence` (instancia temporal específica). Un `space` **no** — el space es **continuo en el tiempo**.

Si necesitas "uso específico del space el jueves", eso es:

- `booking` sobre el space (claim temporal sobre el todo), o
- `slot` que particiona el space en ventanas atómicas reservables (e.g. "Cancha 7 19:00-20:00"), o
- `event` que se programa en el space (`event scheduled_in space`)

Space no se "instancia". Space **es**, persistentemente, hasta que se archiva.

---

## §7 — Space NO debe ser mutable como inventory row

**NO hacer:**

```sql
UPDATE resources
SET is_booked = true, current_occupancy = 5, waitlist = '["Jose","Daniel"]'::jsonb
WHERE resource_type = 'space'
```

El estado de ocupación se **deriva** (ver §9 — atoms, §10 — projections).

Excepción permitida — *shortcuts de display* que viven en `resources.metadata`, siempre escritos por la RPC que **también** emite el atom — el atom es la verdad, el metadata es el cache de UI:

- `metadata.capacity` (límite máximo declarado, no occupancy actual)
- `metadata.location_name` / `metadata.location_lat` / `metadata.location_lng`
- `metadata.description`

`metadata.capacity` es el **techo declarado**, NO la ocupación actual. La ocupación actual vive en `space_capacity_view` derivada de atoms + bookings activos.

---

## §8 — Booking architecture (canónico)

### Booking NO es estado mutable del space

**NO hacer:**

```sql
UPDATE resources SET is_booked = true WHERE id = :space_id
```

**PROHIBIDO** — viola Constitution §15 (Resource ≠ Action) y §16 ("estados mutables que pueden derivarse").

### Booking es atom + projection

```
booking atom            → public.bookings (mig 00216)
                          append-only, guarded by bookings_atom_guard
                          un row = una claim de reserva
                          
cancellation / expiration → system_events (bookingCancelled / bookingExpired)
                          se derivan separadamente; bookings NO se UPDATE-an

availability projection → space_availability_view
                          deriva de bookings + cancellation atoms + slots + rules

occupancy projection    → space_occupancy_view
                          deriva de check_in_actions + bookings + atoms

capacity projection     → space_capacity_view
                          deriva de metadata.capacity (techo) + bookings actuales + check-ins

waitlist projection     → space_waitlist_view
                          deriva de space.waitlist_joined atoms - space.waitlist_promoted atoms
```

Cuando un booking se cancela, **no se borra**. Se inserta otro row `system_event` con `event_type = 'bookingCancelled'` referenciando el `booking_id`. La projection deriva "qué bookings están activos hoy" haciendo `bookings LEFT JOIN cancellations` y filtrando.

### `bookings` ya existe

`public.bookings` (mig 00216) es el atom canónico, hoy escrito por `book_slot`. Para space, la convención análoga es `book_space(p_space_id, p_starts_at?, p_ends_at?, p_notes?)` que inserta un row con `slot_id` apuntando al **space resource** (mismo wire shape; el FK ya es polimórfico vía `resources.id`).

> **Decisión arquitectónica**: en lugar de añadir columna `space_id`, reusamos el column `slot_id` como "target resource id" polimórficamente. La column name es legacy del primer caller (slots); el contenido es cualquier resource que admita bookings. Una migración futura puede renombrarlo a `target_resource_id` cuando haya tiempo de touch RLS + edge fns + iOS callers.

---

## §9 — Atoms relacionados

### Atoms canónicos de space (mig 00264)

```
spaceCreated            — ya existe (mig 00203)
space.booked            — spaceBooked
space.released          — spaceReleased
space.capacity_reached  — spaceCapacityReached
space.waitlist_joined   — spaceWaitlistJoined
space.waitlist_promoted — spaceWaitlistPromoted
space.access_granted    — spaceAccessGranted
space.access_revoked    — spaceAccessRevoked
```

### Atoms compartidos (no duplicados)

```
checkInRecorded         — ya existe (mig 00154). Aplica al space cuando
                           el resource_id apunta a un space.
bookingCreated          — ya existe (mig 00203 whitelist + mig 00216 atom)
bookingCancelled        — ya existe whitelist
bookingExpired          — ya existe whitelist
resourceArchived        — ya existe (mig 00186)
resourceUnarchived      — ya existe
resourceRenamed         — ya existe
resourceLinked          — ya existe (event scheduled_in space, etc.)
resourceUnlinked        — ya existe
```

Todos `INSERT ONLY` sobre `system_events`, protegidos por trigger `system_events_atom_guard` (mig 00162). `processed_at` es la única columna mutable y solo one-way.

`bookings` (atom append-only) está bajo `bookings_atom_guard` (mig 00216).

---

## §10 — Projections derivadas (mig 00266)

Space deriva projections — **nunca** persiste verdad independiente. Las 4 canónicas iniciales:

```
space_availability_view    — windows libres / ocupados por space
space_capacity_view        — capacity declarada vs ocupación actual + waitlist count
space_occupancy_view       — quién ocupa AHORA + bajo qué claim (booking/event/right)
space_history_view         — feed cronológico de eventos atómicos relevantes
```

Todas `security_invoker=on` — RLS sobre `system_events` + `resources` + `bookings` aplica.

Futuras (cuando demanda lo pida):

```
space_booking_load_view    — densidad de bookings por window
space_waitlist_view        — ordered waitlist actual
space_access_view          — quién tiene derecho activo a entrar
space_revenue_view         — ledger sumado por space (si charging)
```

---

## §11 — Space como centro de governance

Rules pueden aplicar:

- al grupo entero (default policy)
- al `resource_type='space'` global (e.g. "todo space requiere check-in")
- a un space específico (resource-scoped)
- a una capability sobre space (e.g. todos los bookings del grupo)

### Precedencia

```
resource > resource_type > group > global
```

(Mismo patrón que events §10 y asset §10 — sin `series`/`occurrence` porque space no se instancia).

### Engine

Server-only, determinístico, sobre `system_events`. Misma máquina que events/asset; el `event_type` discrimina (`spaceBooked`, `spaceWaitlistJoined`, `checkInRecorded`, etc.).

---

## §12 — Waitlist (canónico)

Waitlist NO es:

```
resources.metadata.waitlist_json = ['Jose', 'Daniel', 'Alan']
```

**PROHIBIDO** — viola §7 y §16.

### Waitlist correcto

Waitlist es **ordered projection** derivada de:

```
space.waitlist_joined atoms     (member_id, occurred_at, priority)
- space.waitlist_promoted atoms  (member_id, occurred_at)
- space.waitlist_left atoms      (futuro, cuando alguien renuncia su slot)
```

`space_waitlist_view` proyecta el order: `(latest joined per member) NOT IN (promoted)`, ordenado por `priority desc, joined_at asc`.

Reglas determinan `priority` en el `waitlist_joined` atom (founder=+100, premium=+50, default=0).

---

## §13 — Access model

Space soporta acceso mediante:

- **membership rights** — `right.grants_access_to space` (cualquier miembro con ese right pasa)
- **temporary rights** — rights con `expires_at` cercano (e.g. day pass)
- **bookings** — claim explícita por ventana de tiempo
- **admin overrides** — RPC `grant_space_access(p_space_id, p_member_id, p_until?, p_reason?)` emite `space.access_granted`
- **governance rules** — eligen quién puede booking/exercise (e.g. "founder bypass capacity")

Access projection (`space_access_view`, P2 follow-up) deriva quién tiene derecho activo a entrar AHORA.

---

## §14 — Space capacity

Capacity NO es hardcoded en código. Debe soportar:

- **fixed capacity** — `metadata.capacity = 10` (palco con 10 asientos)
- **dynamic capacity** — derivada de rules + sport/use mode (cancha futbol=22, tenis=4)
- **partitioned capacity** — coworking con N escritorios independientes (cada uno es un slot child del space)
- **quota capacity** — capacity = X por member-day (parking pass: 1 por día)

`metadata.capacity` es el techo simple por default. Capacity dinámica se modela como capability config (`capacity.config.mode = 'dynamic' | 'partitioned' | 'quota'`).

### Ejemplos

```
Palco       — capacity = 10                                (fixed)
Coworking   — capacity = floor.desks_count                 (dynamic)
Cancha      — capacity = sport == 'futbol' ? 22 : 4         (rule-driven)
Parking     — capacity = 1 per member per day              (quota)
```

---

## §15 — Arquitectura de datos

Space vive en:

```
resources.resource_type = 'space'
```

**NO crear:** una tabla `spaces` gigante monolítica. **NO crear:** subtype tables (`venues`, `rooms`, `parking_spaces`). Toda diferencia entre tipos de space vive en `metadata` (jsonb) + capabilities activadas.

`bookings` (existing atom table, mig 00216) sirve a space igual que sirve a slot.

---

## §16 — Space capabilities (mig 00207 + 00265)

Catálogo canónico:

| Capability      | Significado                                                | Status     |
|-----------------|------------------------------------------------------------|------------|
| `booking`       | claim temporal de uso sobre el space                       | stable     |
| `schedule`      | scheduling de bookings/events                              | stable     |
| `check_in`      | registrar presencia al entrar                              | stable     |
| `capacity`      | techo de aforo + waitlist                                  | stable     |
| `location`      | dónde vive físicamente (address + coords)                  | stable     |
| `guest_access`  | invitados externos del miembro                             | stable     |
| `availability`  | consultar ventanas libres                                  | mig 00265  |
| `access_control`| gate de quién puede entrar (RBAC contextual)               | mig 00265  |
| `waitlist`      | cola ordenada cuando se llena                              | mig 00265  |
| `maintenance`   | reportar limpieza / daños / utilities                      | stable (shared with asset) |
| `voting`        | decisiones sobre el space                                   | stable     |
| `rules`         | governance específica                                       | stable     |
| `ledger`        | gastos asociados                                            | stable     |
| `status`        | estado de display derivado                                  | stable     |
| `description`   | texto libre                                                 | stable     |
| `history`       | feed cronológico                                            | stable     |

`availability` + `access_control` + `waitlist` se materializan en mig 00265 (capability catalog extension + dependency edges).

---

## §17 — Space lifecycle

### Estados reales NO mutables

**NO usar:**

```
status = "occupied"
status = "available"
status = "full"
```

como verdad primaria.

La realidad se **deriva** de atoms.

### Ejemplo

```
spaceCreated → existe
booking.created (Jose, viernes 19:00) → claim insertada
checkInRecorded (Jose, viernes 19:05) → ocupando
space.capacity_reached (al llenarse el aforo) → waitlist enabled
space.waitlist_joined (Daniel) → en cola
booking.cancelled (Jose, sábado) → claim retirada
space.waitlist_promoted (Daniel) → promovido
space.released (al final) → fin de la ventana
resourceArchived → fin de vida del space
```

→ projections derivan:

```
is_available_now
current_occupancy
upcoming_bookings_count
waitlist_count
last_used_at
```

---

## §18 — Space governance — rule templates canónicos

Ejemplos (no exhaustivo, ver follow-up `Plans/Active/SpaceRules.md` cuando aterrice):

```
si occupancy >= capacity                  → waitlist (auto-emit space.capacity_reached + space.waitlist_joined)
si cancellation < 24h                     → fine
si no check_in within 30m of booking      → release + notify next in waitlist
si booking outside allowed_hours          → deny
si member.role == founder                 → priority +100 in waitlist
si maintenance overdue                    → lock bookings nuevos
si damage reported severity=major         → vote para temporary closure
si booking duration > limit               → require approval
```

Cada template es `WHEN <atom> → IF <conditions> → THEN <consequences>` server-side. UI las expone en el Template Gallery del Rule Builder.

---

## §19 — Space NO es event

**Event:** coordinación temporal (momento social).

**Space:** lugar persistente con identidad propia.

Un `event` puede **scheduled_in** un space (la cena usa el palco). Un `space` puede **generar** eventos asociados (e.g. mantenimiento programado = event). No son el mismo primitive.

---

## §20 — Space, Asset, Slot, Right son CAPAS, no alternativas

**Asset:** **ownership layer** — quién posee económicamente. Custody, valuation, transfer, equity, herencia, impuestos.

**Space:** **operational/occupancy layer** — quién usa, cuándo, cómo. Booking, availability, capacity, access, scheduling.

**Slot:** **partition layer** — unidad atómica de tiempo o cupo dentro de un space. La cancha tiene slots 19:00, 20:00, 21:00; el palco tiene lugar 14.

**Right:** **entitlement layer** — derecho normativo de acceso o uso preferente. Membresía, boleto VIP, equity de voto, day pass.

**Event:** **temporal coordination layer** — momento social específico que ocupa el space.

La diferencia práctica NO es elegir uno — es **vincularlos** cuando aplica:

```
ASSET (ownership)            owns →  SPACE (occupancy)
                                     SPACE  partitioned_in → SLOTS (time/seat windows)
                                     SPACE  scheduled_in   → EVENTS (occurrences)
                                     SPACE  ←grants_access_to— RIGHTS (entitlements)
                                     SPACE  ←linked_to—  FUNDS (sub-pools / maintenance)
```

**Ejemplos:**

- "Palco Mundial" → `space` (operación) **+** `asset 50%` (ownership) linked via `owns`.
- "Lugar 14 del palco" → `slot` child del space.
- "Membresía Gold con acceso al palco" → `right` que `grants_access_to` el space.
- "Final Mundial" → `event` que `scheduled_in` el space.
- "Fondo Palco" → `fund` que `owns` o `funds_maintenance_of` el space.

**Cuándo crear solo space sin asset:** cuando el grupo no quiere tracking de ownership/valuación (e.g. sala de juntas corporativa que la empresa simplemente "tiene"; coworking floor rentada).

**Cuándo crear solo asset sin space:** cuando el objeto no es ocupable temporalmente (e.g. herramienta que se presta — más cerca de custody que de occupancy; NFT/equity que no tiene "ocupación").

**Cuándo crear ambos linked:** cuando ambas capas existen como realidades coordinadas distintas (palco con ownership compartido, hotel con habitaciones reservables, yacht con camarotes, oficina con sub-rooms). Esto es **lo más común** en el mundo real.

---

## §21 — Space NO es fund

**Fund:** pool monetario gobernable.

**Space:** lugar persistente.

Un space puede tener `ledger` (gastos asociados: limpieza, mantenimiento, utilities, fees) — eso no lo convierte en fund. Fund es **dinero líquido coordinado**; space es **superficie coordinada** que **puede** mover dinero.

Un fund puede `owns` un space (`fund.owns space`) — relación válida vía `resource_links`.

---

## §22 — UI/UX correcto

La UI debe sentirse como:

> "Todo lo relacionado a este lugar del grupo"

**NO** como:

- calendario booking app
- room management ERP
- hotel PMS plano
- mutable {is_booked: true} flag

### Doctrina actual: universal frame inline-sections

Space **no** tiene un detail view propio. Renderiza dentro de `UniversalResourceDetailView` (Fund-style scaffold post-`b01f8fb`), igual que event/fund/asset/slot/right.

### Secciones space-específicas

Cuando `resource_type='space'` y la capability está activa, `UniversalResourceDetailView` inyecta inline:

| Sección                  | Capability     | Proyección base                       |
|--------------------------|----------------|---------------------------------------|
| `SpaceAvailabilitySection` | `booking` o `availability` | `space_availability_view`     |
| `SpaceOccupancySection`    | `check_in` o `booking`     | `space_occupancy_view`         |
| `SpaceCapacitySection`     | `capacity`                 | `space_capacity_view`          |
| `SpaceWaitlistSection`     | `waitlist`                 | `space_waitlist_view` (P2)     |
| `SpaceBookingsSection`     | `booking`                  | `bookings` + `space_history_view` |
| `SpaceAccessSection`       | `access_control`           | `space_access_view` (P2)        |

Cada sección es un componente SwiftUI independiente bajo `Features/Resources/Detail/Sections/Space/SpaceSections.swift`. Hablan con `SpaceLifecycleRepository` directamente y disparan los atoms canónicos del §9.

### Availability UI canónica

```
HOY
09:00  Libre
10:00  Reservado (Jose)
11:00  Reservado (Daniel)
12:00  Libre
13:00  Libre
```

### Occupancy UI canónica

```
AHORA
Jose y Maria
Hasta 11:30 — booking
+ Pedro como guest
```

### Waitlist UI canónica

```
EN COLA
1. Jose            (founder, priority 100)
2. Daniel          (joined 09:01)
3. Alan            (joined 09:15)
```

---

## §23 — Space y atoms

El `space` es una **agregación social persistente**. Los atoms son la **verdad histórica**.

Ejemplo:

```
spaceCreated
booking.created
checkInRecorded
space.capacity_reached
space.waitlist_joined
space.waitlist_promoted
space.released
        ↓
space_projection (availability + occupancy + capacity + waitlist + history)
```

---

## §24 — Realtime

Space debe agregar realtime subscriptions para:

- `bookings` (INSERT)
- `system_events WHERE event_type IN ('spaceBooked', 'spaceReleased', 'spaceCapacityReached', 'spaceWaitlistJoined', 'spaceWaitlistPromoted', 'checkInRecorded')`

usando el **kick-based refresh pattern** (cliente recibe notify, refetch projection) — NO optimistic local truth.

Realtime publication ya existe (mig `realtime_publication_for_multidevice`); las secciones space hacen `.task(id:)` con un refresh token bumped on event.

---

## §25 — Constraints doctrinales (NO hacer)

- mutable booking states (`is_booked = true`)
- direct occupancy flags (`current_occupancy = 5`)
- arrays JSON de bookings o waitlists
- overlap logic client-side
- booking truth en SwiftUI local state
- duplicated schedule tables
- special-case vertical hacks (`palco_bookings`, `cancha_slots`)
- tabla `spaces` separada

---

## §26 — Decisiones NO negociables

### Sí

- spaces como resources polimórficos
- bookings como atom append-only compartido (con slot)
- projections derivadas (4 canónicas + extensibles)
- governance sobre spaces (resource-scoped + heredada)
- capabilities universales
- waitlist como projection sobre atoms
- access via rights + bookings + admin overrides + rules
- capacity como techo declarativo + projection de uso

### No

- inventory tracker clone
- calendar app clone
- mutable status truth (`status='booked'` directo)
- subtype tables (`venues`, `rooms`, `parking`)
- arrays mutables en metadata (`waitlist_json`, `current_users`)
- lógica client-side de overlap/availability
- space monolith table
- stateful counters manuales (occupancy, bookings_count)

---

## §27 — Resultado esperado

El sistema debe poder modelar:

- palcos
- canchas
- coworking floors
- hotel rooms
- quirófanos
- estacionamientos
- aulas
- estudios
- bodegas
- salas de juntas
- venues
- airport / aviation slots (con slot child)
- marinas (yacht berths)
- smart buildings
- government permits

**SIN crear nuevos resource types** y **SIN cambiar primitives**.

---

## §28 — Backend reference (canónico al 2026-05-18)

| Pieza                                | Migración           | Detalle                                                  |
|--------------------------------------|---------------------|----------------------------------------------------------|
| RPC `create_space`                   | `00207`             | Any-member create con `is_group_member` gate             |
| `build_resource_from_draft` (space)  | `00207`             | Wizard atomic path                                       |
| `bookings` atom + `book_slot`        | `00216`             | Compartido con space (slot_id reused polimórficamente)   |
| Atoms whitelist (7 nuevos)           | `00264`             | spaceBooked / spaceReleased / spaceCapacityReached / spaceWaitlistJoined / spaceWaitlistPromoted / spaceAccessGranted / spaceAccessRevoked |
| Capabilities (3 nuevos universales)  | `00265`             | availability / access_control / waitlist                 |
| RPCs lifecycle (9)                   | `00265`             | book_space / cancel_booking / expire_booking / join_waitlist / promote_from_waitlist / check_in_to_space / grant_space_access / revoke_space_access / update_space_metadata / archive_space / unarchive_space |
| Projections (4 vistas)               | `00266`             | space_availability_view / space_capacity_view / space_occupancy_view / space_history_view |
| Rule shapes + templates (space)      | `00267`             | space.capacity_reached → waitlist; cancellation<24h → fine; no_check_in_30m → release; etc. |

### iOS surface

- Model: `Space` (`PlatformModels/Space.swift`) — typed view of `resources WHERE resource_type='space'`
- Repo: `SpaceRepository` (list/get/create) + `SpaceLifecycleRepository` (book/cancel/checkin/waitlist/access/update/archive — mock + live)
- Projections: `SpaceAvailability`, `SpaceOccupancy`, `SpaceCapacityState`, `SpaceHistoryEntry` decodable from views
- UI: secciones inline dentro de `UniversalResourceDetailView` — `SpaceAvailabilitySection` / `SpaceOccupancySection` / `SpaceCapacitySection` / `SpaceBookingsSection` en `Features/Resources/Detail/Sections/Space/SpaceSections.swift`
- Wizard: `SpaceResourceBuilder` (registrado en `AppState.resourceBuilders`, visible bajo categorías "Lugares" + "Custom")
- Routing: `ResourceDetailSheet` despacha **todos** los tipos al mismo `UniversalResourceDetailView`

---

## §29 — Definition of Done

Space está completo cuando:

- puede ser reservado (`book_space` + bookings atom)
- puede ser cancelado (`cancel_booking` + `bookingCancelled` atom)
- soporta capacity (techo + projection)
- soporta waitlist (atoms + projection ordenada)
- soporta occupancy (check-in + projection)
- soporta scheduling (rules sobre allowed_hours, deadlines)
- soporta rights (grant_access + atom + projection)
- soporta events (`event scheduled_in space` via resource_links)
- soporta rules (rule shapes + templates space-specific)
- soporta money (ledger sobre space)
- soporta realtime (kick-based refresh)
- todo deriva de atoms
- no hay mutable truth (no `is_booked`, no `current_occupancy`, no `waitlist_json`)
- no hay vertical hacks (no `palco_*`, no `cancha_*`)
- funciona para palco/coworking/cancha/hotel/quirófano/parking SIN cambiar schema

---

## §30 — Definición final

### Space

> Resource persistente con identidad propia que coordina ocupación, disponibilidad, capacidad, acceso, scheduling y consecuencias mediante atoms append-only y projections derivadas, sin tabla propia ni status mutable como verdad primaria. Distinto de `asset` (custody/valuation/transfer), distinto de `event` (occurrence temporal), distinto de `slot` (partición atómica), distinto de `right` (derecho normativo).

Ese es el modelo canónico de `space` en Ruul.
