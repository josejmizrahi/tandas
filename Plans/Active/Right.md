# Ruul — `right` Resource Type (Canonical Specification)

**Status:** Canónico desde 2026-05-18. Founder directive.
**Companion of:** `Plans/Active/Constitution.md` (Artículo 2 — enum congelado), `Plans/Active/TalmudicGovernance.md` (8 principios cardinales — right pasa los 8 con 1 partial documentado), `Plans/Active/Asset.md` §11 (asset puede tener rights), `Plans/Active/Space.md` §13 (rights grant_access_to spaces), `Plans/Active/Fund.md` §11 (rights grant_authority_over funds), `Plans/Active/Slot.md` §16, `Plans/Active/AtomProjection.md`, `Plans/Active/HierarchyReference.md` §2.
**Scope:** Define qué es `resources.resource_type = 'right'` en Ruul, qué NO es, y cómo se modela. Toda decisión de implementación sobre `right` consulta primero este documento.

> Ruul **NO** modela ACL, ni Discord-style roles, ni IAM tradicional. Ruul modela coordinación social sobre **claims normativos persistentes** mediante `resources`, `capabilities`, `rules`, `atoms` y `projections`. Un `right` **NO** es solamente "un permiso" ni "una membresía" — es la **entitlement layer** de la coordinación: el reconocimiento explícito de que el holder puede ejercer una capability X sobre un target Y, con scope, prioridad, exclusividad, transferabilidad, delegabilidad, divisibilidad y expiración configurables. Es la capa jurídica de "derecho de uso/acceso/beneficio".

---

## §1 — Definición ontológica

Un `right` es:

> Un claim normativo persistente otorgado a un holder (miembro o grupo) sobre un target (resource específico, resource_type, capability, o scope group entero), con atributos jurídicos configurables (priority, exclusive, transferable, delegable, divisible, expires_at), gobernable mediante atoms append-only (transferred / delegated / revoked / suspended / restored / exercised / expired). El right NO es la acción que el holder puede tomar — es el reconocimiento social de que está autorizado a tomarla.

Un `right` puede representar:

- membresía Gold de un club
- voting share de equity en startup
- day pass a un coworking
- equity tranche con derecho a dividendos
- custody assignment de un asset
- veto sobre transfers > $X
- prioridad de booking en una cancha
- acceso especial al palco para semifinales
- approval authority sobre gastos de un fund
- delegación temporal de autoridad de tesorero
- derecho de uso preferente de equipo compartido
- pase de invitado one-time
- equity vesting con cliff + linear
- license to use IP del grupo

---

## §2 — Principio cardinal

```
right = claim normativo persistente sobre (target × capability)
        con scope, priority y lifecycle propios
```

**NO:**

```
right = permission        (permission es boolean del sistema; right es entidad)
right = role              (role es bundle de permissions; right es claim atómico)
right = membership        (membership es relation User→Group; right es claim sobre algo)
right = capability        (capability es comportamiento posible; right es autorización)
right = group_policy      (policy es regla global; right es claim específico)
right = ACL row           (ACL es config técnica; right es objeto jurídico con history)
```

La diferencia es estructural. Los rights tienen **identidad propia**, **lifecycle independiente** (created → active → [transferred/delegated/suspended] → revoked|expired → archived), y **atoms append-only**. Sobreviven a sus targets (un right en un asset archivado persiste como historia). Pueden venderse/transferirse/delegarse. Tienen prioridad jerárquica. Son **objetos jurídicos**, no flags.

---

## §3 — `right` NO es

| Esto | Pertenece a | Por qué |
|------|-------------|---------|
| Permission (createVote, bookSlot, etc.) | `public.permissions` enum | Sistema, no entidad |
| Role (founder, admin, treasurer) | `groups.roles` jsonb | Bundle de permissions |
| Membership (Jose es miembro de X) | `group_members` | Relation, no claim |
| Capability (`booking`, `voting`) | `public.capabilities` | Comportamiento posible |
| Group policy | `public.group_policies` | Regla global, no claim individual |
| Override de capacity por miembro | `member_capability_overrides` (futuro) | Exception puntual |
| Asignación de slot | `slotAssigned` atom | Acto, no claim persistente |
| Custody temporal de asset | `custodyAssigned` atom | Acto |

