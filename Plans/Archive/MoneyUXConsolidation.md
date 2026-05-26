# Money UX Consolidation — Plan & User Journeys

**Status**: ACTIVE 2026-05-24
**Trigger**: Founder feedback "en dinero siento todavía muy confuso. no puedo ver la lista de transacciones. no tengo el smart settlement todavía. aparte no estoy seguro de cómo dinero se relaciona con todos los demás resources."
**Follow-up**: "porque tenemos dos vistas diferentes para el fondo compartido y para los otros fondos?"

---

## TL;DR

Hoy hay **3 modelos mentales** de dinero y **5 sheets** que hacen variantes del mismo `INSERT INTO ledger_entries`:

| Model | Sheets | RPC |
|---|---|---|
| Shared pool (Phase 3 canonical) | ContributeToSharedMoneySheet · RecordSharedExpenseSheet | `contribute_to_shared_money` · `record_shared_expense` |
| Protected/Legacy fund | ContributeToFundSheet · RecordExpenseFromFundSheet | `fund_contribute` · `fund_record_expense` |
| Per-resource ledger | AddLedgerEntryDestination | `record_ledger_entry` |

**Por qué hay dos vistas distintas hoy**: `SharedMoneyCard` muestra el shared pool. `GroupFundsListView` muestra todos los demás (`fundId != sharedPoolId`). Filtros opuestos sobre la misma tabla. Phase 3 (shared) se lanzó sin retirar el flow legacy de funds, y la UX no se consolidó.

**Plan**: 6 PRs incrementales para llegar a 1 hub + 1 sheet universal. Empezamos con el más visible (embeber otros fondos en el hub).

---

## 1. Inventario actual de superficies

| # | Surface | Path | Mounts | Purpose |
|---|---|---|---|---|
| 1 | `SharedMoneyCard` | `Features/Group/Components/` | Inline en `GroupSpaceView` | Saldo shared pool + CTAs Aportar/Gastar + acceso al hub |
| 2 | `GroupBalancesView` ("Dinero del grupo") | `Features/Group/Subscreens/` | Push desde card | Balances por miembro + Liquidar + Movimientos recientes + footer Otros fondos |
| 3 | `GroupFundsListView` | `Features/Group/Subscreens/` | Push desde footer del hub | Lista de fondos protegidos/legacy + Crear fondo |
| 4 | `ResourceDetailSheet` (fund variant) | `Features/Resources/` | Push desde lista | Detalle polimórfico — fund detail tiene su propio money section |
| 5 | `ResourceMoneySlot` | `Features/Resources/Detail/Slots/` | Inline en ResourceDetail (asset/event/fund) | "Dinero del recurso" + CTAs (mismas que SharedMoneyCard pero con `sourceResource`) |
| 6 | `ContributeToSharedMoneySheet` | `Features/Group/Sheets/` | Sheet desde card/slot | Form de aporte (Phase 3, canonical) |
| 7 | `RecordSharedExpenseSheet` | `Features/Group/Sheets/` | Sheet desde card/slot | Form de gasto con split picker (Phase 4 mig 00370) |
| 8 | `ContributeToFundSheet` | `Features/Resources/Detail/Sections/` | Sheet desde fund detail | Legacy form de aporte directo a fund |
| 9 | `RecordExpenseFromFundSheet` | `Features/Resources/Detail/Sections/` | Sheet desde fund detail | Legacy form de gasto directo de fund |
| 10 | `AddLedgerEntryDestination` | `Features/Resources/Sheets/Money/` | Sheet desde resource detail (ledger button) | Polymorphic ledger entry creation (4 kinds) |
| 11 | `SettlementSheet` | `Features/Resources/Detail/Sections/` | Sheet desde hub suggestion / slot | Single settlement between two members |

**Total**: 11 superficies. 6 son sheets de creación. 2 son list views (hub + funds). 3 son inline blocks (card + slot + slot variant).

---

## 2. Inventario de acciones del usuario (12 acciones)

