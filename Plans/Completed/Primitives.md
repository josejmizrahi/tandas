# Ruul — Arquitectura canónica

> **Ruul es un runtime social gobernable.** No es una colección de
> verticales (DinnerApp / TandaApp / PalcoApp); crece con primitives
> componibles, no con apps nuevas.
>
> Status: **canónico desde 2026-05-09**. Actualizado para reflejar la
> visión final del founder. Cualquier sesión (humana o IA) que
> trabaje en Ruul lee este doc + `Roadmap.md` + `AtomProjection.md`
> antes de tocar código.

---

## La fórmula

```
Identity
→ Membership
→ Group
→ Template
→ ModuleRegistry
→ CapabilityResolver
→ Resource
→ Rule
→ Atom
→ Projection
→ UI
```

Esa es la cadena completa. Cualquier feature nueva se ubica en uno
de estos 11 nodos, NO crea un nodo nuevo paralelo.

---

## 1. Núcleo (L1)

| Primitive | Definición | Estado FE+BE |
|---|---|---|
| **Identity** | Persona persistente. `auth.users` + `profiles`. | ✅ |
| **Membership** | Relación Identity ↔ Group. roles, estado, joined_at. | ✅ |
| **Group** | Comunidad persistente. nombre, miembros, settings, governance base. | ✅ |
| **Template** | Preset inicial. **Solo arranca configuración** — no define el futuro del grupo. | ✅ |
| **ModuleRegistry** | Catálogo de capacidades disponibles. `public.modules` (mig 00060) + `list_modules()` RPC. | ✅ |
| **CapabilityResolver** | Runtime que decide qué se puede hacer según group + modules + membership + role + policy. iOS struct + `has_permission()` server. | ✅ |

---

## 2. Resource — objeto gobernable

**Regla canónica**:

> Algo es Resource si y sólo si tiene gobernanza propia: rules,
> votes, history, lifecycle, disputes.

### Es Resource

`event`, `trip`, `expense`, `fund`, `contribution`, `payout`,
`rotation`, `assignment`, `asset`, `slot`, `booking`,
`guest_pass`, `proposal`.

### NO es Resource

`Identity`, `Membership`, `Notification`, `Permission`, `Policy`,
`Capability`. Son canales, relaciones, identidades o configuración —
no objetos con gobernanza propia.

### Estado actual

| Resource type | Estado | Phase |
|---|---|---|
| `event` | ✅ vivo | V1 |
| `slot` / `booking` / `asset` / `guest_pass` | ❌ | Phase 2 |
| `rotation` / `assignment` | ❌ | Phase 2 |
| `fund` / `contribution` / `payout` | ❌ | Phase 3 |
| `expense` | ❌ | Phase 4 |
| `proposal` | ❌ | Phase 5 |
| `trip` | ❌ | Phase 2/4 (TBD) |

`public.resources` table es polimórfica via `resource_type` — añadir
un tipo nuevo NO requiere schema migration; sólo case nuevo en
`ResourceType` enum (codegen) + repos específicos del tipo.

---

## 3. Rule

```
WHEN trigger
IF condition
THEN consequence
```

Engine determinístico server-only en
`supabase/functions/_shared/ruleEngine.ts`. Persistido en
`public.rules` (platform-only post-mig 00058):
`id, group_id, slug, name, is_active, trigger, conditions,
consequences`.

### Ejemplos

```
WHEN event_closed
IF member_no_show
THEN issue_fine

WHEN contribution_due
IF payment_missing
THEN issue_fine

WHEN slot_starts
IF member_absent
THEN release_slot + sanction
```

V1 implementa los 5 evaluators de `recurring_dinner`. Phase 2+
añaden evaluators nuevos (slot, contribution, payment) sin cambiar
el shape del Rule.

---

## 4. Atom + Projection

**Atom** = hecho autoritativo append-only.
**Projection** = vista derivada / cacheable / rebuildable.

**La UI nunca es source of truth.** UI lee projections; mutations
escriben atoms; projections se recomputan.

| Atom | Projection |
|---|---|
| `SystemEvent` | History feed |
| `VoteCast` | `vote_counts_view` / Decision |
| `LedgerEntry` (Phase 3) | `balances_projection` |
| `RSVPAction` | Attendance summary |
| `Contribution` (Phase 3) | Fund status |
| `AssignmentChange` (Phase 2) | Current assignment |
| `FineIssued` | Member reputation |

Marker protocols en
`ios/Packages/RuulCore/Sources/RuulCore/PlatformModels/AtomProjection.swift`
+ doc canónico en `Plans/Active/AtomProjection.md`.