---

## §4 — Polimorfismo total (target × capability × scope)

Right es **el resource más polimórfico** del enum. Tres dimensiones lo definen:

### 4.1 Target

```
target_resource_id  uuid   nullable — apunta a resource específico
target_capability   text   nullable — apunta a capability (booking, voting, access, etc.)
scope               text   default 'resource' — uno de:
                              'group'       — vale para todo el grupo
                              'resource_type' — vale para todo resource_type=X
                              'resource'    — vale para target_resource_id concreto
                              'occurrence'  — vale para occurrence específica
                                              (futuro, evento puntual)
```

Combinaciones canónicas:

```
scope=group,         target_resource=null,    capability=null       → "miembro vitalicio"
scope=group,         target_resource=null,    capability='voting'   → "voting share group-wide"
scope=resource_type, target_resource=null,    capability='booking'  → "puede reservar cualquier cancha"
scope=resource,      target_resource=palco,   capability='access'   → "acceso al palco específico"
scope=resource,      target_resource=fund,    capability='approval' → "tesorero del fondo"
scope=resource,      target_resource=asset,   capability='transfer' → "puede vender este asset"
```

### 4.2 Capability

Cualquier capability del catálogo (`public.capabilities`) puede ser el objeto del right. El derecho NO es la capability per se — es el "reconocimiento explícito" de que el holder está autorizado a ejercerla en el target especificado.

### 4.3 Jurídico knobs

```
priority      int      — orden de evaluación (higher wins). Default 0.
exclusive     boolean  — only one holder permitted? (e.g. tesorero exclusivo)
transferable  boolean  — holder puede transferir a otro miembro?
delegable     boolean  — holder puede delegar temporalmente?
divisible     boolean  — el claim puede fraccionarse? (equity tranches)
expires_at    timestamptz nullable — auto-expira en X fecha?
source        text nullable — origin docs/contrato (audit)
```

Estos no son boilerplate — son la doctrina jurídica del right. Cada uno tiene semántica precisa que el rule engine consume.

---

## §5 — Ejemplos canónicos

### Caso 1 — Membresía Gold del club

**Resource:** `right: Membresía Gold de Lupe`

```
holder_member_id     = Lupe
target_resource_id   = null
target_capability    = null
scope                = 'group'
priority             = 0
exclusive            = false
transferable         = false  (no se puede vender)
delegable            = false
divisible            = false
expires_at           = 2027-12-31
source               = 'contrato_membership_2025_07_15.pdf'
```

**Significado:** Lupe es miembro Gold del grupo hasta fin de 2027. Reglas pueden consultar este right para decidir si puede entrar a salas premium, votar en juntas, etc.

### Caso 2 — Voting share de equity

**Resource:** `right: 10 votos en Startup X`

```
holder_member_id   = Founder Jose
target_resource_id = startup_asset_id
target_capability  = 'voting'
scope              = 'resource'
priority           = 0
exclusive          = false   (otros holders pueden tener votos también)
transferable       = true    (acciones vendibles)
delegable          = true    (proxy voting)
divisible          = true    (puede vender 3 de 10)
expires_at         = null
metadata.shares    = 10
```

**Significado:** Cuando se abre vote sobre el startup, el evaluator suma los `shares` de todos los rights activos.

### Caso 3 — Day pass de coworking

**Resource:** `right: Day pass Coworking 12-mar-2026`

```
holder_member_id   = Pedro (invitado externo, member temporal)
target_resource_id = coworking_floor_id
target_capability  = 'access'
scope              = 'resource'
transferable       = false
delegable          = false
divisible          = false
expires_at         = 2026-03-12T23:59:59Z
source             = 'sponsor_invite'
```

**Significado:** Pedro puede ejercer `access` sobre el coworking solo ese día. El cron `expire_due_rights` lo expira automáticamente.

### Caso 4 — Tesorero del fondo

**Resource:** `right: Tesorero Fondo Mantenimiento Palco`

```
holder_member_id   = Maria
target_resource_id = fund_palco_mantenimiento_id
target_capability  = 'approval'
scope              = 'resource'
priority           = 100
exclusive          = true    (solo un tesorero)
transferable       = true    (siguiente tesorero puede recibir)
delegable          = true    (vacation backup)
divisible          = false
```

