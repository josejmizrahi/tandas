# Ruul — `asset` Resource Type (Canonical Specification)

**Status:** Canónico desde 2026-05-15. Founder directive.
**Companion of:** `Plans/Active/Constitution.md` (Artículo 2 — enum congelado), `Plans/Active/EventResource.md` (spec hermana, mismo patrón), `Plans/Active/HierarchyReference.md` §2 (resource types) y §3 (capabilities), `Plans/Active/AtomProjection.md` (atoms y projections).
**Scope:** Define qué es `resources.resource_type = 'asset'` en Ruul, qué NO es, y cómo se modela. Toda decisión de implementación sobre `asset` consulta primero este documento.

> Ruul **NO** modela inventario, ni custody software, ni asset management tradicional. Ruul modela coordinación social sobre **objetos persistentes socialmente gobernables** mediante `resources`, `capabilities`, `rights`, `rules`, `atoms` y `projections`. Un `asset` **NO** es solamente "un objeto que tiene un dueño". Un `asset` es el **resource persistente central** del sistema social cuando lo que se coordina es un objeto, no un momento.

---

## §1 — Definición ontológica

### Qué es un `asset`

Un `asset` es:

> Un objeto persistente con identidad propia y lifecycle independiente, sobre el cual un grupo coordina custodia, uso, mantenimiento, valuación, transferencia y consecuencias mediante reglas.

Un `asset` puede representar:

- auto compartido
- equipo de sonido
- cancha o palco
- instrumento
- herramienta
- llave / acceso físico
- NFT / token
- equity / shares
- propiedad intelectual
- licencia de software
- hardware
- documento canónico
- locker
- bicicleta
- proyector
- libro
- planta / colección

---

## §2 — Principio cardinal

```
asset = objeto persistente socialmente gobernable
```

**NO:**

```
asset = inventory row
asset = palco-shaped slot container
asset = "thing with an owner"
```

La diferencia es enorme. Pre-2026-05 Ruul tenía la forma palco — un asset era casi un container de slots para bookings. La spec canónica eleva asset a primitiva universal: **cualquier objeto que el grupo coordine**.

---

## §3 — `asset` NO es solamente propiedad

Un `asset` puede contener:

- custodios contextuales
- ownership (member, group, shared, fractional)
- bookings (uso temporal con claim)
- check-out / check-in (préstamo)
- usage history
- mantenimientos
- daños reportados
- valuaciones recurrentes
- transfers
- rights derivados (acceso, delegación, veto)
- governance específica (quién puede usarlo, cuándo, bajo qué condiciones)
- fines / consecuencias por mal uso
- workflows (approval para gastos, voting para transfers grandes)

Es el **centro operacional** de Ruul cuando la coordinación es sobre objetos persistentes en vez de momentos.

---

## §4 — Relación con otras entidades

### Asset puede gobernar

- bookings sobre sí mismo
- custodios designados
- approvals para mantenimiento o transfer

### Asset puede usar

- funds (para gastos de mantenimiento)
- rights (privilegios de uso)
- events (un asset es usado durante un event)

### Asset puede generar

- atoms (custody.assigned, maintenance.logged, etc.)
- obligations (multa por daño, multa por no devolver)
- bookings (claim temporal sobre el asset)
- valuaciones históricas
- usage history projection
- maintenance state projection
- consequence rules sobre el grupo

---

## §5 — Ejemplos canónicos

### Caso 1 — Auto compartido del grupo

**Resource:** `asset: Auto Toyota familiar`

**Capabilities:**

```
custody
booking
maintenance
valuation
transfer
voting
ledger
```

**Rules:**

```
si reservas y no devuelves antes de 24h → multa $200
si reportas daño > $5,000 → requiere approval del consejo
si mantenimiento overdue → bloquea bookings nuevos
```

**Atoms:**

```
asset.created
custody.assigned (Jose lo tiene esta semana)
booking.created (Maria lo usa el viernes)
asset.checked_out
asset.checked_in
maintenance.logged (cambio de aceite)
damage.reported (rayón en puerta)
valuation.recorded ($280k MXN)
```

### Caso 2 — Equipo de sonido

**Resource:** `asset: Bocinas JBL del grupo`