---

## 5. Governance + Consequences

```
Governance
├── Role
├── Permission
├── Policy
├── Proposal
├── Vote
├── VoteCast
├── Decision
└── Appeal

Consequences
├── Fine
├── Sanction
├── Reward
├── Badge
├── Warning
├── Notification
└── StatusChange
```

**Conceptualmente**: `Vote` y `Fine` son instrumentos derivados de
`Rule + Resource + Role`. No son atoms independientes — son cómo
las primitives se materializan en decisiones y consequences.

### Estado actual

| Layer | Primitive | Estado |
|---|---|---|
| Governance | Role | ✅ (mig 00063) |
| Governance | Permission | ✅ (`Permission` enum) |
| Governance | Policy | ⚠️ implícito en `groups.governance` jsonb; falta unificar |
| Governance | Proposal | ❌ Phase 5 |
| Governance | Vote | ✅ |
| Governance | VoteCast | ✅ atom |
| Governance | Decision | ✅ projection (`vote_counts_view`) |
| Governance | Appeal | ✅ |
| Consequences | Fine | ✅ |
| Consequences | Sanction | ❌ Phase 5 |
| Consequences | Reward / Badge | ❌ Phase 5 |
| Consequences | Warning | ❌ |
| Consequences | Notification | ✅ |
| Consequences | StatusChange | ⚠️ implícito vía SystemEvent |

**Cuando lleguen Sanction/Reward/Badge en Phase 5**: NO crear
tablas paralelas. Polymorfizar `Consequence` con
`consequence_type`. Misma forma derivada que Fine sigue hoy.

---

## 6. Estructura de datos canónica

### Tablas vivas hoy (post-cleanup mig 00064)

```
auth.users
profiles
groups
group_members
templates
modules
resources
rules
votes
vote_casts
fines
fine_review_periods
appeals
system_events
user_actions
events
event_attendance
invites
notification_tokens
notifications_outbox
otp_codes
```

### Por venir (Phase 2+)

```
ledger_entries          -- Phase 3 atom
balances_projection     -- Phase 3 projection
contributions           -- Phase 3 atom
payouts                 -- Phase 3 atom
slots                   -- Phase 2 (puede vivir polymorfico en resources)
bookings                -- Phase 2 (idem)
sanctions               -- Phase 5 (o consequence polymorfica)
rule_versions           -- Phase 5 (custom rules con history)
rule_snapshots          -- Phase 5
analytics_events        -- Phase 6 (probablemente fuera de Postgres)
```

---

## 7. Estructura lógica de un Group

```
Group
├── Identity / Membership
├── Active Modules            ← computed runtime via CapabilityResolver
│   ├── Events
│   ├── RSVP
│   ├── Rotation
│   ├── Booking
│   ├── Expenses
│   ├── Fund
│   ├── Votes
│   ├── Fines
│   └── History
│
├── Resources                 ← polymorphic public.resources
│   ├── Event
│   ├── Trip
│   ├── Expense
│   ├── Fund
│   ├── Slot
│   ├── Booking
│   ├── Assignment
│   └── Proposal
│
├── Rules                     ← public.rules (platform-only)
├── Governance                ← groups.governance + groups.roles jsonb
├── Atoms                     ← system_events, vote_casts, ledger_entries…
├── Projections               ← *_view + computed
└── UI                        ← consume projections only
```

---

## 8. La promesa de producto — sin verticales

Un solo grupo, "Los Cuates", puede tener simultáneamente:

- cenas semanales (events module)
- viajes (trip resource)
- gastos compartidos (expense module)
- fondo común (fund module)
- rotación de host (rotating_host module)
- palco compartido (asset + slot module)
- invitados con permisos limitados (guest_pass)
- votaciones para decisiones grupales
- multas automáticas
- historia completa

**Sin crear** "Los Cuates - Cenas" / "Los Cuates - Viajes" /
"Los Cuates - Gastos" como grupos paralelos. Un Group, N modules
activos, M resources de varios tipos.

Ése es el test. Si la arquitectura no soporta esto, no es Ruul.

---

## 9. Flujo correcto end-to-end

```
Template crea defaults
  ↓
Group activa modules (set_group_module RPC, cascade dinámico)
  ↓
CapabilityResolver decide acciones disponibles
  ↓
User crea Resource
  ↓
Resource emite Atom / SystemEvent
  ↓
Rule engine evalúa (process-system-events cron)
  ↓
Consequences crean Fine / Vote / Notification / etc.
  ↓
Projections actualizan UI
  ↓
History preserva memoria (system_events append-only)
```