**Significado:** Maria es tesorera; cuando alguien intenta hacer un expense > threshold, la rule "requires treasurer approval" consulta este right.

### Caso 5 — Veto sobre transfers grandes

**Resource:** `right: Veto Transfers Palco > $50k`

```
holder_member_id   = Founder Daniel
target_resource_id = palco_asset_id
target_capability  = 'transfer'
scope              = 'resource'
priority           = 1000
exclusive          = true
transferable       = false   (founder-only, no se vende)
metadata.condition = 'amount_above:5000000'   (cents)
```

**Significado:** Cualquier transfer del palco > $50k requiere approval explícito de Daniel. Rule engine lo consulta antes de finalize.

---

## §6 — Right vs resource sobreviviente

Un right **sobrevive a su target**. Si el asset/space/fund target se archiva, el right persiste como historia. Esto es intencional:

- evidencia de quién tuvo voting share en una compañía disuelta
- registro de quién recibió membership el año pasado (aunque la membership haya expirado)
- auditoría de equity vesting historic

Para "borrar" un right: `archive_resource` (soft delete). Atoms permanecen.

---

## §7 — Lifecycle (status machine)

```
created
  ↓ create_right
status='active'  + rightCreated atom + (opcional) holder default = caller
  ↓
  ├─ transfer_right       → status sigue 'active', holder cambia, rightTransferred
  ├─ delegate_right       → status sigue 'active', metadata.delegate_until, rightDelegated
  ├─ exercise_right       → status sigue 'active', metadata.last_exercised_at, rightExercised
  ├─ suspend_right        → status sigue 'active', metadata.suspended_until, rightSuspended
  ├─ restore_right        → metadata.suspended_until cleared, rightRestored
  │                         (también puede lift status='revoked' → 'active')
  ├─ revoke_right         → status='revoked', rightRevoked
  └─ expire_due_rights    → status='expired', rightExpired (cron, hourly)

(cualquier status)
  ↓ archive_resource (admin)
status persistente + archived_at = now() + resourceArchived
```

### Status canónicos (3)

```
active     — claim vigente, puede ejercerse
revoked    — admin revocó manualmente
expired    — expires_at lapsed (cron-emitted)
```

### Suspend NO cambia status — es marker temporal

`metadata.suspended_until` es **marker mutable** (no estado canónico). Convivencia con doctrine:

- status='active' + suspended_until=null      → "no suspendido"
- status='active' + suspended_until=future   → "suspended hasta esa fecha"
- status='active' + suspended_until=past     → técnicamente expirado, pero admin debe llamar restore (no auto-lift)

Es decir: status='active' es la verdad canónica; suspended_until es un overlay opcional que el rule engine consulta para decidir "este right está exercise-able AHORA". Esta separación es deliberada — evita que crons mute status automáticamente.

---

## §8 — Atoms canónicos (9 totales)

### Lifecycle (mig 00198 + 00199 + 00200 + 00203)

```
rightCreated       — create_right RPC. Payload: {name, holder_member_id,
                     target_resource_id, target_capability, scope, priority,
                     exclusive, transferable, delegable, divisible, expires_at,
                     source, created_by, holder_defaulted}
rightTransferred   — transfer_right RPC (holder+admin). Payload:
                     {from_member_id, to_member_id, transferred_by, reason}
rightDelegated     — delegate_right RPC (holder+admin). Payload:
                     {delegate_member_id, until, delegated_by, reason}
rightRevoked       — revoke_right RPC (admin). Payload:
                     {previous_status, revoked_by, reason}
rightSuspended     — suspend_right RPC (admin). Payload:
                     {until, suspended_by, reason}
rightRestored      — restore_right RPC (admin). Payload: {restored_by, reason}
rightExercised    — exercise_right RPC (holder or delegate). Payload:
                     {exercised_by_user_id, exercised_by_member_id, context}
rightExpired       — expire_due_rights cron (hourly). Payload:
                     {expired_at, holder_member_id, name,
                      source='cron:expire_due_rights'}
rightExpiringSoon  — notify_rights_expiring_soon cron (daily, mig 00206).
                     Payload: {expires_at, holder_member_id, name,
                               days_until_expiry, window_days,
                               source='cron:notify_rights_expiring_soon'}
```

