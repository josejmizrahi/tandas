# Ruul — Resource Mesh: Money Parity + Cross-Resource Linking

**Status:** Draft 2026-05-17. Founder directive (Bros UX surfaced that resources feel siloed).
**Companion of:** `Plans/Active/Constitution.md` (Artículo 2/11), `Plans/Active/Asset.md` §21 (asset ≠ fund pero ambos pueden tener ledger), `Plans/Active/HierarchyReference.md` §3 (capabilities), `Plans/Active/AtomProjection.md` (ledger_entries polimórfico).
**Scope:** Llevar a TODOS los resource types (event/fund/asset/space/slot/right) al mismo nivel de superficie monetaria + activar el grafo `resource_links` polimórficamente para que el grupo se sienta UN sistema, no 6 islas.

> Hoy un fondo deja registrar `fund_contribute` + `fund_record_expense` y un activo deja `record_valuation` + `log_maintenance`. Ambos escriben en `public.ledger_entries`, pero ninguno expone la vocabulary genérica (`expense / contribution / payout / settlement`) que sí tiene event. Resultado: el founder siente que cada tipo es su propia app. Esto lo arregla.

---

## §1 — Premisa doctrinal (no negociable)

Tres invariantes que el plan respeta:

1. **Resource es polimórfico**. Ningún tipo "contiene" a otro estructuralmente. La relación entre dos resources vive en `resource_links` y es opcional, no jerárquica.
2. **`ledger` es una capability transversal** (mig 00136, `enabledResourceTypes: [.event, .fund, .asset, .space, .slot, .right]`). Si un resource la tiene encendida, expone la `MoneySectionView` completa con `expense / contribution / payout / settlement`. Punto.
3. **Atoms especializados conviven con los genéricos**. `fund_contribute`, `log_maintenance`, `record_valuation` siguen siendo el happy-path porque emiten `system_events` tipados (`fundDeposit`, `maintenanceLogged`, `valuationRecorded`) que el rule engine consume. Los genéricos (`record_ledger_entry`) son el escape hatch para casos sin RPC dedicado.

Corolario: **un activo puede tener `expense`, `contribution`, `settlement`, `payout`** vía la sección Money. NO le agregamos `asset_contribute()` etc. — eso sería duplicar fund. La sección genérica + `record_ledger_entry` cubre la vocabulary completa.

---

## §2 — Estado actual (audit honest)

### Money UI por resource type (hoy en prod)

| Type | Capabilities default | MoneySectionView visible | Vocabulary disponible |
|---|---|---|---|
| event | (varían por template) | si caps incluyen `ledger` | expense/contribution/payout/settlement (genérica) |
| fund | `ledger, money, rules` | ✅ | + `Registrar gasto` (atom) + `Lock/Unlock` |
| asset | `history, location, transfer, valuation, voting` | ❌ — falta `ledger` | sólo `record_valuation`, `log_maintenance`, `report_damage`, `record_asset_usage` |
| space | varía | ❌ típicamente | — |
| slot | varía | ❌ típicamente | — |
| right | varía | ❌ típicamente | — |

### Cross-resource linking

| Capacidad | Estado |
|---|---|
| Tabla `resource_links(from, to, kind)` | ✅ existe (mig 00198) |
| RPC `link_resource_to_event` | ✅ sólo event como source |
| RPC `unlink_resource_from_event` | ✅ |
| Validación matrix (from_type, to_type, kind) | ❌ inexistente |
| UI "Vinculaciones" polimórfica | ❌ `ResourcesUsedSectionView` gateado a `resourceType == .event` |
| Edges en prod | `0 rows` |

### Atoms hoy

`ledger_entries.resource_id` ya es polimórfico. Cualquier RPC de la familia ledger puede targetear cualquier resource. La constraint la pone el RPC, no el schema. El allowed-types whitelist en `record_ledger_entry` cubre todos los kinds (mig 00150).

---

## §3 — Plan en 3 tracks, 8 slices

Tracks A y B son independientes (se shipean en paralelo). Track C depende de los otros dos.

```
Track A: Money parity (assets gain ledger UX)
Track B: Cross-resource linking polimórfico
Track C: Rules + UX que conectan A y B
```

---

## Track A — Money parity entre resource types

### Slice A1 — Auto-enable `ledger` + `money` en asset/space/slot/right via builder

**Why**: hoy `AssetResourceBuilder` toma `draft.enabledCapabilities` literal. El draft default para asset no incluye `ledger`. Asset queda sin money UI.

