# Ruul — `fund` Resource Type (Canonical Specification)

**Status:** Canónico desde 2026-05-18. Founder directive.
**Companion of:** `Plans/Active/Constitution.md` (Artículo 2 — enum congelado; Artículo 11 — ledger es única verdad financiera), `Plans/Active/TalmudicGovernance.md` (8 principios cardinales), `Plans/Active/Asset.md` §21 (asset NO es fund — spec hermana), `Plans/Active/Space.md` (otra spec hermana), `Plans/Active/AtomProjection.md` (regla append-only), `Plans/Active/HierarchyReference.md` §2-3.
**Scope:** Define qué es `resources.resource_type = 'fund'` en Ruul, qué NO es, y cómo se modela. Toda decisión de implementación sobre `fund` consulta primero este documento.

> Ruul **NO** modela contabilidad tradicional, ni neobanking, ni Splitwise, ni gestor de gastos personal. Ruul modela coordinación social sobre **pools monetarios persistentes y gobernables** mediante `resources`, `capabilities`, `rules`, `atoms` (ledger_entries) y `projections` (balances). Un `fund` **NO** es solamente "un saldo" ni "una cuenta bancaria". Un `fund` es el **resource persistente** que coordina **propósito, autoridad y consecuencias** sobre dinero compartido — distinto de `ledger_entry` (que es el atom de movimiento) y distinto de `asset` (cuya coordinación es custody/valuation/transfer, no liquidez).

---

## §1 — Definición ontológica

Un `fund` es:

> Un pool monetario persistente con identidad propia y lifecycle independiente, sobre el cual un grupo coordina aportaciones, gastos, autoridad de uso, metas, transferencias y consecuencias mediante reglas. El balance es derivado del ledger; el fund existe **entre** los movimientos.

Un `fund` puede representar:

- cochinito / kitty / chanda
- caja chica
- presupuesto de evento (viaje, boda, fiesta)
- fondo de mantenimiento (palco, casa, vehículo)
- fondo de emergencia
- tanda / ROSCA / hui
- pool de contribuciones para un objetivo (regalo, equipo, herramienta)
- fondo de operación recurrente (cuotas mensuales)
- treasury de comunidad o asociación
- escrow simple
- jackpot de juego/concurso del grupo

---

## §2 — Principio cardinal

```
fund = pool monetario persistente y gobernable
```

**NO:**

```
fund = ledger entry           (entry es el movimiento, fund es el contenedor)
fund = cuenta bancaria         (fund es scope social, no infraestructura financiera)
fund = balance                 (balance es projection sobre entries)
fund = "el dinero del grupo"   (group puede tener N funds con propósitos distintos)
```

La diferencia es enorme. Un fund es **continuo** — existe entre los actos de aportación/gasto. Los movimientos lo **alimentan o consumen**, las reglas lo **gobiernan**, los rights le **dan autoridad de uso**. La verdad financiera vive en `ledger_entries` (atoms append-only); el balance se **deriva** vía `fund_balance_view`. Constitution Artículo 11 es ley.

---

## §3 — `fund` NO es

| Esto | Pertenece a | Por qué |
|------|-------------|---------|
| Aportación (contribution) | `ledger_entries` (atom) | Movimiento, no contenedor |
| Gasto (expense) | `ledger_entries` (atom) | Movimiento, no contenedor |
| Settlement / pago entre miembros | `ledger_entries` | Atom de cierre de cuenta |
| Multa | `ledger_entries` + `fines_view` | Instrument derivado del atom |
| Saldo / balance actual | `fund_balance_view` (projection) | Cálculo, no entidad |
| Cuenta bancaria real | Infrastructure (Stripe/MX banks) | Out of scope V1 — fund es scope social |
| Wallet personal de un miembro | (no existe) | Member balance vive en `balances_view` polimorphic |
| Activo (palco, equipo, NFT) | `asset` | Custody/valuation, no liquidez |
| Acceso al fund | `right` o `group_policies` | Entitlement layer, distinto del scope |

---

## §4 — Relación con otras entidades (multi-layer doctrine)

Como con Asset/Space (ver Space.md §3 sobre layers), fund interactúa con otros resources sin reemplazarlos:

```
ASSET                        FUND                       SPACE
50% Palco        ←─owns─    Fondo Palco    ─funds_maintenance_of→    Palco
(ownership)                  (liquidez)                 (operación)
                                ↑
                                │ contributes_to
                                │
                            MEMBER (vía ledger_entries)
                                │
                                │ exercises
                                ↓
                            RIGHT
                            "Tesorero" (entitlement de aprobar gastos)
```

### Fund puede gobernar

- contribuciones (quién/cuánto/cuándo)
- gastos (autoridad, threshold, approval)
- payouts/settlement entre miembros
- meta (target_amount + projection de progreso)
- lock (admin bloquea write activity)

### Fund puede usar

- rules (governance específica del fund)
- rights (tesorero, comité, derecho de veto)
- voting (decisiones sobre gastos grandes)
- ledger (es su único storage — fund NO tiene tabla propia)

### Fund puede generar

- atoms (`fundCreated`, `fundDeposit`, `fundThresholdReached`, `fundLocked`, `fundUnlocked`, + indirectamente `ledgerEntryCreated`)
- obligations (multas con `resource_id = fund_id`)
- balance projection
- contribución requerida (vía rule, e.g. cuota mensual)
- consequence cascade (cuando se llega a la meta, abrir vote para liberar)

### Relaciones universales (vía `resource_links`)

```
fund    --funds_maintenance_of--> asset    (fondo mantenimiento → palco)
fund    --funds_maintenance_of--> space    (fondo limpieza → coworking)
fund    --funds--> event                   (fondo de la boda → boda)
asset   --owns--> fund                     (composite ownership — raro pero válido)
right   --grants_authority_over--> fund    (tesorero → fondo común)
event   --collects_into--> fund            (cuotas del partido → kitty)
```

---

## §5 — Ejemplos canónicos

### Caso 1 — Cochinito de viaje familiar

**Resource:** `fund: Viaje a Cancún 2027`

**Capabilities:**
```
money, ledger, rules, voting, status, description, history
```

**Rules:**
```
aportación mensual de $5,000 por miembro → cron emite fineOfficialized si no se aporta
gasto > $20,000 → require approval del consejo
balance >= target → emit warning "Meta alcanzada, libera el siguiente paso"
```

**Atoms:**
```
fundCreated (Maria creó el fondo, target=$200,000 MXN)
fundDeposit (Jose aportó $5,000) — via ledger_entries trigger
fundDeposit (Maria aportó $5,000)
ledgerEntryCreated (gasto $3,000 al hotel)
fundThresholdReached (cuando in_cents ≥ target_amount_cents)
fundLocked (admin pausa contribuciones — viaje pagado completo)
```

### Caso 2 — Tanda mensual (ROSCA)

**Resource:** `fund: Tanda Marzo 2027`

**Capabilities:**
```
money, ledger, rules, rotation, voting
```

**Rules:**
```
aportación fija de $X por miembro / mes
payout rotativo por turn_order
si miembro no aporta → fine + skip turno
```

### Caso 3 — Fondo común del palco

**Resource:** `fund: Mantenimiento Palco Mundial`

Linked a:
- `space: Palco Mundial` via `funds_maintenance_of`
- `asset: 50% Palco Mundial` via opcional ownership (founder decide)

**Capabilities:** `money, ledger, rules, voting, access`

**Rules:**
```
gasto > 10% del balance → require vote 2/3
solo tesoreros pueden registrar gastos (vía right grants_authority_over)
balance < $20,000 → emit warning de bajo saldo
```

### Caso 4 — Caja de emergencia comunitaria

**Resource:** `fund: Emergencia Vecinal`

Cualquier vecino aporta voluntariamente; gastos requieren approval del consejo.

### Caso 5 — Treasury de asociación civil

**Resource:** `fund: Treasury Asociación X`

Multi-currency (MXN + USD), gobernanza por roles, locked por default (solo tesorero puede mover).

---

## §6 — Fund NO es occurrence

Igual que asset/space: un fund **persiste continuamente** hasta que se archiva. Los movimientos lo alimentan/consumen pero el fund existe entre ellos. No hay "instancias" de un fund — un viaje cancelado se archiva, no se borra.

Si necesitas "el dinero del viaje del 2027", eso es:
- un `fund` con `metadata.purpose = 'viaje_2027'`, o
- un `event scheduled_in <fecha>` + `fund collects_into event` link (más rica)

---

## §7 — Fund NO debe ser mutable como inventory row

**NO hacer:**

