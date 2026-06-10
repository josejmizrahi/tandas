# R.8 — Pool / Cuenta de Capital Colectiva (primitiva universal)

**Fecha:** 2026-06-10
**Status:** 🟢 R.8.A/B/C shipped — founder firmó shape 2026-06-10; schema (r8_a),
RPCs core (r8_b) y resolución `preview_pool_resolution`/`resolve_pool` con
winner_takes_all + equity_target y gate de gobernanza `pool.resolve` (r8_c,
20260611104000) en la cadena. Pendiente: R.8.D activity extra · R.8.E/F iOS
(en curso) · policies proportional/equal_share/rotational/custom_spec (post-MVP).
**Companions:**
- `Plans/Active/MVP2_iOS_Contract.md` (Money RPCs + obligations universal R.2R)
- `Plans/Active/R5V_UXDoctrine.md` (§0.4 action states · §V Section layout doctrine)
- `Plans/Active/R6_RuleEngineArchitecture.md` (evento `pool.resolved` se suma al catalog)
- `Plans/Active/R7_GovernanceOrchestrationEngine.md` (acciones de pool entran al catalog R.7 vía `pool.resolve` / `pool.contribute`)
- `Plans/Doctrine/doctrine_actor_context.md` (pool = actor `collective` sub-tipo `pool`)

---

## §0 — Historia del documento

**2026-06-10 (este doc):** Founder reportó dos fricciones reales del fin de semana:

1. **Settlement multifacético.** "Yo le debo a Eduardo 1000 pesos en bros de Happy King y a David 650, pero pagué 9490 por 8 boletos de Capo Marte. Eduardo va a usar 2, David 1, yo 2. Quiero que el settlement netee todo en el contexto."
2. **Bote sin acreedor.** "Anoche en Happy King se me hizo muy difícil marcar quién debe qué porque no se quién es el ganador hasta que acaba. Todos los que jugaron deberían tener obligación pendiente sin acreedor, y cuando hay ganador se le asignan."

Iteración 1 propuso `start_game_session` / `close_game_session` específico para juegos. Founder pidió generalizar:

> *"Pero quiero que sea escalable a otros casos de uso. Por ejemplo el ejemplo en donde yo aporto un terreno con un valor X y mi socio se compromete a pagar la construcción para hacer una nave industrial hasta que llegue al mismo valor y se tienen que registrar todos los gastos ahí y la aportación del terreno me entiendes? No solo para grupos de amigos. Piensa en todos los casos de uso."*

Iteración 2 (este doc) define un primitive único — **Pool** — con tres componentes (basis ledger + política declarativa + evento de resolución) que cubre bote de juego, joint venture, tanda/cundina, kitty de viaje, fondo de regalo, escrow de obra, partnership con capital accounts, bounty pool. Founder firmó shape e integración al tab Dinero del contexto.

> *"Sí, pero quiero que esté integrado al tab de dinero en el contexto."* — Founder, 2026-06-10

---

## §1 — Modelo conceptual

### 1.1 Definición

Un **Pool** es una cuenta de capital colectiva: un actor `collective` sub-tipo `pool` que vive **dentro de un contexto padre**, acepta contribuciones (cash o asset valuado) de N actores, mantiene un basis ledger por contribuyente, y se **resuelve** según una política declarativa que transforma el basis en obligaciones pairwise normales que entran al settlement existente.

```
Contexto padre (collective)
  └── Pool actor (collective, subtype='pool', parent_context_actor_id=padre)
        ├── pool_basis_entries (ledger por contribuyente: cash o asset)
        ├── pool_policy (winner_takes_all | equity_target | proportional | rotational | equal_share | custom)
        └── al resolverse → N obligations actor↔actor (van al settlement normal)
```

### 1.2 Por qué es un actor, no un resource

Los pools tienen las tres propiedades de un actor colectivo:
- **Reciben contribuciones** (debt-side: actor → pool).
- **Pueden ser counterparty** de una obligation (pending state, antes de resolver).
- **Tienen membership implícita** (los contribuyentes).