**What**:
- Builders (`AssetResourceBuilder`, `SpaceResourceBuilder`, `SlotResourceBuilder`, `RightResourceBuilder`) inyectan `ledger` y `money` en `draft.enabledCapabilities` si no están presentes, ANTES de llamar `build_resource_from_draft`.
- Para `right` y `slot`, evaluar caso por caso (un `right` que sólo otorga acceso quizás no necesita money — config flag opcional en el builder).
- Decision capturada en código + plan: por default money ON en asset+space; por default OFF en slot+right (pero capability lista para activar manualmente).

**Migration**: `00231_backfill_ledger_caps_on_existing.sql` — inserta filas en `resource_capabilities` para todos los assets/spaces ya creados que no las tengan. Idempotente (`ON CONFLICT DO NOTHING`).

**DoD**:
- Crear un nuevo asset → `MoneySectionView` aparece con botón "Movimientos"
- Backfill: assets viejos también ven la sección
- Test: `AssetResourceBuilderTests` verifica que el draft post-builder incluye `ledger` + `money`

**Out of scope**: validar que el RPC `record_ledger_entry` funciona en asset (ya funciona — mig 00229 lo confirmó).

### Slice A2 — Secondary actions polimórficas para resources con `ledger`

**Why**: hoy sólo `fund` tiene `Registrar gasto` en el menú "···". Asset, space, etc. con `ledger` activo no exponen atajos rápidos — el founder debe abrir Movimientos → +Agregar → elegir tipo. Para fund hay shortcut; para asset no.

**What**:
- Refactor `CapabilityResolver+SecondaryActions.swift`: extraer el bloque `fundSecondaryActions`'s "Registrar gasto" + futuros "Registrar aporte" / "Registrar pago" a un helper `ledgerSecondaryActions(resource, viewerRole)`.
- Helper gatea por capability `ledger` presente, NO por `resource_type`.
- Cada acción abre un sheet pre-configurado con el `formKind` adecuado de `ResourceLedgerCoordinator`. Reutiliza el sheet existente (cero nuevos componentes UI).
- Acciones standard cuando `ledger` está on:
  - `Registrar gasto` (formKind=.expense)
  - `Registrar aporte` (formKind=.contribution)
  - `Registrar pago a miembro` (formKind=.settlement)
  - `Registrar payout del grupo` (formKind=.payout) — admin-only

**DoD**:
- Asset menú "···" expone las 4 acciones de ledger (no sólo "Compartir/Archivar")
- Fund mantiene su "Registrar gasto" (que ahora es la versión polimórfica + fund_record_expense sigue siendo el RPC backend)
- Tests: `CapabilityResolver+SecondaryActionsTests` cubre los 4 tipos × 2 roles

### Slice A3 — Atom typed para ledger entries sobre asset

**Why**: rule engine se entera de cosas mediante `system_events`. `fund_contribute` emite `fundDeposit`, `log_maintenance` emite `maintenanceLogged`. Pero `record_ledger_entry` NO emite ningún system_event tipado. Si grabás un `expense` genérico sobre un asset, la rule engine no ve nada.

**What**:
- Decisión: ¿emitir un nuevo atom `ledgerEntryRecorded` genérico, o no emitir nada (el ledger es su propia tabla)?
- Recomendación: emitir `ledgerEntryRecorded` con payload `{ entry_id, resource_type, kind, amount_cents, currency }` para que las rules puedan reaccionar uniformemente. El rule engine ya soporta `system_event` triggers — sólo whitelist en `is_known_system_event_type`.
- Migration: trigger `AFTER INSERT ON ledger_entries` que llama `record_system_event` con `event_type = 'ledgerEntryRecorded'` IFF el entry no viene de un atom RPC tipado (detect via `metadata->>'via'` que los RPCs especializados ya estampan).
- Rule shapes V1: `ledger.entryAbove(amount)` → consecuencia `notify(admins)` para visibility.

**DoD**:
- Insertar un `expense` genérico sobre un asset → `system_events` tiene 1 fila `ledgerEntryRecorded`
- Insertar via `fund_record_expense` → NO duplica el atom (el atom tipado `fundDeposit` / `fundExpense` ya existe)
- Rule editor expone trigger `ledger.entryAbove`

### Slice A4 — UX coherence: "DINERO" card consistente entre tipos