```sql
UPDATE resources
SET balance_cents = 50000, contribution_count = 12, last_deposit_at = now()
WHERE resource_type = 'fund'
```

El balance, los contadores, la última actividad **se derivan** de `ledger_entries` vía `fund_balance_view`.

### Excepción de display permitida (con doctrina)

`resources.metadata.currency` es config (declarativa, no derivada — el founder elige al crear).
`resources.metadata.target_amount_cents` es config (meta declarada).

Ambas son **declarativas**, no estado mutable derivado. Estas son legítimas en metadata.

### ⚠️ Known Issue: lock state in metadata

`fund_lock` (mig 00202) stampea `locked_at`, `locked_by`, `locked_reason` en `resources.metadata`. **Esto viola TalmudicGovernance §4.A (Acto > Estado)**: el lock debería derivarse de los atoms `fundLocked` / `fundUnlocked` que ya existen, NO persistirse como estado mutable en metadata.

**Remediación canónica** (futuro slice):

```sql
-- En vez de UPDATE resources.metadata SET locked_at = now()
-- Solo emit fundLocked atom.
-- fund_balance_view deriva is_locked vía:
--   EXISTS (latest fundLocked atom for fund_id)
--   AND NOT EXISTS (later fundUnlocked atom for same fund_id)
```

El display shortcut acceptable (per §7.b general rule) es OK si el atom siempre se emite *junto* y el atom es la fuente; lock actual no cumple porque la verificación lee metadata, no atoms. Migración futura debe invertir la dependencia.

---

## §8 — Atoms relacionados

### Atoms canónicos (mig 00139 + 00140 + 00141 + 00203)

```
fundCreated          — fund resource lands. Payload: {name, target_amount_cents?, currency?}
fundDeposit          — TRIGGER emit when ledger_entries.type='contribution' INSERT en
                       un fund. Payload: {amount_cents, currency, from_member_id, fund_resource_id}
fundThresholdReached — TRIGGER emit cuando in_cents acumulado ≥ target_amount_cents
                       (per currency, once-per-fund dedupe). Payload: {fund_resource_id,
                       target_amount_cents, accumulated_cents, currency}
fundLocked           — admin pausa el fund. Payload: {locked_by, locked_reason}
fundUnlocked         — admin reactiva. Payload: {unlocked_by, previous_locked_at}
```

### Atoms compartidos (no duplicados)

```
ledgerEntryCreated   — mig 00193 trigger, fires on EVERY ledger_entries INSERT.
                        Fund consumes este atom indirectamente vía rule engine.
resourceArchived     — mig 00186 generic, fund usa el mismo
resourceUnarchived
resourceRenamed
resourceLinked       — cuando fund se vincula a asset/space/event
resourceUnlinked
warningEmitted       — emit-warning consequence sobre fund balance bajo / threshold reached
```

Todos `INSERT ONLY` sobre `system_events` / `ledger_entries`, protegidos por guards (mig 00103, 00162, 00163).

---

## §9 — Projections derivadas (mig 00203)

Fund deriva projections — **nunca** persiste verdad independiente.

### `fund_balance_view`

```
fund_id, group_id, name, target_amount_cents, currency,
in_cents, out_cents, balance_cents (in − out),
contribution_count, expense_count, last_activity_at,
locked_at, locked_reason, archived_at, created_at
```

Per-fund, **per-currency**. Un fund con activity multi-currency devuelve N rows (una por currency); fund sin movimientos devuelve 1 row con currency declarada.

`security_invoker = on` — RLS sobre `resources` + `ledger_entries` aplica.

### Futuras (cuando demand-pull lo pida)

```
fund_member_balance_view    — quién aportó cuánto, neto por miembro
fund_obligation_view        — cuotas pendientes por miembro (cuando llegue rule template)
fund_velocity_view          — in/out por window (semana/mes), trend de salud
fund_authority_view         — quién tiene right activo sobre el fund (tesorero, comité)
```

---

## §10 — Fund como centro de governance

Rules pueden aplicar:

- al grupo entero (default policy: todos pueden contribuir)
- al `resource_type='fund'` global (e.g., todo fund > $50k requires monthly audit)
- a un fund específico (resource-scoped: este fund solo acepta MXN)
- a una capability sobre fund (e.g., todos los expense actions del grupo)

### Precedencia

```
resource > resource_type > group > global
```