**Capabilities:**

```
custody
booking
maintenance
ledger
```

**Rules:**

```
préstamo mayor a 7 días → vote group-wide
si lo devuelven dañado → consequence en ledger
```

### Caso 3 — Palco / espacio físico

**Resource:** `asset: Palco Estadio Azteca`

**Puede contener:**

- custody rotativa
- bookings por partido (compatible con events)
- guest_access (invitados extras)
- inventory (cuántos lugares ocupa)
- valuation (precio de mercado del palco)

### Caso 4 — NFT / equity / IP

**Resource:** `asset: Collection X NFT`

**Capabilities:**

```
custody
valuation
transfer
voting
```

**Rules:**

```
transfer > 10% del portfolio → vote 2/3
revaluation mensual automática (cron + valuation.recorded)
```

### Caso 5 — Inventario (capability, no resource_type)

**Resource:** `asset: Lockers piso 3`

`metadata.inventory_count = 24`, `metadata.unit_label = "locker"`.

`inventory` es una **capability sobre asset** (spec §17 — `inventory` no es resource_type propio). La projection `asset_inventory_view` lee `metadata.inventory_count` y deriva disponibilidad cruzando con bookings activos.

---

## §6 — Asset NO es occurrence

Un `event` tiene `occurrence` (instancia temporal específica). Un `asset` **no** — el asset es **continuo en el tiempo**.

Si necesitas "uso específico del asset el jueves", eso es:

- `booking` sobre el asset (claim temporal), o
- `event` que usa el asset (`event` coordina, `asset` provee)

Asset no se "instancia". Asset **es**, persistentemente, hasta que se archiva.

---

## §7 — Asset NO debe ser mutable como inventory row

**NO hacer:**

```sql
UPDATE resources
SET custodian_id = ..., last_maintenance = ..., value_current = ...
WHERE resource_type = 'asset'
```

El estado se **deriva** (ver §8 — atoms, §9 — projections).

Excepción permitida: shortcuts de display que viven en `resources.metadata` (e.g. `metadata.custodian_id` para la fila en HomeView), siempre escritos por la RPC que **también** emite el atom — el atom es la verdad, el metadata es el cache de UI.

---

## §8 — Atoms relacionados

### Atoms canónicos (mig 00204)

```
asset.created           — assetCreated  (también vía mig 00193)
asset.archived          — resourceArchived (genérico, mig 00186)
```

### Atoms de custodia

```
custody.assigned        — custodyAssigned
custody.released        — custodyReleased
```

### Atoms de mantenimiento

```
maintenance.logged      — maintenanceLogged
maintenance.completed   — maintenanceCompleted
damage.reported         — damageReported
```

### Atoms de uso

```
asset.used              — assetUsed
asset.checked_out       — assetCheckedOut
asset.checked_in        — assetCheckedIn
```

### Atoms de valuación / transfer

```
valuation.recorded      — valuationRecorded
asset.transferred       — assetTransferred
asset.assigned          — assetAssigned
asset.returned          — assetReturned
```

### Atoms de booking (compartidos con space/slot)

```
booking.created         — bookingCreated  (no duplicado en mig 00204)
```

Todos `INSERT ONLY` sobre `system_events`, protegidos por trigger `system_events_atom_guard` (mig 00162). `processed_at` es la única columna mutable y solo one-way.

---

## §9 — Projections derivadas (mig 00212)

Asset deriva projections — **nunca** persiste verdad independiente. Las 4 canónicas:

```
asset_current_custodian_view       — quién tiene el asset ahora
asset_valuation_view               — última valuación recorded
asset_maintenance_status_view      — mantenimientos abiertos (logged sin completed)
asset_usage_history_view           — feed de uso (check-out/in + asset.used)
```

Todas `security_invoker=on` — RLS sobre `system_events` + `resources` aplica.

Futuras (cuando demanda lo pida):

```
asset_ownership_view               — share fractional cuando entren equity tokens
asset_booking_load_view            — densidad de bookings por window
asset_damage_history_view          — eventos de daño + costo derivado
```

---

## §10 — Asset como centro de governance

Rules pueden aplicar:

- al grupo entero (default policy)
- al `resource_type='asset'` global
- a un asset específico (resource-scoped)
- a una capability sobre asset (e.g. todas las maintenance del grupo)

### Precedencia

```
resource > resource_type > group > global
```

(Mismo patrón que events §10 — sin `series`/`occurrence` porque asset no se instancia).

### Engine

Server-only, determinístico, sobre `system_events`. Misma máquina que events; el `event_type` discrimina (`custodyAssigned`, `damageReported`, etc.).

---

## §11 — Asset puede tener rights

Ejemplos:

- Jose tiene prioridad de booking sobre el auto
- Linda tiene veto sobre transfers > $50k
- El consejo tiene approval obligatoria para mantenimientos > $10k
- Miembros nuevos no pueden ser custodios primarios

`rights` se modelan como su propio `resource_type` y se referencian desde rules.

---

## §12 — Asset puede contener bookings

Un `asset` con capability `booking` activa permite:

```
asset → expone availability
member → crea booking (claim temporal)
member → checked_out (custodia transient)
member → checked_in (custodia revertida)
```

`booking` es un **atom + projection**, no un resource_type propio. La availability se deriva del asset + bookings activos + rules de capacidad.

---

## §13 — Asset puede contener workflows

Ejemplos:

- approval para gastos de mantenimiento
- vote para transfers grandes
- appeal sobre daño reportado
- waitlist cuando hay over-booking
- delegation de custody temporal

Workflows viven en `votes` / `user_actions` / `appeals` polimórficos, referenciando el asset por `reference_id`.

---

## §14 — Asset como unidad social primaria

En Ruul, muchas preguntas del usuario son sobre assets:

- "¿Quién tiene el auto?"
- "¿Cuándo es mi turno?"
- "¿Cuánto vale el palco hoy?"
- "¿Quién lo rompió?"
- "¿Quién pagó el último servicio?"
- "¿Está disponible el viernes?"
- "¿Quién tiene veto sobre la venta?"
- "¿Qué reglas aplican a este equipo?"

---

## §15 — Arquitectura de datos

Asset vive en:

```
resources.resource_type = 'asset'
```

**NO crear:** una tabla `assets` gigante monolítica. **NO crear:** subtype tables (`vehicles`, `equipment`, `nfts`). Toda diferencia entre tipos de asset vive en `metadata` (jsonb) + capabilities activadas.

---

## §16 — Asset capabilities (mig 00208)

Catálogo canónico:

| Capability      | Significado                                                | Status     |
|-----------------|------------------------------------------------------------|------------|
| `custody`       | quién tiene físico/operativo el asset ahora                | stable     |
| `booking`       | claim temporal sobre el asset                              | stable     |
| `inventory`     | conteo discreto (`metadata.inventory_count`)               | stable     |
| `maintenance`   | logged / completed / damage reported                       | stable     |
| `valuation`     | historial de valor                                         | stable     |
| `transfer`      | cambio de ownership con atom + governance                  | stable     |
| `voting`        | decisiones sobre el asset                                  | stable     |
| `guest_access`  | invitados pueden usarlo bajo el host                       | stable     |
| `capacity`      | cuántos caben/cuántas unidades                              | stable     |
| `location`      | dónde vive físicamente                                     | stable     |
| `status`        | estado de display derivado                                  | stable     |
| `description`   | texto libre + foto                                          | stable     |
| `history`       | feed cronológico                                            | stable     |
| `access`        | gate de quién puede tocar (RBAC contextual)                | incomplete |
| `delegation`    | custody temporal a otro miembro                             | incomplete |

`access` + `delegation` están declaradas pero el runtime path aterriza en follow-up. iOS oculta capabilities `incomplete` del wizard.

`ledger` no es asset-specific — cualquier resource lo puede activar para gastos asociados.

---

## §17 — Asset lifecycle

### Estados reales NO mutables

**NO usar:**

```
status = "in_use"
status = "available"
status = "broken"
```

como verdad primaria.

La realidad se **deriva** de atoms.

### Ejemplo

```
asset.created → existe
custody.assigned (Jose) → en custodia de Jose
asset.checked_out (Maria) → Maria lo tiene transient
damage.reported → marca de daño en projection
maintenance.logged → maintenance abierto
maintenance.completed → cierra ese maintenance
custody.released → vuelve a grupo
resource.archived → fin de vida
```