Todos en `system_events` con guard append-only. Idempotencia via cron flags en metadata (`expiration_warning_emitted`).

---

## §9 — Projection canónica

### `right_holders_view` (mig 00198)

Columnas:

```
right_id, group_id, status, name, holder_member_id, holder_user_id,
delegate_member_id, delegate_user_id, delegate_until,
target_resource_id, target_capability, scope, priority,
exclusive, transferable, delegable, divisible,
expires_at, suspended_until, last_exercised_at,
source, created_by, created_at, updated_at, archived_at
```

`security_invoker = on` — RLS sobre `resources` aplica.

Single source — NO existe `rights_view` separada. Projecta directamente de `resources WHERE resource_type='right'` joineado con `group_members` para resolver holder/delegate names.

### Futuras (cuando demand-pull lo pida)

```
right_chain_view        — transfer history per right (atoms folded)
right_active_grants_view — quién tiene right activo sobre target X
right_exercise_log_view  — frecuencia de uso por right
```

---

## §10 — Right como centro de governance

Rights aplican en precedencia jerárquica:

```
right más específico (scope=resource) > resource_type > group
+ priority desc tiebreak
+ created_at asc tiebreak final
```

El rule engine consulta rights cuando una acción se dispara:

- "Maria intenta hacer expense $5k del fund X" → query rights con
  `target_resource_id=fund_X AND target_capability='approval' AND status='active' AND suspended_until IS NULL`
- "Pedro intenta entrar al coworking" → query rights con target=coworking + capability='access'

Si NO hay right matching → consultar group_policies + rules default. Si SÍ hay right → la autorización ya está concedida (sujeta a priority y exclusive).

---

## §11 — Right NO es event / asset / space / fund / slot

**Event:** occurrence temporal. Right puede `grants_access_to` eventos puntuales.
**Asset:** objeto persistente. Right puede gobernar transfer/ownership de assets.
**Space:** lugar persistente. Right puede `grants_access_to` spaces.
**Fund:** pool monetario. Right puede `grants_authority_over` funds.
**Slot:** partición atómica. Right puede `grants_access_to` slot classes.

Right es transversal — **modifica** cómo los otros resources se gobiernan.

---

## §12 — Capabilities aplicables

| Capability      | Significado                                           | Status     |
|-----------------|-------------------------------------------------------|------------|
| `transfer`      | Right puede transferirse a otro holder                | stable     |
| `delegation`    | Right puede delegarse temporalmente                   | stable     |
| `expiration`    | Right tiene fecha de caducidad                        | stable     |
| `voting`        | Right confiere voto (con shares opcional)             | stable     |
| `approval`      | Right confiere autoridad de approval                  | incomplete |
| `access`        | Right confiere acceso a target                        | stable     |
| `ownership`     | Right representa propiedad (vs. usufructo)            | stable     |
| `valuation`     | Right tiene valor económico (equity)                  | stable     |
| `status`        | Display lifecycle (active/revoked/expired)            | stable     |
| `description`   | Texto libre + source de contrato                      | stable     |
| `history`       | Activity feed de transfers/delegations/exercises      | stable     |
| `rules`         | Rules específicas sobre cómo se ejerce                | stable     |

---

## §13 — Permission gates (mig 00200 + 00206)

| RPC                    | Quién puede ejecutar                                            |
|------------------------|------------------------------------------------------------------|
| `create_right`         | Cualquier miembro del grupo (`is_group_member`)                  |
| `transfer_right`       | Current holder OR group admin (hardened mig 00206)              |
| `delegate_right`       | Current holder OR group admin (hardened mig 00206)              |
| `revoke_right`         | Group admin only                                                 |
| `suspend_right`        | Group admin only                                                 |
| `restore_right`        | Group admin only                                                 |
| `exercise_right`       | Current holder OR current delegate (within delegate_until)       |
| `update_right_metadata`| Group admin only                                                 |
| `expire_due_rights`    | service_role only (cron)                                         |
| `notify_rights_expiring_soon` | service_role only (cron)                                  |