Igual que event/asset/space §10-§11.

### Engine

Server-only, determinístico, sobre `system_events` + `ledger_entries`. El `event_type` discrimina (`fundDeposit`, `fundThresholdReached`, `ledgerEntryCreated` con `payload.resource_id` = fund_id).

---

## §11 — Fund puede tener rights

Ejemplos:

- "Tesorero" right → `grants_authority_over` fund (puede registrar gastos sin approval)
- "Auditor" right → `grants_read_access_to` fund metadata + history
- "Miembro contribuyente" right → bypass cuota mínima (override de la rule de cuotas)
- "Veto sobre gastos > $X" right → require su explicit approval

`rights` polimorphic con `target_resource_id = fund_id`. Mismos patterns que asset (§11) o space (§13).

---

## §12 — Fund puede tener workflows

Ejemplos:

- approval para gastos > threshold (vote 2/3, mig 00194 expense_threshold_vote)
- vote para liberar payout cuando se alcanza la meta
- appeal sobre multa por cuota no pagada
- delegation temporal de autoridad de tesorero
- audit programada (cron emite event → workflow de revisión)

Workflows viven en `votes` / `user_actions` / `appeals` polimórficos con `reference_id` = fund_id.

---

## §13 — Lock semantics (con known issue flag)

`fund_lock` es soft policy admin-only (mig 00202):

- Llama `fund_lock(p_fund_id, p_reason?)` → emite `fundLocked`
- Constitution §9: **el RPC NO bloquea writers**. Las rules + UI react al flag.
- Sirve para "pause" — bloquear nuevas contribuciones/gastos mientras se reorganiza.

**Doctrina**: lock es metadata cache **+** atom emit. La verdad debería ser atom; metadata es shortcut. Hoy `fund_balance_view` lee metadata directamente (KNOWN ISSUE §7). Remediación: invertir dependencia en migración futura.

---

## §14 — Fund como unidad social primaria

Muchas preguntas del usuario son sobre funds:

- "¿Cuánto hay en el fondo del viaje?"
- "¿Quién no ha aportado este mes?"
- "¿Quién aprobó ese gasto?"
- "¿En qué se va el dinero?"
- "¿Cuándo alcanzamos la meta?"
- "¿Quién es el tesorero?"
- "¿Por qué está bloqueado el fondo?"
- "¿Cuánto debo al grupo?"

---

## §15 — Arquitectura de datos

Fund vive en:

```
resources.resource_type = 'fund'
```

**NO crear:** una tabla `funds` separada. **NO crear:** subtype tables (`travel_funds`, `treasuries`, `tandas`). Toda diferencia entre tipos de fund vive en `metadata` (jsonb) + capabilities activadas + rules + linked rights.

Las tablas de financial truth (`ledger_entries`, `fund_balance_view`) son **compartidas polimórficamente** — no hay tabla especial de "fund_ledger".

---

## §16 — Fund capabilities

Catálogo aplicable (mig 00165 + 00207 + 00265):

| Capability      | Significado                                                | Status     |
|-----------------|------------------------------------------------------------|------------|
| `money`         | El fund maneja dinero (gate básico, todos los funds)        | stable     |
| `ledger`        | Asientos contables atómicos en `ledger_entries`            | stable     |
| `voting`        | Decisiones colectivas (expense > threshold)                | stable     |
| `rules`         | Governance específica del fund                              | stable     |
| `status`        | Lifecycle display (active/locked/archived)                 | stable     |
| `description`   | Texto libre + propósito                                     | stable     |
| `history`       | Feed cronológico de atoms                                   | stable     |
| `valuation`     | Para funds con activos non-cash (NFT/equity en treasury)   | stable (asset shared) |
| `access`        | Gate explícito de quién puede operar (admin/tesorero)      | stable (asset shared) |
| `recurrence`    | Cuotas recurrentes (rule template)                          | stable     |
| `rotation`      | Tandas: payout rotativo                                     | stable     |
| `consequence`   | Multas por no aportar                                       | incomplete |
| `appeal`        | Apelación de multas/exclusiones                             | stable     |
| `approval`      | Workflow de aprobación de gastos                            | incomplete |

`money` + `ledger` son fund-defining (un fund sin ledger no es fund — es metadata muerta).

---

## §17 — Fund lifecycle

### Estados reales NO mutables