→ projections derivan:

```
is_in_custody
is_checked_out
has_open_maintenance
is_archived
current_value
```

---

## §18 — Asset governance — rule templates canónicos

Spec §15 ejemplos (no exhaustivo):

```
si reportas damage > $5,000             → require approval
si no devuelves después de booking      → multa
si maintenance overdue > 7 días         → lock bookings nuevos
si transfer > 10% portfolio             → vote 2/3
si checkin tardío                       → fine + warning
revaluation mensual                     → cron emite valuation.recorded
```

Cada template es `WHEN <atom> → IF <conditions> → THEN <consequences>` server-side. UI las expone en el Template Gallery del Rule Builder (Phase 2).

**Roadmap de implementación canónico:** `Plans/Active/AssetRules.md` — mapea cada template a sus shape IDs concretos, evaluators pseudocode y orden de migraciones (atoms → shapes → templates → cron → engine → iOS → tests).

---

## §19 — Asset NO es event

**Event:** coordinación temporal (momento social).

**Asset:** objeto persistente con identidad propia.

Un `event` puede **usar** un asset (la cena usa el palco). Un `asset` puede **generar** un event (mantenimiento programado = event). No son el mismo primitive.

---

## §20 — Asset NO es space ni slot

**Space:** subdivisión locacional persistente (cancha, salón, sala).

**Slot:** unidad atómica de tiempo o cupo (un turno de 1h, un lugar en lineup).

**Asset:** objeto persistente.

La diferencia práctica:

- "Palco" puede modelarse como **asset** (objeto persistente con custody + valuación + transfer) **o** como **space** (subdivisión que se reserva). El equipo elige según qué capabilities domina la coordinación: si lo principal es ownership/valuación → asset; si es booking-only → space.
- "Lugar 14 del palco" es **slot** dentro del space/asset.

Spec §17 framing: cuando hay ownership, value, custody y transferability, el primitive correcto es **asset**.

---

## §21 — Asset NO es fund

**Fund:** pool monetario gobernable.

**Asset:** objeto persistente.

Un asset puede tener `valuation` (cuánto vale) y `ledger` (gastos asociados) — eso no lo convierte en fund. Fund es **dinero líquido coordinado**; asset es **objeto coordinado** que **puede** tener valor.

NFTs / equity / tokens parecen "dinero" pero son **asset** porque tienen identidad discreta. Fungibilidad pura sin identidad = fund.

---

## §22 — UI/UX correcto

La UI debe sentirse como:

> "Todo lo relacionado a este objeto del grupo"

**NO** como:

- inventory list de almacén
- ERP asset tracker
- ownership ledger plano
- ERP-style 7-tab SegmentedPicker (el intento previo — descartado en `b01f8fb`)

### Doctrina actual: universal frame inline-sections

Asset **no** tiene un detail view propio. Renderiza dentro de `UniversalResourceDetailView` (Fund-style scaffold post-`b01f8fb`), igual que event/fund/space/slot/right. La página tiene la misma estructura para cualquier `resource_type`:

1. `DetailAttentionView` (cuando hay actions pendientes)
2. Icon-badge hero (chrome symbol + título + subtítulo de tipo)
3. Sección INFORMACIÓN (facts type-specific)
4. **Capability-gated sections** (Description, Location, RSVP, CheckIn, Money, Rules, ResourcesUsed, Activity, **Custody, Ownership, Maintenance, Bookings**)
5. Settings (manage capabilities + archive)
6. Sticky `ResourcePrimaryCTA` + toolbar

### Secciones asset-específicas

Cuando `resource_type='asset'` y la capability está activa, `UniversalResourceDetailView` inyecta inline:

| Sección               | Capability     | Proyección base                          |
|-----------------------|----------------|------------------------------------------|
| `AssetCustodySection` | `custody`      | `asset_current_custodian_view`           |
| `AssetOwnershipSection` | `transfer`   | (ownership shortcut en `metadata`)        |
| `AssetMaintenanceSection` | `maintenance` | `asset_maintenance_status_view`        |
| Bookings              | `booking`      | bookings activos + `asset_usage_history_view` |