**Why**: Asset hoy renderiza secciones especializadas (Custody, Ownership, Maintenance, Bookings) ANTES de Money. Con Money on, el founder ve 5 cards de dinero (Maintenance includes costs!) sin orden claro.

**What**:
- Definir prioridades: Money es la card principal de dinero del activo. Maintenance/Valuation siguen siendo cards aparte (son lifecycle, no movement).
- Maintenance log row debería linkear a su ledger entry (el `log_maintenance` ya escribe a ledger_entries con metadata.maintenance_event_id).
- Valuation card muestra "última valuación" + linkear al historial via Money → Movimientos filtrado por type=valuation.

**DoD**:
- Asset detail: Money card ENTRE Description y Maintenance (priority 400, ya está)
- Maintenance card no duplica el costo total — sólo conteo de eventos + último → "Ver costos completos" linkea a Money
- Test snapshot del detail order

---

## Track B — Cross-resource linking polimórfico

### Slice B1 — RPC genérica `link_resources(from, to, kind)`

**Why**: `link_resource_to_event` es asimétrico y bloquea ~90% de combinaciones útiles (`fund uses asset`, `asset uses space`, `right governs fund`, etc.).

**What**:
- Nuevo RPC `link_resources(p_from_resource_id, p_to_resource_id, p_link_kind)` SECURITY DEFINER.
- Validación matrix server-side (tabla `resource_link_kinds` o switch en plpgsql) — qué tuplas `(from_type, to_type, kind)` son válidas:
  - V1 whitelist:
    - `event uses {fund, asset, space, slot}` (reemplaza la actual)
    - `fund uses {asset, space}` ("este activo se financia con este fondo")
    - `asset uses {space}` ("este equipo vive en este espacio")
    - `right governs {fund, asset, space}` ("este derecho controla este recurso")
  - Cualquier otra tupla → `raise exception 'unsupported link kind'`.
- RPC validations:
  - Both resources son del mismo grupo
  - Caller es member del grupo
  - Caller tiene permiso `linkResources` (nueva permission del catálogo, founder by default)
  - No duplicates activos (unique partial index `WHERE unlinked_at IS NULL`)
- `link_resource_to_event` queda como wrapper deprecated que llama `link_resources` con kind=`uses`.

**Migration**: `00232_link_resources_rpc.sql`. Forward-only, no rollback de `link_resource_to_event` (alias permanente).

**DoD**:
- RPC ejecutable + matrix de prueba pasa todas las combinaciones whitelisted
- Unique index previene dobles links activos
- `link_resource_to_event` sigue funcionando byte-by-byte

### Slice B2 — UI: Sección "VINCULACIONES" polimórfica

**Why**: `ResourcesUsedSectionView` hoy es event-only (gate `resourceType == .event` en UniversalResourceDetailView:122). Si activamos `fund uses asset`, no hay UI para verlo.

**What**:
- Renombrar `ResourcesUsedSectionView` → `ResourceLinksSectionView`. Eliminar gate por type, gatear por presencia de cualquier link in o out (no por capability).
- Mostrar 2 sub-secciones:
  - **"USA"** (out-edges): `from_resource = this`. Tarjeta por cada target con icon del type + nombre.
  - **"USADO POR"** (in-edges): `to_resource = this`. Mismo formato.
- Tap → navigation push al detail del otro resource.
- Botón "+ Vincular" si caller tiene permiso `linkResources` — abre un picker con resources del grupo filtrados por la matrix de validación.

**Adapter de detail**: `UniversalResourceDetailView` registra `ResourceLinksSectionView.definition` con prioridad ~700 (después de Money, antes de Activity).

**Repository**: nueva fetch `LiveResourceLinkRepository.listLinks(forResource: id) → ([incoming], [outgoing])` consultando `resource_links` con `from_resource_id=id OR to_resource_id=id AND unlinked_at IS NULL`.

**DoD**:
- Asset detail con un link `fund uses this asset` muestra "USADO POR: Fondo Bbva"
- Fund detail muestra "USA: Auto 2018"
- Tap navega al otro
- "+ Vincular" picker excluye combinaciones no whitelisted

### Slice B3 — Atom `resourceLinked` / `resourceUnlinked`

**Why**: sin atom las rules no pueden reaccionar a la formación del grafo. Pero las rules sobre linking son V2/V3 (governance flows tipo "cualquier link de fondo a activo requiere votación") — por ahora basta el atom para history feed.