**NO usar:**
```
status = "funded"
status = "empty"
status = "active"
```

como verdad primaria.

La realidad se **deriva** de atoms.

### Ejemplo

```
fundCreated → existe
fundDeposit (Maria $5k) → balance = 5000
fundDeposit (Jose $5k) → balance = 10000
ledgerEntryCreated (gasto -$3k) → balance = 7000
fundThresholdReached (cuando in ≥ target) → meta alcanzada (atom único)
fundLocked → admin pausa
fundUnlocked → admin reactiva
resourceArchived → fin de vida
```

→ projections derivan:
```
balance_cents
contribution_count
expense_count
is_locked (KNOWN ISSUE: hoy lee metadata; debería derivar de atoms)
target_progress (in_cents / target_amount_cents)
is_archived
```

---

## §18 — Fund governance — rule templates canónicos

Ejemplos (no exhaustivo, follow-up en `Plans/Active/FundRules.md` cuando aterrice):

```
si gasto > 10% del balance              → vote 2/3
si gasto > $X (threshold)               → vote (mig 00194 expense_threshold_vote)
si miembro no aporta cuota mensual      → fine
si balance < umbral                     → emit warning "saldo bajo"
si meta alcanzada                       → emit warning "siguiente paso"
si meta no alcanzada en N días          → vote para extender/ajustar
si lock activo + INSERT contribución    → deny (rule, no RPC gate)
```

Cada template es `WHEN <atom> → IF <conditions> → THEN <consequences>` server-side. Mig 00193 + 00194 ya shippean expense_threshold_warning + expense_threshold_vote.

---

## §19 — Fund NO es event

**Event:** ocurrencia temporal coordinada (la cena).
**Fund:** pool monetario persistente (el cochinito).

Un event puede `collects_into` un fund (cuotas del partido → kitty). Un fund puede `funds` un event (presupuesto de la boda → boda). No son el mismo primitive.

---

## §20 — Fund NO es asset / space / slot / right

**Asset:** custody + valuation + transfer de objetos persistentes.
**Space:** ocupación / capacidad de lugares.
**Slot:** partición atómica de tiempo/cupo.
**Right:** entitlement normativo de acceso/uso.
**Fund:** liquidez compartida.

Un fund **puede ser ownership de un asset** (NFT en treasury) o **fundear un space** (mantenimiento del palco), pero nunca los **reemplaza**. Estos son layers complementarios (TalmudicGovernance §4.H).

---

## §21 — Fund NO es ledger entry

**Ledger entry:** atom de movimiento (acto financiero).
**Fund:** scope persistente bajo el cual los movimientos viven.

Constitution §11: **el ledger es la única verdad financiera**. El fund es el "namespace" social que agrupa entries con `resource_id = fund_id`. Borrar el fund (archive) no borra los entries — la historia financiera persiste.

Un grupo SIN funds puede aún tener ledger_entries (con `resource_id = group_id` o = event_id), pero pierde scoping social y governance específica de pool. Funds son cómo el grupo da "propósito" al dinero.

---

## §22 — UI/UX correcto

La UI debe sentirse como:

> "Todo lo relacionado a este pool del grupo"

**NO** como:
- balance app plana
- Splitwise clone (split tracking sin scope social)
- ERP financiero
- spreadsheet exportada

### Doctrina actual: universal frame inline-sections

Fund renderiza dentro de `UniversalResourceDetailView`, igual que event/asset/space/slot/right.

### Secciones fund-específicas

Cuando `resource_type='fund'` y la capability está activa:

| Sección                  | Capability     | Proyección base                |
|--------------------------|----------------|--------------------------------|
| `FundBalanceSection`     | `money` (always) | `fund_balance_view`           |
| Money / contribute       | `money`        | `ContributeToFundSheet` modal  |
| Money / expense          | `money`        | `RecordExpenseFromFundSheet`   |
| Lock toggle              | admin-only     | `fund_lock` / `fund_unlock`    |
| Rules / Activity         | `rules` / `history` | shared sections           |

### Lo que el usuario debe ver

```
INFORMACIÓN
$45,000 / $200,000 MXN
22% hacia la meta
12 aportaciones · 3 gastos · última actividad hace 2h

CONTRIBUYENTES
Maria $15,000 · Jose $15,000 · Daniel $10,000 · Alan $5,000

REGLAS
Cuotas mensuales de $5,000
Gastos > $10,000 requieren voto

ACTIVIDAD
Hace 2h: Maria aportó $5,000
Hace 1d: Gasto de $3,000 al hotel (Jose, aprobado)
```