**Note:** Mig 00200 relajó todos los lifecycle RPCs para aceptar `auth.uid() = NULL` cuando el caller es service_role — habilita rule-engine-driven transfers automáticos. El gate humano sigue intacto cuando hay auth.uid.

---

## §14 — Cron behavior

### `expire_due_rights` (hourly)

```
SELECT rights WHERE expires_at < now()
  AND status='active'
  AND metadata.expired_emitted IS NULL
  → for each: status='expired'
            + emit rightExpired
            + stamp metadata.expired_emitted=now() (idempotency)
```

### `notify_rights_expiring_soon` (daily)

```
SELECT rights WHERE expires_at BETWEEN now() AND now() + 14 days
  AND status='active'
  AND metadata.expiration_warning_emitted IS NULL
  → for each: emit rightExpiringSoon
            + stamp metadata.expiration_warning_emitted=now()
```

Ambos crons idempotentes vía flag stamping. Rule template `right_expiration_warning` (mig 00203) consume `rightExpiringSoon` para notificar al holder.

---

## §15 — Auto-lift de suspensión: NO (admin gesture explícita)

Cuando `suspended_until < now()`, el right **NO auto-restablece** — admin debe llamar `restore_right` explícitamente. Doctrina TalmudicGovernance §4.G (consentimiento explícito): el admin tomó la decisión de suspender; el admin debe tomar la decisión de restaurar.

Si la suspensión debe ser puramente temporal sin gesture admin, eso es feature distinto (e.g., rule consequence "auto-restore al pasar X" sería un nuevo template). Por default: explicit.

---

## §16 — Divisible rights — Phase 2 future

Hoy `divisible=true` es flag declarativo sin ledger integration. Cuando aterricen rights con fractional shares ledger:

- `right_shares` ledger entries (mig futura) registran fragments
- transfer parcial = nuevo right child del original + ledger entry
- consolidation = merge atom

Hoy: para fractional ownership, crear N rights scoped al mismo target con `exclusive=false` + `priority` distintas. El audit es funcional aunque más verboso.

---

## §17 — Arquitectura de datos

Right vive en:

```
resources.resource_type = 'right'

metadata.holder_member_id        — UUID, el holder actual
metadata.target_resource_id      — UUID nullable
metadata.target_capability       — text nullable
metadata.scope                   — group | resource_type | resource | occurrence
metadata.priority                — int
metadata.exclusive               — boolean
metadata.transferable            — boolean
metadata.delegable               — boolean
metadata.divisible               — boolean
metadata.expires_at              — timestamptz nullable
metadata.suspended_until         — timestamptz nullable (NO es status, es marker)
metadata.delegate_member_id      — UUID nullable
metadata.delegate_until          — timestamptz nullable
metadata.last_exercised_at       — timestamptz nullable (cache)
metadata.source                  — text nullable (source contractual)
metadata.expired_emitted         — flag idempotency cron
metadata.expiration_warning_emitted — flag idempotency cron

status text                       — 'active' | 'revoked' | 'expired'
archived_at timestamptz nullable
```

**NO crear:** tabla `rights` paralela. **NO crear:** subtype tables (`memberships`, `equity_shares`, `vetoes`). Toda diferencia entre tipos de right vive en `metadata` (jsonb) + capabilities activadas + target/scope combination.

---

## §18 — UI/UX correcto

Right renderiza dentro de `UniversalResourceDetailView`, igual que event/asset/fund/space/slot.

### Action surface (RightActionSheet)

Modal con 6 actions polimórficas según capability + status:

```
Exercise              (cualquier holder/delegate, si exercisable)
Transfer to member    (holder/admin, si transferable)
Delegate to member    (holder/admin, si delegable)
Revoke                (admin only)
Suspend               (admin only)
Restore               (admin only)
```

### Edit surface (EditRightSheet)

Admin-only panel con ~10 knobs (priority, scope, exclusive/transferable/etc., expiration, source). Calls `update_right_metadata` con changed-keys-only diff.

### Lo que el usuario debe ver