| # | Acción | Surface(s) | RPC | Clicks |
|---|---|---|---|---|
| 1 | Aportar al dinero compartido del grupo | SharedMoneyCard | `contribute_to_shared_money` | 2 |
| 2 | Aportar a un recurso específico (asset/event) | ResourceMoneySlot | `contribute_to_shared_money(sourceResourceId)` | 3 |
| 3 | Aportar en especie (in-kind) | ContributeToSharedMoneySheet toggle | `contribute_to_shared_money(inKind=true)` + valuation sync | 3 |
| 4 | Aportar a fondo protegido | ContributeToFundSheet (legacy) | `fund_contribute` | 4 |
| 5 | Registrar gasto compartido (sin split) | RecordSharedExpenseSheet | `record_shared_expense` | 2 |
| 6 | Registrar gasto compartido con split (equal/exact/percent/shares) | RecordSharedExpenseSheet mode picker | `record_shared_expense(splitMode, splitBreakdown)` | 2-3 |
| 7 | Registrar gasto de fondo protegido | RecordExpenseFromFundSheet (legacy) | `fund_record_expense` | 4 |
| 8 | Liquidar (settle up) sugerido | GroupBalancesView "Liquidar ahora" | `record_settlement` (vía sheet pre-filled) | 3 |
| 9 | Liquidar (settle up) manual | SettlementSheet | `record_settlement` | 3 |
| 10 | Ver lista de transacciones del grupo | GroupBalancesView "Movimientos recientes" | (read-only `list(groupId)`) | 2 |
| 11 | Ver lista de fondos protegidos | GroupFundsListView | (read-only `listForGroup`) | 3 |
| 12 | Crear fondo protegido | GroupFundsListView FAB | resource creation wizard | 4+ |
| 13 | Reversar movimiento | Activity feed context menu | `reverse_ledger_entry` | 4+ |
| 14 | Editar nota de movimiento | Activity feed context menu | `update_ledger_entry_note` | 4+ |

---

## 3. User Journeys click-por-click

### J1 — Aportar al dinero compartido (golden path)

**Pre**: Group existe, user is member, shared pool inicializado.

1. Group Home → ver `SharedMoneyCard` (siempre visible)
2. Tap "Aportar" → `ContributeToSharedMoneySheet` aparece (sheet, medium detent)
3. Type monto (NumberPad)
4. (opcional) Type nota
5. Tap "Aportar" → submit + dismiss
6. SharedMoneyCard recarga con nuevo balance

**Clicks**: 2 (1 surface + 1 submit) · **Input**: 1-2 fields · **Friction**: minimal

---

### J2 — Aportar a un activo específico (in-kind capital)

**Pre**: Activo existe (terreno, equipo), user navega al detail.

1. Group Home → tile "Activos" → tap → lista
2. Tap activo → `ResourceDetailSheet`
3. Scroll a `ResourceMoneySlot` ("Dinero del recurso")
4. Tap "Aportar" → `ContributeToSharedMoneySheet(sourceResource=asset)`
5. Ver label "Para {asset.name}"
6. (opcional) Toggle "Aporte en especie" → monto se prefilla con última valuación
7. Modify monto si quieres / type nota
8. Tap "Aportar" → submit. Stamps `source_resource_id`, `in_kind=true`, sync `record_valuation`

**Clicks**: 4 + toggle · **Input**: monto + nota · **Friction**: low (prefill reduce typing)

---

### J3 — Registrar gasto compartido con split equal

**Pre**: Group con 3+ miembros, shared pool.

1. Group Home → SharedMoneyCard → tap "Registrar gasto"
2. `RecordSharedExpenseSheet` aparece
3. Picker "¿Quién pagó?" → default = current user; switch si alguien más
4. Type monto
5. Segmented "Cómo dividir" → tap "Igualmente" (default)
6. Toggles "Dividir entre" → selecciona participantes
7. Footer muestra "N personas · cada una $X" (validación passes)
8. (opcional) Type nota
9. Tap "Registrar"

**Clicks**: 2 + 3-4 inputs · **Friction**: medium (4 selecciones distintas)

---

### J4 — Registrar gasto con split por porcentaje

Igual que J3 pero step 5 → "Por %", step 6 → typear % por miembro hasta llegar a 100%. Footer valida "Suman 100% ✓" antes de enable submit.

**Clicks**: 2 + 5 inputs (payer + amount + mode + 3 percentages) · **Friction**: high

---

### J5 — Liquidar deuda (settle suggested)

**Pre**: Group con balances no settled.

1. Group Home → SharedMoneyCard
2. Tap strip "Te deben $500" → `GroupBalancesView`
3. Scroll a "Liquidar ahora"
4. Tap row "Pagale a Daniel — $500" → `SettlementSheet` pre-filled
5. (opcional) Type nota
6. Tap "Registrar"