**NO** debe ver: `payload`, `event_type=fundDeposit`, `ledger_entries.type='contribution'`, `cents`, JSON.

---

## §23 — Fund y atoms

El fund es una **agregación social persistente**. Los ledger_entries + system_events son la **verdad histórica**.

```
fundCreated
fundDeposit (Maria)
fundDeposit (Jose)
ledgerEntryCreated (gasto)
fundThresholdReached
fundLocked
        ↓
fund_balance_view (in − out + counts + lifecycle state)
```

---

## §24 — Filosofía Talmúdica / legal

La ley **no** gobierna "dinero" como sustancia. Gobierna:

- propósito (para qué se separa este pool)
- autoridad (quién puede mover el dinero)
- contribución (deber u opcionalidad de aportar)
- consecuencia (qué pasa si no aportas)
- transferencia (cuándo y a quién se libera)
- custodia financiera (tesorería con responsabilidad)
- audit (memoria del flow)

Ruul modela exactamente eso. El `fund` es el **recipiente persistente** de propósito; los `ledger_entries` son los actos; las `rules` son las consecuencias; los `rights` son la autoridad delegada.

---

## §25 — Decisiones NO negociables

### Sí

- funds como resources polimórficos (no tabla propia)
- ledger_entries como atom append-only único
- balance como projection derivada
- governance sobre funds (resource-scoped + heredada)
- multi-currency soportado (1 row per (fund, currency))
- capabilities universales reutilizadas
- target_amount como soft goal (no hard cap), declarativo en metadata
- currency en metadata (declarativo)

### No

- tabla `funds` paralela
- `fund_ledger_entries` paralela a `ledger_entries`
- mutable balance counters (`balance_cents` UPDATE)
- subtype tables (`travel_funds`, `tandas`, `treasuries`)
- "fund auto-aprueba si autorizado" — todo gasto deja atom
- saldo cacheado fuera de la projection
- soft delete de ledger_entries (atom es eterno)

---

## §26 — Resultado esperado

El sistema debe poder modelar:

- viajes con cochinito
- tandas / ROSCAs
- fondos de mantenimiento (palco, casa, vehículo)
- treasuries de asociaciones
- caja chica / emergencia
- presupuestos de eventos (boda, fiesta)
- pools de regalo grupal
- cuotas mensuales recurrentes
- multi-currency funds (treasury internacional)
- escrow simple

**SIN crear nuevos resource types** y **SIN inventar tabla financiera nueva**.

---

## §27 — Backend reference (canónico al 2026-05-18)

| Pieza                                | Migración              | Detalle                                                  |
|--------------------------------------|------------------------|----------------------------------------------------------|
| RPC `create_fund`                    | `00139`                | Any-member create. Stamps name/target/currency in metadata. |
| Trigger `fundDeposit` emit           | `00140`                | On `ledger_entries INSERT WHERE type='contribution'` |
| Trigger `fundThresholdReached` emit  | `00141`                | Extension del 00140 — fires once cuando in_cents ≥ target |
| `build_resource_from_draft` (fund)   | `00139`                | Wizard atomic submit                                     |
| RPCs writers + lifecycle (4)         | `00203`                | fund_contribute / fund_record_expense / fund_lock / fund_unlock |
| `fund_balance_view` projection       | `00203`                | Per-fund per-currency. security_invoker=on.              |
| Whitelist atoms (5)                  | `00139` + `00203`      | fundCreated / fundDeposit / fundThresholdReached / fundLocked / fundUnlocked |
| `expense_threshold_warning_pilot`    | `00193`                | Rule template para gastos grandes (mig 00193)            |
| `expense_threshold_vote`             | `00194`                | Rule template para vote sobre gasto                      |
| `ledger_review_finalize_vote`        | `00195`                | Finalize vote handler para expense reviews               |
| `ledger_review_notify_member`        | `00196`                | Notify member when expense vote resolves                 |

### iOS surface