```
Membresía Gold de Lupe
Activo · expira en 60 días

DETALLES
Holder: Lupe
Hasta: 31 dic 2027
Fuente: contrato_membership_2025.pdf

ACCIONES
[Ejercer]  [Transferir]  [Delegar]
[Suspender]  [Revocar]   (solo admins)

HISTORIA
Hace 3 meses: Right creado por Founder Daniel
Hace 1 mes: Lupe ejerció (entrada al palco)
```

**NO** debe ver: `metadata.suspended_until`, `status='active'`, `payload`, JSON.

---

## §19 — Right y atoms

```
rightCreated
  ↓
rightDelegated (proxy)
  ↓
rightExercised (delegate uses)
  ↓
rightTransferred (sale)
  ↓
rightSuspended (admin pause)
  ↓
rightRestored (admin lifts)
  ↓
rightExpired (cron)
        ↓
right_holders_view (current holder + delegate + state)
```

---

## §20 — Filosofía Talmúdica / legal

La ley **no** gobierna "permisos abstractos". Gobierna:

- propiedad (ownership)
- posesión (possession)
- usufructo (usus + fructus)
- acceso (access)
- uso (use)
- ocupación (occupancy)
- licencia (license)
- temporalidad (expires_at)
- transmisibilidad (transferable, divisible)
- delegabilidad (proxy, agency)

Ruul modela exactamente eso. El `right` es la **encarnación digital** del derecho subjetivo clásico — con identidad propia, history, lifecycle, transmisión y consecuencias.

---

## §21 — Decisiones NO negociables

### Sí

- rights como resources polimórficos universales (no tabla propia)
- 3-status machine: active / revoked / expired
- suspended_until como marker temporal, NO status (separación canónica)
- atoms append-only por cada gesture lifecycle
- holder default = caller cuando no se especifica (mig 00201)
- service_role bypass para crons (mig 00200)
- holder + admin para transfer/delegate; admin para revoke/suspend/restore (mig 00206)
- archive soft-delete; rights sobreviven a sus targets
- no auto-lift de suspensión (consentimiento explícito)

### No

- tabla `rights` separada
- subtype tables (`memberships`, `vetoes`, `equity_shares`)
- arrays JSON de holders ("holders": [...])
- status flag para "suspended" (eso es marker, no estado)
- silent revoke por crons (cron solo expira, no revoca)
- delete real de rights (siempre archive)
- transfer/delegate sin atom (cada gesture deja huella)

---

## §22 — Resultado esperado

El sistema debe poder modelar:

- membresías de club/coworking/asociación
- voting shares de equity / governance tokens
- day passes / invitados externos
- equity vesting (cliff + linear, con divisible rights)
- custody assignments de assets
- tesorería de funds (approval authority)
- vetoes founder sobre transfers grandes
- prioridad de booking (founder first pick)
- delegated proxies para voting/approval
- licencias temporales (uso preferente N días)

**SIN crear nuevos resource types** y **SIN tabla ACL paralela**.

---

## §23 — Backend reference (canónico al 2026-05-18)

| Pieza                                    | Migración             | Detalle                                                  |
|------------------------------------------|----------------------|----------------------------------------------------------|
| `create_right` RPC + 8 atoms             | `00198`              | Right resource canonical foundation                      |
| `right_holders_view`                     | `00198`              | Single projection — sin tabla cache paralela             |
| `update_right_metadata` + cron expire    | `00199`              | Whitelist 11 fields editables; hourly expire cron        |
| Lifecycle service_role relaxation        | `00200`              | RPCs aceptan auth.uid()=NULL para crons                  |
| Default holder = caller                  | `00201`              | create_right sin holder asigna al caller                 |
| Expiration warning template + cron       | `00203` (mig 206)    | rightExpiringSoon + notify cron + rule template          |
| Holder/admin gate hardening              | `00206`              | transfer/delegate require holder OR admin                |
| Permissions founder default (5)          | `00255`              | transferRight/delegateRight/revokeRight/suspendRight/exerciseRight |
| Push lifecycle notifications             | `00254`              | on_right_lifecycle_notify trigger → APNs                 |
| Push expiring soon                       | `00253`              | on_right_expiring_soon_notify trigger → APNs             |
| Atoms whitelist restore                  | `00219`              | Regression fix: 9 right atoms re-added                   |

### iOS surface