Modelar como actor reusa la columna `counterparty_actor_id` de `obligations` (ya existe, R.2R) sin agregar `pool_id` polimórfico. Las contribuciones pendientes son obligations con `creditor_actor_id = pool_actor_id` y `status='pending_pool'` (status nuevo). Al resolver, esas obligations se transforman/crystallizan a pairwise.

### 1.3 Por qué basis ledger separado de obligations

`obligations` es el ledger universal de deuda pairwise. `pool_basis_entries` registra **aportes al pool** con campos que `obligations` no cubre:

- `basis_kind`: `cash` | `asset` | `service` | `pending_stake`
- `asset_resource_id`: si el aporte es un recurso (terreno, vehículo)
- `valuation_amount` + `valuation_method`: para asset/service (no hay transferencia real de cash hasta que el pool se liquida)
- `pool_account_id`: FK al pool

Cuando el aporte es cash, **además** se emite una obligation paralela (`debtor=contributor, creditor=pool_actor, status='pending_pool'`) — eso permite que el pool tenga visibilidad en `attention_inbox` y settlement preview. Cuando es asset, la obligation no se emite hasta resolución (el terreno no se "paga" en cash, su basis se distribuye según política).

### 1.4 Resolución = crystallize basis a pairwise obligations

`resolve_pool(pool_id, payload)` ejecuta la política y emite obligations finales:

- **`winner_takes_all`** → toma todas las `pending_stake` obligations, las **UPDATE-a** con `creditor_actor_id = winner_actor_id` y `status='open'`. Las contribuciones de cash genuino (no stake) se mantienen como `creditor=pool` y el pool transfiere el balance al winner via una settlement op.
- **`equity_target`** → calcula basis de cada parte; si parte A está bajo target y parte B está al target, crea obligation `B → A` por el monto necesario, o marca al pool `target_reached` y libera el asset al socio que aportó el opuesto. Para el caso JV terreno↔construcción: cuando `basis_socio_construcción = basis_socio_terreno (= valuación del terreno)`, el pool se cierra; la propiedad del recurso `nave_industrial` queda compartida al 50/50 (right grant generado por resolución).
- **`proportional`** → distribuye el net value del pool entre contribuyentes según porcentaje de basis. Emite obligations `pool → contributor` por la cuota.
- **`equal_share`** → tras cierre, cada miembro debe (#total / #miembros). Emite obligations de nivelación entre quienes pagaron de más y de menos. (Caso: kitty de viaje.)
- **`rotational`** → cada ciclo, un actor recibe el pot total y los demás reciben pending_stake para el siguiente ciclo. (Caso: tanda/cundina — primer slice **NO** lo cubre, queda fuera de scope MVP.)
- **`custom_spec`** → escape hatch, payload define la matriz de distribución manualmente. (Caso: arreglos ad-hoc que no caen en las anteriores.)

### 1.5 Casos de uso mapeados al primitive

| Caso | Política | Aporte típico | Resolución |
|---|---|---|---|
| Bote Happy King | `winner_takes_all` | cash (`pending_stake`) por jugador | `resolve_pool({winner_actor_id})` |
| JV terreno↔construcción | `equity_target` | asset (terreno) + cash (expenses) | auto cuando basis_construccion = basis_terreno |
| Fondo regalo grupal | `proportional` o `equal_share` | cash por miembro | `resolve_pool({beneficiary_actor_id})` al comprar |
| Kitty de viaje | `equal_share` | cash registrado durante viaje | `resolve_pool()` al cierre del viaje |
| Tanda / cundina | `rotational` | cash periódico | cron-tick por ciclo (post-MVP) |
| Bounty pool | `winner_takes_all` | cash por sponsor | `resolve_pool({winner_actor_id})` cuando completion verificada |
| Escrow de obra | `equity_target` o `proportional` | cash por etapas | `resolve_pool()` por milestone |
| Partnership capital accounts | `custom_spec` | cash + asset | `resolve_pool({distribution_matrix})` al P&L close |

---

## §2 — Schema (R.8.A)

### 2.1 Tablas nuevas

```sql
-- Pool account: el actor del pool ya existe en `actors` (kind='collective', subtype='pool').
-- Esta tabla agrega metadata específica del pool.
create table public.pool_accounts (
  id uuid primary key default gen_random_uuid(),
  pool_actor_id uuid not null unique references public.actors(id) on delete cascade,
  parent_context_actor_id uuid not null references public.actors(id) on delete cascade,
  policy_key text not null check (policy_key in
    ('winner_takes_all', 'equity_target', 'proportional', 'equal_share', 'rotational', 'custom_spec')),
  policy_config jsonb not null default '{}',
  status text not null default 'open' check (status in ('open', 'target_reached', 'resolving', 'resolved', 'cancelled')),
  display_name text not null,
  description text,
  currency text,  -- nullable: pools de pure-asset (terreno↔construcción mixto) la dejan null
  target_amount numeric,  -- usado por equity_target
  metadata jsonb not null default '{}',
  created_by_actor_id uuid references public.actors(id),
  created_at timestamptz not null default now(),
  resolved_at timestamptz,
  resolved_payload jsonb
);

create index idx_pool_accounts_parent on public.pool_accounts (parent_context_actor_id, status);

-- Basis entries: ledger por contribuyente. Cash, asset, service, o pending_stake.
create table public.pool_basis_entries (
  id uuid primary key default gen_random_uuid(),
  pool_account_id uuid not null references public.pool_accounts(id) on delete cascade,
  contributor_actor_id uuid not null references public.actors(id),
  basis_kind text not null check (basis_kind in ('cash', 'asset', 'service', 'pending_stake')),
  basis_amount numeric not null check (basis_amount >= 0),
  currency text,  -- required si basis_kind='cash' o 'pending_stake'
  asset_resource_id uuid references public.resources(id),  -- required si basis_kind='asset'
  valuation_method text,  -- 'manual' | 'appraisal' | 'market' | 'cost'
  valuation_notes text,
  -- Vínculo con la obligation paralela cuando basis_kind='cash' o 'pending_stake':
  paired_obligation_id uuid references public.obligations(id),
  -- Vínculo con la money_transaction de cash genuino:
  money_transaction_id uuid references public.money_transactions(id),
  metadata jsonb not null default '{}',
  created_at timestamptz not null default now(),
  resolved_at timestamptz,  -- timestamp cuando este entry se liquidó al resolver el pool
  resolution_obligation_ids uuid[] not null default '{}'  -- obligations finales emitidas
);

create index idx_pool_basis_pool on public.pool_basis_entries (pool_account_id);
create index idx_pool_basis_contributor on public.pool_basis_entries (contributor_actor_id);

-- Comments
comment on table public.pool_accounts is
  'R.8: cuenta de capital colectiva. Bote / JV / kitty / fondo. Resolución → obligations pairwise.';
comment on column public.pool_accounts.policy_key is
  'R.8: política declarativa de resolución. Determina cómo basis ledger → obligations pairwise.';
comment on table public.pool_basis_entries is
  'R.8: aportes al pool. cash/asset/service/pending_stake. Al resolver emite obligations finales.';
```

### 2.2 Cambios a tablas existentes

```sql
-- 1. obligations: agregar status 'pending_pool' al CHECK existente.
alter table public.obligations drop constraint obligations_status_check;
alter table public.obligations
  add constraint obligations_status_check check (status in
    ('open', 'accepted', 'in_progress', 'completed', 'expired',
     'settled', 'cancelled', 'forgiven', 'disputed', 'pending_pool'));

-- 2. obligations: pending_pool obligations tienen creditor = pool_actor. Settlement
--    debe filtrar status='open' (ya lo hace), así que pending_pool queda fuera del
--    netting hasta que se crystallize.

-- 3. actors: agregar subtype 'pool' al collective sub-tipos válidos (si hay CHECK).
--    Verificar `mvp2_001_identity` — probable que no haya CHECK estricto.
```

### 2.3 RLS

- `pool_accounts` SELECT: miembro del `parent_context_actor_id` o contribuyente.
- `pool_basis_entries` SELECT: mismo gate.
- Escrituras: SOLO vía RPCs SECURITY DEFINER.

---

## §3 — RPCs (R.8.B)

Todas SECURITY DEFINER, errores en inglés (mapeados por `RPCErrorMapper`).

### 3.1 Lifecycle

| RPC | Firma | Devuelve | Notas |
|---|---|---|---|
| `create_pool` | `(p_parent_context_actor_id, p_display_name, p_policy_key, p_policy_config, p_currency?, p_target_amount?, p_description?, p_metadata?, p_client_id?)` | `{pool_account_id, pool_actor_id, pool_account: {row}}` | Idempotente por client_id. Crea actor `pool` + `pool_accounts` row. Requiere `money.manage` o role admin del padre. |
| `contribute_to_pool` | `(p_pool_account_id, p_basis_kind, p_amount, p_currency?, p_asset_resource_id?, p_valuation_method?, p_notes?, p_metadata?, p_client_id?)` | `{basis_entry_id, paired_obligation_id?, money_transaction_id?}` | basis_kind ∈ cash, asset, service, pending_stake. Cash → emite money_transaction + obligation `contributor → pool` con status='pending_pool'. Asset → solo basis entry (asset queda en resource del contribuyente hasta resolver). Pending_stake → obligation pending_pool sin transaction (caso bote: aún no pagas). |
| `update_pool_policy_config` | `(p_pool_account_id, p_policy_config_patch)` | `{pool_account: {row}}` | Solo creator o admin. Bloqueado si `status != 'open'` y hay basis entries. |
| `cancel_pool` | `(p_pool_account_id, p_reason?)` | `{cancelled: true}` | Marca status='cancelled'. Revierte pending_stake obligations a `cancelled`. Cash genuino requiere refund manual (out of scope este slice). |

### 3.2 Resolución

| RPC | Firma | Devuelve |
|---|---|---|
| `preview_pool_resolution` | `(p_pool_account_id, p_payload?)` | `{policy_key, basis_summary: [{contributor, basis_amount, basis_kind}], projected_obligations: [{debtor, creditor, amount, currency, reason}], warnings: [text]}` |
| `resolve_pool` | `(p_pool_account_id, p_payload, p_client_id?)` | `{pool_account_id, status, emitted_obligations: [{obligation_id, debtor, creditor, amount, currency}], emitted_activity_event_id}` |

`p_payload` depende de la política:
- `winner_takes_all`: `{winner_actor_id: uuid}`
- `equity_target`: `{}` (auto) o `{force_close: bool}`
- `proportional`: `{beneficiary_actor_id?: uuid}` (si null, distribuye a contribuyentes según basis %)
- `equal_share`: `{}` (auto)
- `rotational`: out of scope MVP
- `custom_spec`: `{distribution: [{from_actor_id, to_actor_id, amount}]}`

### 3.3 Lectura

| RPC | Firma | Devuelve |
|---|---|---|
| `list_context_pools` | `(p_parent_context_actor_id)` | `[{pool_account_id, pool_actor_id, display_name, policy_key, status, basis_total, currency, contributor_count, my_basis?, available_actions: [...]}]` |
| `pool_account_detail` | `(p_pool_account_id)` | `{pool_account: {row}, basis_entries: [{contributor_actor_id, display_name, basis_kind, basis_amount, currency, asset_resource_id, occurred_at}], available_actions: [{action_key, label, section, enabled, reason}], totals: {basis_total, my_basis, contributor_count}}` |

### 3.4 Activity events emitidos

| event_type | Cuándo | Payload |
|---|---|---|
| `pool.created` | `create_pool` | `{pool_account_id, pool_actor_id, policy_key, parent_context_actor_id}` |
| `pool.contributed` | `contribute_to_pool` | `{pool_account_id, contributor_actor_id, basis_kind, basis_amount, currency?}` |
| `pool.resolved` | `resolve_pool` | `{pool_account_id, policy_key, emitted_obligation_ids[], payload}` |
| `pool.cancelled` | `cancel_pool` | `{pool_account_id, reason?}` |
| `pool.target_reached` | trigger interno en `equity_target` cuando basis empareja | `{pool_account_id}` (sugiere resolución, no la fuerza) |

R.6 Rule Engine se suscribe a estos como cualquier otro event (no requiere cambios en R.6).

### 3.5 R.7 governance integration

Pools se integran al catalog R.7 con tres acciones:

| action_key | execution_rpc | default policy |
|---|---|---|
| `pool.contribute` | `contribute_to_pool` | `not_required` (default) |
| `pool.resolve` | `resolve_pool` | `requires_decision` para `equity_target` y `custom_spec`; `not_required` para `winner_takes_all` (lo activa quien tiene `pool.manage`) |
| `pool.cancel` | `cancel_pool` | `requires_decision` |

Founder puede overridear per-contexto via `governance_policies` (Cena Semanal: bote sin voto; Familia Mizrahi: bote requiere voto).

---

## §4 — Settlement integration (R.8.D)

### 4.1 Cero cambios en `generate_settlement_batch`

Las obligations emitidas por `resolve_pool` tienen `status='open'` y entran al batcher existente. El min-cashflow netting R.2N las absorbe automáticamente junto con expenses, fines, y game_results. **Esto resuelve el caso "settlement multifacético" del founder sin tocar el batcher.**

### 4.2 Preview agrupado por origen

Nueva RPC complementaria: `preview_settlement_breakdown(p_context_actor_id)`:

```jsonc
{
  "pairwise": [
    {
      "from_actor_id": "...", "from_display_name": "JJ",
      "to_actor_id": "...", "to_display_name": "Eduardo",
      "net_amount": 1372.50, "currency": "MXN",
      "sources": [
        {"kind": "expense",   "label": "Capo Marte tickets", "amount": 2372.50},
        {"kind": "pool",      "label": "Bote Happy King",    "amount": -1000.00, "pool_account_id": "..."}
      ]
    },
    {
      "from_actor_id": "...", "from_display_name": "JJ",
      "to_actor_id": "...", "to_display_name": "David",
      "net_amount": 536.25, "currency": "MXN",
      "sources": [
        {"kind": "expense", "label": "Capo Marte tickets", "amount": 1186.25},
        {"kind": "bro",     "label": "Bro pendiente",      "amount": -650.00}
      ]
    }
  ]
}
```

Esta RPC NO modifica el batcher — solo expone breakdown. Settlement preview en iOS lo consume para mostrar "qué obligaciones se comieron entre sí" antes de marcar pagado.

---

## §5 — iOS Domain + RPC wire (R.8.C)

### 5.1 RuulCore Domain

`Sources/RuulCore/Domain/Pool.swift` nuevo:

```swift
public struct PoolAccount: Sendable, Hashable, Identifiable, Codable {
    public let id: UUID                    // pool_account_id
    public let poolActorId: UUID
    public let parentContextActorId: UUID
    public let policyKey: PoolPolicyKey
    public let policyConfig: JSONValue
    public let status: PoolStatus
    public let displayName: String
    public let description: String?
    public let currency: String?
    public let targetAmount: Double?
    public let createdAt: Date
    public let resolvedAt: Date?
}

public enum PoolPolicyKey: String, Sendable, Codable {
    case winnerTakesAll = "winner_takes_all"
    case equityTarget   = "equity_target"
    case proportional   = "proportional"
    case equalShare     = "equal_share"
    case rotational     = "rotational"
    case customSpec     = "custom_spec"
}

public enum PoolStatus: String, Sendable, Codable {
    case open, targetReached = "target_reached", resolving, resolved, cancelled
}

public struct PoolBasisEntry: Sendable, Hashable, Identifiable, Codable {
    public let id: UUID
    public let poolAccountId: UUID
    public let contributorActorId: UUID
    public let contributorDisplayName: String?
    public let basisKind: PoolBasisKind
    public let basisAmount: Double
    public let currency: String?
    public let assetResourceId: UUID?
    public let occurredAt: Date
}

public enum PoolBasisKind: String, Sendable, Codable {
    case cash, asset, service
    case pendingStake = "pending_stake"
}

public struct PoolDetail: Sendable, Hashable, Codable {
    public let poolAccount: PoolAccount
    public let basisEntries: [PoolBasisEntry]
    public let availableActions: [AvailableAction]
    public let totals: PoolTotals
}

public struct PoolTotals: Sendable, Hashable, Codable {
    public let basisTotal: Double
    public let myBasis: Double
    public let contributorCount: Int
}

public struct PoolResolutionPreview: Sendable, Codable {
    public let policyKey: PoolPolicyKey
    public let basisSummary: [BasisSummaryRow]
    public let projectedObligations: [ProjectedObligation]
    public let warnings: [String]
}
```

### 5.2 RuulRPCClient additions

7 RPCs en `protocol RuulRPCClient` + `MockRuulRPCClient` + `SupabaseRuulRPCClient`:

```swift
func createPool(...) async throws -> PoolAccount
func contributeToPool(...) async throws -> PoolContribution
func updatePoolPolicyConfig(...) async throws -> PoolAccount
func cancelPool(...) async throws -> Void
func previewPoolResolution(...) async throws -> PoolResolutionPreview
func resolvePool(...) async throws -> PoolResolutionResult
func listContextPools(_ parentContextActorId: UUID) async throws -> [PoolListItem]
func poolAccountDetail(_ poolAccountId: UUID) async throws -> PoolDetail
```

Mock devuelve dos pools demo en Cena Semanal: bote Happy King con 4 contribuyentes pending_stake + un pool JV Nave Industrial en Casa Valle context.

### 5.3 Stores

Nuevo `PoolsStore` en `Stores/PoolsStore.swift` (sigue patrón `ResourcesStore`):

```swift
@MainActor @Observable
public final class PoolsStore {
    public private(set) var phase: LoadPhase
    public private(set) var pools: [PoolListItem] = []
    public func load(context: AppContext) async { ... }
    public func refresh() async { ... }
}
```

`PoolDetailStore` para la pantalla detail (con basis entries + preview).

---

## §6 — UI surface en Money tab (R.8.D)

### 6.1 `MoneyHomeView` — insertar Section "Fondos"

Layout actual: Hero / Pendientes / Acciones / Actividad / Detalles.
Layout R.8: **Hero / Pendientes / `Fondos` ← NUEVO / Acciones / Actividad / Detalles**.

Razón del placement: Pendientes muestra obligations abiertas; Fondos muestra capital colectivo en curso. Van juntos antes de "Qué puedes hacer".

```swift
@ViewBuilder
private var fondosSection: some View {
    if !poolsStore.pools.isEmpty {
        Section {
            ForEach(poolsStore.pools) { pool in
                NavigationLink {
                    PoolDetailView(poolAccountId: pool.id, context: context, container: container)
                } label: {
                    poolRow(pool)
                }
            }
            Button {
                isShowingCreatePool = true
            } label: {
                Label("Crear fondo", systemImage: "plus.circle.fill")
            }
        } header: {
            Text("Fondos (\(poolsStore.pools.count))")
        }
    } else if poolsStore.canCreatePool {
        Section {
            Button {
                isShowingCreatePool = true
            } label: {
                Label("Crear fondo", systemImage: "plus.circle.fill")
            }
        } header: {
            Text("Fondos")
        } footer: {
            Text("Cuentas conjuntas: botes de juego, joint ventures, kitty de viajes, fondos compartidos.")
        }
    }
}
```

`poolRow` muestra: icon por policy (🎲 winner_takes_all, 🤝 equity_target, 👥 equal_share, 📊 proportional) + display_name + chip status (RuulStatusBadge) + basis total + chevron.

### 6.2 `CreatePoolFlow` (wizard 3 pasos)

Patrón `CreateResourceFlow` (R.5.PICK shipped 2026-06-07):

1. **Pick policy** — List+Section con 4 policies MVP (winner_takes_all, equity_target, equal_share, proportional). `rotational` y `custom_spec` deferred.
2. **Config** — depende de policy: winner_takes_all pide `stake_per_player` opcional + `currency`; equity_target pide `target_amount` + `currency`; equal_share pide `currency`; proportional pide nada.
3. **Confirm** — display_name + description opcional → `create_pool` → push `PoolDetailView`.

### 6.3 `PoolDetailView`

Doctrina §V Detail layout: Hero / Atención / Aportes / Política / Acciones / Actividad.

```swift
List {
    heroSection         // RuulDetailHero: basis total + status badge + policy chip
    atencionSection     // si hay pending_stake del usuario o target alcanzado
    aportesSection      // basis ledger: cada contributor con basis_kind icon + amount
    politicaSection     // explicación legible de la política + target si aplica
    accionesSection     // available_actions gated: Aportar / Resolver / Cancelar / Configurar
    actividadSection    // pool.* events recientes
}
.listStyle(.insetGrouped)
```

### 6.4 `ContributeToPoolSheet`

Form simple:
- Picker `basis_kind` (cash / asset / pending_stake — service deferred)
- Si cash: TextField amount + currency picker (default = pool.currency)
- Si asset: resource picker (filtrado a recursos del contribuyente) + TextField valuation
- Si pending_stake: TextField amount + currency
- Textarea notes opcional
- Botón "Aportar" → `contribute_to_pool` → dismiss + refresh

### 6.5 `ResolvePoolSheet`

Dispatch por policy:
- `winner_takes_all`: Picker actor entre contribuyentes → preview → confirm
- `equity_target`: muestra basis_summary + projected_obligations + confirm (sin selector)
- `equal_share`: muestra projected_obligations + confirm
- `proportional`: opcional beneficiary picker; default split entre contribuyentes

Llama `preview_pool_resolution` al abrir → muestra projected_obligations + warnings → confirm llama `resolve_pool`.

### 6.6 `CreateIntentSheet` — agregar `intent.fund`

Nueva row (patrón R.5X.fix.B `intent.obligation`):
```swift
case .fund:
    Label("Crear fondo", systemImage: "banknote.fill")
```
→ presenta `CreatePoolFlow` con el context actual. Permite crear pool desde el ➕ global del shell sin entrar al tab Dinero.

### 6.7 `SettlementView` — breakdown agrupado por origen

Reusa `preview_settlement_breakdown` RPC (§4.2). Cada par actor↔actor muestra:
- Net amount prominent
- Sources expandable: chip por kind (expense / pool / fine / bro / game_result) + amount con signo

---

## §7 — Seeds demo (R.8.E)

`MockRuulRPCClient.demo()` agrega dos pools:

1. **Bote Happy King** (Cena Semanal context, policy `winner_takes_all`)
   - JJ, Eduardo, David, Mike → cada uno `pending_stake` 200 MXN
   - status `open`
   - Demuestra: bote sin acreedor, resolución asigna a winner

2. **JV Nave Industrial** (Familia Mizrahi context, policy `equity_target`, target 5,000,000 MXN)
   - JJ → asset (resource `terreno_industrial_norte`) valued at 5,000,000 MXN
   - Hermano → cash 1,200,000 MXN acumulado (3 expenses de construcción)
   - status `open`, falta 3,800,000 MXN para target
   - Demuestra: aportes mixtos (asset + cash), basis ledger, target visible

Backend seed via `supabase/migrations/2026XXXXXXXXXX_r8_e_seeds_pools_demo.sql` (idempotente — solo si actors demo existen).

---

## §8 — Slices

| Slice | Scope | DoD |
|---|---|---|
| **R.8.A** Schema | `pool_accounts` + `pool_basis_entries` + `obligations.status='pending_pool'` + RLS | mig aplicada · smoke crea pool actor + entry + RLS verde · no rompe migrations existentes |
| **R.8.B** RPCs core | `create_pool` + `contribute_to_pool` + `list_context_pools` + `pool_account_detail` + activity emits | 4 RPCs SECURITY DEFINER · smoke cubre cash+asset+pending_stake · cliente_id idempotente |
| **R.8.C** Resolución | `preview_pool_resolution` + `resolve_pool` + dos políticas (`winner_takes_all`, `equity_target`) + `pool.target_reached` trigger | smoke: bote Happy King winner crystallize 4 pending_stake → 4 obligations open · smoke JV equity_target auto-close cuando basis empareja · idempotency por client_id |
| **R.8.D** iOS Domain + RPC wire | Domain Pool* + 8 RPCs en protocol/Mock/Supabase + `PoolsStore` + `PoolDetailStore` | build verde · MockRuulRPCClient demo() devuelve los 2 seeds · zero break en Mock existente |
| **R.8.E** UI Money tab | `fondosSection` en MoneyHomeView + `CreatePoolFlow` + `PoolDetailView` + `ContributeToPoolSheet` + `ResolvePoolSheet` + `intent.fund` en CreateIntentSheet | build verde · preview demo muestra los 2 fondos · iPhone JJ smoke: aportar al bote + resolver con winner = JJ → ver obligations emitidas en Pendientes |
| **R.8.F** Settlement preview | `preview_settlement_breakdown` RPC + SettlementView breakdown UI + R.7 catalog wire (`pool.contribute` / `pool.resolve` / `pool.cancel`) | settlement preview muestra agrupación por origen (expense/pool/fine/bro) · 3 acciones pool en R.7 catalog · governance smoke: pool resolve `equity_target` con policy `requires_decision` → crea decision · governance smoke: bote winner_takes_all sin voto |
| **R.8.G** Seeds + founder smoke | mig seeds bote Happy King + JV Nave + smoke iPhone JJ end-to-end | founder firma flow real (no demo): crea bote, todos aportan, resolve con winner, settlement neteado |

---

## §9 — Fuera de scope (post-R.8)

- **`rotational` policy** (tanda/cundina) — requiere ciclos + cron-tick por período. R.9 candidate.
- **`service` basis_kind con valuación de mercado** (hours worked, professional rates) — modelado pero no UI. Deferred.
- **Pool ownership transfer** — quien controla las settings del pool. MVP: creator. R.9 puede agregar `pool.transfer`.
- **Refund flow al cancelar pool con cash genuino aportado** — MVP requiere refund manual fuera del sistema. Slice futuro: refund automático via reverse obligation.
- **Cross-pool settlement** — settlements que abarquen pools de varios contextos. Deferred — el caso del founder vive todo en un contexto.
- **Pool → Resource direct ownership** — el resultado de un JV (la nave industrial) idealmente crea un resource con rights compartidos al resolverse. MVP: resolve_pool emite obligations + manualmente se crea el resource + grants. R.9 candidate: `equity_target` resolución auto-genera resource + rights.

---

## §10 — Riesgos y decisiones abiertas

1. **Pool actor vs Pool resource.** Firmado actor en §1.2. Riesgo: actor pool con membership implícita podría confundir queries que asumen actors humanos. Mitigación: `actors.actor_subtype='pool'` filtrable, y `pool_accounts.parent_context_actor_id` es la fuente de truth para "dónde vive".
2. **`pending_stake` status en obligations.** Suma un estado al lifecycle. Riesgo: algún caller que filtra por `status != 'settled'` ahora ve pending_stake. Mitigación: `pending_stake` se trata como `open` semánticamente PERO el settlement batcher debe filtrar explícitamente a `status='open'` (ya lo hace). Auditar `attention_inbox` y `my_world` para excluir o renderizar especial.
3. **Naming founder-call.** "Fondos" propuesto. Alternativas: "Cuentas conjuntas" (formal), "Botes" (no aguanta JV). **Pending sign-off.**
4. **Pool de contexto vs pool standalone.** MVP: pool siempre vive bajo un context padre. Pools "personales" o cross-context fuera de scope.
5. **Asset valuation method.** MVP acepta `manual` (sin validación). `appraisal` / `market` / `cost` quedan como hint metadata — no enforcement. Mitigación: si dos partes disputan valuación, governance (R.7) puede meter `pool.update_valuation` con voto.
6. **Resolución parcial.** MVP: resolve_pool es all-or-nothing. Resolución por basis entry parcial (pagar al ganador de cada mano de Happy King sin cerrar el bote completo) fuera de scope — para eso, crear N pools pequeños o usar `record_game_result` legacy.

---

## §11 — Sign-off pendiente (founder)

1. ✅ Shape primitive (Pool + Basis Ledger + Policy declarativa) — firmado 2026-06-10
2. ✅ Integración al tab Dinero (`MoneyHomeView` Section "Fondos") — firmado 2026-06-10
3. ⏳ Naming "Fondos" como umbrella label
4. ⏳ Set inicial de políticas MVP: `winner_takes_all`, `equity_target`, `equal_share`, `proportional`
5. ⏳ Slice order: A → B → C → D → E → F → G (backend antes que iOS antes que UI antes que governance/preview)
6. ⏳ Seeds demo: bote Happy King + JV Nave Industrial
7. ⏳ Out-of-scope confirmado (rotational/tanda + cross-pool + auto resource gen)