**Clicks**: 3 · **Input**: nota opcional · **Friction**: low (todo prefilled)

---

### J6 — Ver historial de movimientos del grupo

1. Group Home → SharedMoneyCard → tap "Ver dinero del grupo" (o strip)
2. Scroll a "Movimientos recientes" — 15 last entries
3. Cada row: tipo + monto + "Para X" si applicable + "Compartido entre N" si split

**Clicks**: 2 · **Friction**: none (read-only)

---

### J7 — Crear fondo protegido (legacy)

**Pre**: User tiene permiso `modifyGovernance`.

1. Group Home → SharedMoneyCard → tap "Ver dinero del grupo" → `GroupBalancesView`
2. Scroll a "Otros fondos" footer → tap → `GroupFundsListView`
3. Tap toolbar "+" (o CTA empty state "Crear fondo")
4. ResourceCreationSheet aparece — type "Fondo viaje"
5. Submit
6. Fund aparece en lista

**Clicks**: 4 + creation form · **Friction**: HIGH — requiere 3 screens antes del form

> **Esto es exactamente la duplicación que el founder llama "dos vistas".**
> Camino: SharedMoneyCard → GroupBalancesView → GroupFundsListView. 3 niveles para gestionar fondos.

---

### J8 — Aportar/gastar en fondo protegido

1. (luego de J7) Tap fund row en GroupFundsListView → ResourceDetailSheet(fund)
2. Scroll a money section → "Aportar" → `ContributeToFundSheet` (DIFERENTE del shared sheet)
3. Form simpler que el shared (sin in-kind toggle, sin sourceResource)
4. Submit

**Clicks**: 5 desde group home · **Friction**: HIGH

---

### J9 — Reversar un movimiento (típico para corregir errores)

1. Group Home → SharedMoneyCard → "Ver dinero del grupo" → `GroupBalancesView`
2. Scroll a "Movimientos recientes" — encuentra la entrada
3. (HOY: no tap; el reverse vive solo en Activity feed con context menu)
4. Cambia a Tab Inicio → Activity feed → context-menu en la entry → "Revertir operación"

**Clicks**: 5+ · **Friction**: VERY HIGH — el flow está roto, no se llega desde Money

> **Gap descubierto**: la lista de movimientos en Money hub NO tiene context menu para reverse. Hay que ir al Activity feed.

---

### J10 — Ver "quién aportó" a un recurso (capital breakdown)

1. Navegar a Resource detail (asset/event)
2. Scroll a ResourceMoneySlot
3. Sección "Quién aportó" muestra per-member contributions con %

**Clicks**: 1-2 (depende del entry path) · **Friction**: none

---

## 4. Duplicaciones críticas

### D1: Dos sheets de aportes para lo mismo

| | ContributeToSharedMoneySheet | ContributeToFundSheet |
|---|---|---|
| Phase | 3 (canonical) | Legacy |
| Scope | groupId + sourceResource opcional | fundId fijo |
| Capabilities | in-kind toggle, valuation sync | basic only |
| RPC | `contribute_to_shared_money` | `fund_contribute` |
| Sentence | "Aportar al dinero del grupo, opcionalmente para X" | "Aportar a este fondo" |

Hacen lo MISMO server-side (`INSERT INTO ledger_entries(type='contribution')`), diferente cara.

### D2: Dos sheets de gastos para lo mismo

| | RecordSharedExpenseSheet | RecordExpenseFromFundSheet |
|---|---|---|
| Phase | 3+4 (canonical) | Legacy |
| Split modes | 4 (equal/exact/percent/shares) | none |
| Scope | groupId | fundId |
| Tri-role | yes (paid_by, to, recorded_by) | yes |
| RPC | `record_shared_expense` | `fund_record_expense` |

Mismo modelo, diferente surface. **Cuando el user crea un fondo protegido, pierde el split picker**.

### D3: Dos rutas para "ver fondos"

| | SharedMoneyCard + GroupBalancesView | GroupFundsListView |
|---|---|---|
| Muestra | Shared pool (1 row) | TODO excepto shared pool |
| Filter | `id == sharedPoolId` | `id != sharedPoolId` |
| Push | inline + 1 push | 2 pushes desde home |