Cada sección es un componente SwiftUI independiente bajo `Features/Resources/Detail/Sections/Asset/AssetSections.swift`. Hablan con `AssetLifecycleRepository` directamente y disparan los atoms canónicos del §8.

---

## §23 — Asset y atoms

El `asset` es una **agregación social**. Los atoms son la **verdad histórica**.

Ejemplo:

```
asset.created
custody.assigned
booking.created
asset.checked_out
maintenance.logged
damage.reported
        ↓
asset_projection (custody + value + state + history)
```

---

## §24 — Filosofía Talmúdica / legal

La ley **no** gobierna "cosas". Gobierna:

- posesión
- custodia
- responsabilidad
- daños
- transferencia
- usufructo
- consecuencias

Ruul debe modelar eso correctamente. El `asset` es el **recipiente persistente** de esos actos. La diferencia con eventos: el asset existe **entre** los actos, no solo durante.

---

## §25 — Decisiones NO negociables

### Sí

- assets como resources
- atoms append-only
- projections derivadas (4 canónicas + extensibles)
- governance sobre assets (resource-scoped + heredada)
- capabilities universales (15 declaradas, 13 stable)
- custody ≠ ownership (custody = quién físicamente; ownership = quién legalmente)
- inventory como capability, no resource_type
- booking polimórfico (asset/space/slot lo comparten)

### No

- inventory tracker clone
- ERP asset management clone
- mutable status truth (`status='broken'` directo)
- subtype tables (`vehicles`, `nfts`, `equity`)
- attendees-array equivalents (no `borrowed_by_users` jsonb mutable)
- lógica client-side de quién puede transferir
- asset monolith table
- stateful counters manuales (uso, mantenimientos, etc.)

---

## §26 — Resultado esperado

El sistema debe poder modelar:

- autos compartidos
- equipo de sonido
- palcos
- instrumentos
- herramientas
- llaves
- NFTs / equity / IP
- licencias
- documentos canónicos
- hardware
- inventarios (con `inventory` capability)
- bicicletas / proyectores / libros

**SIN crear nuevos resource types.**

---

## §27 — Backend reference (canónico al 2026-05-15)

| Pieza                            | Migración              | Detalle                                          |
|----------------------------------|------------------------|--------------------------------------------------|
| RPC `create_asset`               | `00168`                | Any-member create con `is_group_member` gate     |
| Atoms whitelist (12 nuevos)      | `00204`                | custody.* / maintenance.* / damage / usage / valuation / transfer |
| Capabilities (7 nuevos universales) | `00208`             | custody / maintenance / valuation / transfer / inventory / access (incomplete) / delegation (incomplete) |
| RPCs lifecycle (10)              | `00210`                | assign_custody / release_custody / log_maintenance / complete_maintenance / report_damage / record_valuation / transfer_asset / check_out_asset / check_in_asset / record_asset_usage |
| Projections (4 vistas)           | `00212`                | asset_current_custodian_view / asset_valuation_view / asset_maintenance_status_view / asset_usage_history_view |

### iOS surface

- Repo: `AssetLifecycleRepository` (10 funcs, Mock + Live)
- UI: secciones inline dentro de `UniversalResourceDetailView` — `AssetCustodySection` / `AssetOwnershipSection` / `AssetMaintenanceSection` en `Features/Resources/Detail/Sections/Asset/AssetSections.swift` (gated por capability flags)
- Wizard: `AssetResourceBuilder` (registrado en `AppState.resourceBuilders`, visible bajo categorías "Cosas compartidas" + "Custom")
- Routing: `ResourceDetailSheet` despacha **todos** los tipos al mismo `UniversalResourceDetailView`. El intento previo (`c5c6047`) de ramificar `.asset → AssetDetailView` se revirtió en `f9be934` cuando el refactor `b01f8fb` consolidó la página universal

---

## §28 — Definición final

### Asset

> Resource persistente con identidad propia que coordina custodia, uso, mantenimiento, valuación, transferencia y consecuencias mediante atoms append-only y projections derivadas, sin tabla propia ni status mutable como verdad primaria.

Ese es el modelo canónico de `asset` en Ruul.