- Model: `Fund` (`PlatformModels/Fund.swift`) — projection struct (Codable). Composite id = (fundId, currency) per fund_balance_view row.
- Repo: `FundRepository` (Mock + Live) con 5 funcs: listForGroup / get / contribute / recordExpense / lock / unlock
- UI: secciones inline dentro de `UniversalResourceDetailView`:
  - `FundBalanceSection` (siempre cuando .fund) — `Features/Resources/Detail/Sections/FundBalanceSection.swift`
  - `ContributeToFundSheet` + `RecordExpenseFromFundSheet` — modales bajo `Features/Resources/Detail/Sections/`
- Wizard: `FundResourceBuilder` (Capabilities/FundResourceBuilder.swift) — required: name. Optional: targetAmountCents. Auto: money + ledger + voting + rules.
- Tests: `FundRepositoryTests.swift` (5 tests para mock)

---

## §28 — Definición final

### Fund

> Resource persistente con identidad propia que coordina aportaciones, gastos, autoridad de uso y consecuencias sobre dinero compartido del grupo, sin tabla propia ni balance mutable como verdad primaria. Distinto de `ledger_entry` (movimiento), distinto de `asset` (objeto), distinto de `right` (autoridad), distinto de `event` (occurrence).

Ese es el modelo canónico de `fund` en Ruul.

---

## §29 — Definition of Done

Fund.md está canónico cuando:

- [x] Definición ontológica + cardinal principle + qué NO es
- [x] Multi-layer doctrine (relación con asset/space/right/event vía resource_links)
- [x] 5+ ejemplos canónicos (viaje, tanda, palco, emergencia, treasury)
- [x] Atoms documentados (5 fund.* + 1 ledgerEntryCreated shared)
- [x] Projection `fund_balance_view` documentada con columnas + derivación
- [x] Lifecycle (created → active → locked → archived) sin mutable status
- [x] Rule templates listados (expense_threshold_warning / vote, cuota recurrente)
- [x] Capabilities listadas con status (stable/incomplete)
- [x] UI sections documentadas (FundBalanceSection + sheets) sin conflar capability con surface
- [x] Backend reference table
- [x] TalmudicGovernance §4 audit — 7/8 pass, 1 KNOWN ISSUE flagged (lock metadata)
- [x] Definición final one-sentence
- [ ] **REMEDIATION SLICE**: invertir dependencia lock_at en `fund_balance_view` para leer atoms en vez de metadata (cierra §4.A violation)
- [ ] `FundRules.md` companion (mirror de AssetRules.md / SpaceRules.md) cuando llegue su demand-pull

---

## §30 — Known Issues (canonical doctrine debt)

### #1 — Lock state lives in metadata (§4.A violation)

**Síntoma:** `fund_lock` UPDATE-a `resources.metadata` con `locked_at`, `locked_by`, `locked_reason`. `fund_balance_view` lee `metadata->>'locked_at'` para derivar `is_locked`. Esto es mutable state pretendiendo ser projection.

**Doctrina violada:** TalmudicGovernance §4.A (Acto > Estado). Constitution §8 (projections derived from atoms, nothing persisted independently).

**Estado actual:** Tolerado (atoms `fundLocked`/`fundUnlocked` también se emiten, así que el atom es la verdad; metadata es solo display cache acompañante). Pero `fund_balance_view` rompe la doctrina al leer metadata como fuente.

**Remediación canónica:** Mig futura — refactor `fund_balance_view` para derivar `is_locked` de:

```sql
locked_at as (
  select se.resource_id as fund_id, se.occurred_at as locked_at,
         se.payload->>'locked_reason' as locked_reason
  from public.system_events se
  where se.event_type = 'fundLocked'
    and not exists (
      select 1 from public.system_events s2
      where s2.event_type = 'fundUnlocked'
        and s2.resource_id = se.resource_id
        and s2.occurred_at > se.occurred_at
    )
)
```

`fund_lock` deja de stampar metadata; emit atom es suficiente.

**Why deferred:** Touch surface incluye iOS consumers (Fund.swift decoding, FundBalanceSection rendering). Ship el spec primero, refactor en slice dedicado con tests.

### #2 — No `FundRules.md` companion

**Síntoma:** Asset tiene AssetRules.md; Space tiene SpaceRules.md; Fund no tiene FundRules.md a pesar de tener 2 rule templates ya shipped (expense_threshold_warning + expense_threshold_vote mig 00193-00194).

**Remediación:** Mirror del shape de SpaceRules.md cuando el siguiente template tenga demand-pull (e.g., cuota recurrente).