**La pregunta del founder**: "¿por qué dos vistas distintas?". Respuesta: filtros opuestos sobre la misma tabla, sin razón de producto. Es deuda de migración Phase 3.

### D4: AddLedgerEntryDestination vs UniversalMoneySheet

Cuando un user está en un event detail y tappea "Aportar" desde el ResourceMoneySlot, abre `ContributeToSharedMoneySheet` (Phase 3 path). Pero si tappea el botón "Movimientos" del menu del coordinator, abre `AddLedgerEntryDestination` con un kind picker grande. **Dos formas de aportar al mismo recurso**.

---

## 5. Propuesta de consolidación (6 PRs)

### PR-A (este turno, ~30 min): Embeber "Otros fondos" inline en `GroupBalancesView`

**Cambio**: en lugar de footer link → push, renderizar las filas de fondos protegidos DENTRO de `GroupBalancesView` como una sección colapsable (idéntica a "Movimientos recientes"). Mantener `GroupFundsListView` para deeplinks pero quitarlo del flow primario.

**Impacto**: J7 pasa de 4 clicks a 3. J8 pasa de 5 clicks a 4. **Elimina la pregunta "por qué dos vistas".**

### PR-B (~1h): Unificar sheets — eliminar `ContributeToFundSheet` + `RecordExpenseFromFundSheet`

**Cambio**: Cuando el user aporta/gasta DESDE un fund detail, usar `ContributeToSharedMoneySheet` + `RecordSharedExpenseSheet` con `sourceResource = fund`. El RPC `record_shared_expense` ya acepta `source_resource_id` que puede apuntar a un fund tipo protegido — basta validar server-side que el fund existe y stampa el atom correcto.

**Impacto**: 1 sheet de aporte, 1 sheet de gasto. Split picker disponible en TODOS los gastos (incluyendo legacy funds).

### PR-C (~30 min): Tap row de movimiento → reverse / edit-note inline

**Cambio**: en "Movimientos recientes" del hub, agregar context menu (long-press o swipe) con "Revertir operación" + "Editar nota". RPC ya existen (`reverse_ledger_entry`, `update_ledger_entry_note`).

**Impacto**: J9 pasa de 5+ clicks a 2 — gestión de errores deja de requerir el Activity feed.

### PR-D (~1h): Eliminar `AddLedgerEntryDestination` — siempre usar la pareja shared sheets

**Cambio**: cuando un coordinator necesita "abrir un sheet de movimiento", siempre router → `ContributeToSharedMoneySheet` / `RecordSharedExpenseSheet` con `sourceResource` set.

**Impacto**: 1 path de aporte por kind. AddLedgerEntryDestination se borra.

### PR-E (~30 min): Smart settlement v2 — algoritmo global

**Cambio**: extender el greedy actual (viewer-only) a un suggestion global del grupo. Lista todas las parejas optimal hasta que netCents == 0 para todos. Visible a todos los miembros como "Cómo cancelar todas las deudas en N pagos".

**Impacto**: J5 vuelve a 3 clicks pero ahora cubre ALL members, no solo el viewer.

### PR-F (~1h): Multi-currency support en hub + sugerencias

**Cambio**: hoy `GroupBalancesView` filtra a `group.currency`. Si hay entries en otras currencies, no se ven. Para grupos multi-moneda, agregar segmented picker de currency + recompute suggestions por currency.

**Impacto**: cubre grupos con USD + MXN (V1.5 placeholder).

---

## 6. Orden recomendado

1. **PR-A** (este turno) — máximo ROI visual, responde directo la queja del founder
2. **PR-B** — unifica sheets, mata legacy paths
3. **PR-C** — habilita gestión de errores desde Money (alto valor diario)
4. **PR-D** — cleanup del coordinator
5. **PR-E + PR-F** — V2 features (deferred si V1 cubre los grupos del founder)

---

## 7. Backend que necesita acompañar (futuro)

| Cambio iOS | Backend dep |
|---|---|
| PR-B (1 sheet de gasto) | `record_shared_expense` debe aceptar `source_resource_id` pointing a fund tipo protected — verificar |
| PR-E (global suggestions) | (none — algoritmo client-side) |
| PR-F (multi-currency) | `member_balances_per_group` ya retorna por (member, currency) — ya OK |

---

**Última actualización**: 2026-05-24 (live document — se actualiza por PR).