Cada paso es testeable independientemente. Ningún paso muta state
fuera del log atómico.

---

## 10. Principio terminal

```
Ruul NO crece con verticales:
  ❌ DinnerApp
  ❌ TandaApp
  ❌ PalcoApp
  ❌ TravelApp

Ruul SÍ crece con primitives:
  ✅ Group
  ✅ Modules
  ✅ Resources
  ✅ Rules
  ✅ Atoms
  ✅ Projections
```

**Cualquier PR que viole este principio se bloquea en revisión.**
Si la primitiva nueva no encaja en uno de los 11 nodos del § "La
fórmula", la respuesta es "no es Ruul" — replantear el caso de uso
hasta que sí encaje.

---

## 11. Estado de la arquitectura — gap report

**Verde FE+BE post-Gaps 1-4** (todos los L1):

- Identity, Membership, Group, Template, ModuleRegistry,
  CapabilityResolver, Resource (polymorphic), Rule (platform-only),
  SystemEvent (Atom), VoteCast (Atom), Atom/Projection markers.

**Foundation done, awaiting consumers**:

- `RoleStack` (mig 00063): `groups.roles` jsonb + `Permission`
  enum + `has_permission()` RPC + `GovernanceServiceProtocol.hasPermission`.
  RLS rewire from hardcoded role names → `has_permission()` deferred
  to Phase 5.
- `seed_template_rules` genérico (mig 00062) — Phase 2 templates
  escriben `templates.config.defaultRules` y los rules se seedean
  sin RPC nueva.

**Falta para Phase 2** (Slot / Booking / Asset / Rotation):

- `ResourceType` cases: `slot`, `booking`, `asset`, `assignment`,
  `position`, `rotation`. Codegen en SystemEventType +
  ConditionType + ConsequenceType.
- Modules nuevos: `slot_assignment`, `rotating_position`,
  `slot_swap_request`. Declarados en `modules` table; iOS lee via
  `LiveModuleRegistry`.
- Vistas iOS específicas (SlotDetailView, AssignSlotSheet, etc.).
- Template `shared_resource` con `defaultModules`,
  `defaultGovernance`, `defaultRoles`, `defaultRules`.

**Falta para Phase 3** (Pool / Fund / Tanda):

- Atoms nuevos: `LedgerEntry`, `Contribution`, `Payout`.
- Projection: `balances_projection` (matview o view).
- Module `pool_contribution` + `pool_rotation`.
- Template `pool` con localizaciones (tanda / susu / hui /
  comité / tontine).

**Falta para Phase 5** (Custom rules + roles UI + Sanction/Badge):

- `GroupRolesSheet` UI para founders.
- `assign_role` RPC.
- RLS rewire → `has_permission()`.
- Polymorphic `Consequence` table (fine + sanction + reward + badge).
- `rule_versions` + `rule_snapshots` para custom rules con history.
- `Proposal` formal primitive.

---

## 12. Cuándo modificar este documento

- Cuando la cadena de la fórmula del § 1 cambie (raro — sólo si
  emerge una primitive L1 nueva).
- Cuando el set de Resource types crezca (Phase 2+ ships nuevos
  cases).
- Cuando la regla del § 2 (qué es / no es Resource) gane casos
  límite con experiencia real.

**No** se modifica para registrar tareas, sprints, o decisiones
puntuales — eso vive en `Roadmap.md`, `Phase2Readiness.md`, ADRs.

---

## 13. Referencias cruzadas

- `Plans/Active/Roadmap.md` — fases temporales y features.
- `Plans/Active/Phase2Readiness.md` — entry point Phase 2.
- `Plans/Active/AtomProjection.md` — pattern Atom/Projection +
  classifications.
- `Plans/Active/RolesV2.md` — Phase 5 roadmap del role-stack.
- `Plans/Active/GovernanceRulesJsonb.md` — Phase 4 unificación
  Policy/Roles.
- `Plans/Active/SystemEventsArchival.md` — Phase 4 archival.
- `Plans/Active/Beta1.md` — observación cualitativa post-launch.
- `ios/Packages/RuulCore/Sources/RuulCore/PlatformModels/` —
  modelos Swift de las primitives L1/L2.
- `ios/Packages/RuulCore/Sources/RuulCore/PlatformModules/` —
  ModuleRegistry + LiveModuleRegistry.
- `ios/Packages/RuulCore/Sources/RuulCore/Capabilities/` —
  CapabilityResolver.
- `supabase/functions/_shared/ruleEngine.ts` — engine determinístico.