**What**:
- Whitelist `resourceLinked`, `resourceUnlinked` en `is_known_system_event_type`.
- Trigger `AFTER INSERT/UPDATE ON resource_links` que emite el atom.
- Payload: `{ from_resource_id, from_resource_type, to_resource_id, to_resource_type, link_kind }`.
- History feed renderea: "Bros vinculó Fondo Bbva → Auto 2018" con dos chips clickeables.

**DoD**:
- Crear un link → aparece en el feed
- Atom aparece en `system_events`
- Rule editor expone trigger `resource.linked`

---

## Track C — Money fluye por el grafo

### Slice C1 — Hint UX cuando hay link relevante

**Why**: founder graba un gasto en un evento que `uses fund Bbva`. El sistema sabe del link. Debería ofrecer "¿También debitar del fondo Bbva?".

**What**:
- En `AddLedgerEntrySheet`, después de monto + tipo, si el resource tiene out-links a un `fund`, mostrar un toggle: "También registrar en fondo Bbva (-$X)".
- Si on → tras `record_ledger_entry` exitoso, segundo call a `fund_record_expense(p_fund_id=linked_fund, p_amount_cents=same, p_to_member_id=current_user, p_note='vía evento Comida')`.
- Atómico best-effort: si el segundo falla, mostrar warning + ofrecer retry. No rollback del primero (ya está en la tabla atómica per Constitution §11).

**DoD**:
- Crear expense en evento con link a fund → toggle visible
- Tap registrar → 2 ledger entries (una scope=event, otra scope=fund)
- Si fund call falla → banner "El gasto se registró pero no pudimos debitar el fondo. Reintentar?"

### Slice C2 — Rule shape "auto-debit linked fund on event close"

**Why**: hoy si el grupo cierra un evento, los gastos quedan sólo en el evento. Si hay un fund vinculado que debería "pagar" esos gastos, el founder lo hace a mano.

**What**:
- Rule shape: `whenEventClosed.usesLink(fund)` → `debitFund(amount = sum(event_expenses_where_from=member))`.
- Server-side rule engine (`process-system-events` edge function) detecta el shape, calcula el monto, ejecuta `fund_record_expense` server-side.
- Atom resultante: `fundAutoDebited` con payload `{ event_id, fund_id, total_cents, source = 'rule:auto_debit_linked_fund' }`.

**Out of scope**: UI para configurar el shape — sale por `RulePresetsView` con un preset nuevo en mig.

**DoD**:
- Rule activa + evento cierra con link a fund → fund_balance baja en el monto correcto
- History feed muestra "Bros debitó $X del fondo Bbva por cierre del evento Comida"

---

## §4 — Orden de ejecución

```
Sprint 1 (1 semana):  A1 + A2 (asset gana Money UI completa)
Sprint 2 (1 semana):  B1 + B2 (grafo polimórfico funcional)
Sprint 3 (3 días):    A3 + B3 (atoms para rules)
Sprint 4 (1 semana):  C1 + C2 (glue UX + rule)
                      A4 (UX coherence) en paralelo
```

Cada sprint termina en main verde, con la app instalable y la nueva surface operativa. No hay branch que sobreviva sprint.

---

## §5 — Lo que NO está en este plan

- **Inventory management**: nada de stock, depreciación lineal, asset tags, QR. Eso es Constitution §13 (filtro ontológico) territorio.
- **Multi-currency cross-resource**: si el evento es MXN y el fondo USD, C1 grita y exige el founder elija manualmente. Conversión automática es V5.
- **Hierarchy implícita**: nunca tratar `fund uses asset` como "el fondo posee el activo". Es link semántico, no ownership.
- **Atomic 2-phase commit**: las dobles escrituras en C1/C2 son best-effort. Si el grupo necesita atomicidad real → escapa a un edge function que abra una transacción server-side. No lo necesitamos en V1.

---

## §6 — Doctrina post-ejecución

Cuando este plan cierre, el founder podrá decir:

> "Un activo y un fondo son objetos paralelos del grupo. Cualquiera de los dos puede aceptar gastos, aportes, pagos a miembros o payouts del pot. Si los vinculo (`fund uses asset`), las operaciones de uno pueden disparar operaciones del otro vía reglas."

Eso es **Resource Mesh**. No es "fund tiene activos" ni "activo tiene ledger" — es "todos los resources son ciudadanos de primera y se enlazan opcionalmente cuando tiene sentido coordinarlos".