- Model: `Right` (vía `ResourceRow.decodeAsRight()` polimórfico)
- Repo: `RightRepository` (Mock + Live) — 7 funcs lifecycle + updateMetadata
- UI: `RightActionSheet` (6 actions) + `EditRightSheet` (10 knobs admin)
- Wizard: `RightResourceBuilder` (6 fields: name + holderMemberId optional + transferable/delegable/exclusive toggles + targetResourceId optional)
- Routing: `UniversalResourceDetailView` despacha right detail (no view type-specific)

---

## §24 — Definición final

### Right

> Resource persistente que encarna un claim normativo del holder sobre (target × capability) con scope, priority, exclusividad, transferabilidad, delegabilidad, divisibilidad y expiración, gobernable mediante 9 atoms append-only (created/transferred/delegated/revoked/suspended/restored/exercised/expired/expiringSoon) — sin tabla propia, sin status mutable para suspensión, sin ACL paralela. La capa jurídica digital del derecho subjetivo clásico.

Ese es el modelo canónico de `right` en Ruul.

---

## §25 — Definition of Done

Right.md está canónico cuando:

- [x] Definición ontológica + cardinal principle + qué NO es
- [x] Polimorfismo total documentado (target × capability × scope) con tabla de combinaciones
- [x] 5 ejemplos canónicos con knobs explícitos (membresía / equity / day pass / tesorero / veto)
- [x] Status machine (3 estados: active/revoked/expired) — suspended NO es status
- [x] Atoms documentados (9 con payloads completos)
- [x] Projection `right_holders_view` documentada
- [x] Permission gates per RPC (mig 00200 + 00206 hardening)
- [x] Cron behavior (expire_due_rights + notify_rights_expiring_soon) con idempotency
- [x] No auto-lift de suspensión — doctrina §4.G consentimiento explícito
- [x] Divisible rights — Phase 2 future documentado
- [x] Multi-layer doctrine (right grants_access_to / grants_authority_over / governs)
- [x] Backend reference table completa (mig 00198→00255)
- [x] UI surface documentada (RightActionSheet + EditRightSheet) sin conflar capability con surface
- [x] TalmudicGovernance §4 audit: 8/8 pass (con §4.D partial documentado — target_capability textual no FK, intentional defer)
- [x] Definición final one-sentence
- [ ] **Phase 2 follow-up**: divisible rights con ledger integration cuando equity vesting demande
- [ ] **Phase 3 follow-up**: rule engine consume rights en authorization (hoy implícito, no aterriza)
- [ ] `RightRules.md` companion (mirror de AssetRules/SpaceRules) cuando aterricen 2+ templates

---

## §26 — Known Issues (canonical doctrine debt)

### #1 — target_capability is text, not FK (TalmudicGovernance §4.D partial)

**Síntoma:** `metadata.target_capability` es texto libre sin FK a `public.capabilities`. Permite typos silenciosos ("votting", "acces"). Mig 00198 explícitamente intentional defer.

**Doctrina afectada:** §4.D (Capabilities ≠ Resources) está OK conceptualmente, pero la integridad referencial falta. Es un trade-off entre flexibility (rights pueden referir capabilities futuras) y safety (typos rompen rule matching).

**Remediación:** Cuando el catálogo se estabilice y rule engine consume rights activamente, agregar CHECK constraint o FK validation. Por ahora documentado como aceptable deferred.

### #2 — Rule engine NO consume rights todavía

**Síntoma:** Rights existen como records canónicos, pero el rule engine no los consulta para authorize actions. Hoy authorization vive en RPC gates (`has_permission`, `is_group_admin`); rights son metadata + history rica, pero su weight en decisiones runtime es mínimo.

**Remediación:** Phase 3 slice — integrate rights query en authorization helpers (`has_permission` extended a `has_permission_via_right`). Por ahora rights son source-of-record canónico para auditoría; engine real consumption deferred.

### #3 — RightRules.md companion ausente

**Síntoma:** Asset, Space tienen rule templates docs companion. Right tiene 1 template shipped (`right_expiration_warning` mig 00203) pero sin doc canónico.

**Remediación:** Mirror de shape SpaceRules.md cuando aterricen 2+ templates más (e.g., "transfer requires vote", "high-value right needs audit").
