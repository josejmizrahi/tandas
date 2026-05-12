# AppShell — Estructura canónica (Beta 1+)

> Status: **Active** · Owner: founder · Started: 2026-05-12
> Supersede de cualquier referencia previa a "groupsTab/HomeView" como
> entrada paralela a `GroupsListView`. La lista de grupos vive ahora dentro
> del `GroupSwitcherSheet`; Home aterriza directo sobre el grupo activo.

## Filosofía

Cada tab responde a una pregunta del usuario:

| Tab | Pregunta | Fuente de datos |
|---|---|---|
| **Home** | ¿qué importa ahora en este grupo? | `resources[]` + `inbox_items` proyección + `system_events` (preview) + RuleEngine advisory |
| **Inbox** | ¿qué tengo que hacer? | proyección polimórfica sobre `votes` / `fines` / `system_events` con `actor=me AND status=pending` |
| **Create** | ¿qué quieres organizar? | catálogo runtime desde `CapabilityResolver` + `templates.config.resource_catalog` |
| **Activity** | ¿qué pasó? | `system_events` polimórfico, filterable/searchable |
| **Profile** | ¿quién soy across groups? | agregaciones sobre `group_members`, `fines`, `ledger` |

No verticales hardcoded. Toda discriminación por `Resource.resource_type`
+ capabilities habilitadas del grupo, nunca por `switch` en SwiftUI.

---

## Shell layout

```
RootShell
├── Top
│   └── GroupSwitcherHeader        ← visible en Home / Inbox / Create / Activity
│                                     NO en Profile
└── BottomTabs (TabView iOS 26 nativo)
    ├── Home          (.home,     "Inicio",    person.3.fill)
    ├── Inbox         (.inbox,    "Inbox",     tray.fill)
    ├── Create        (.create,   "Crear",     plus.circle.fill)  ← intercept → cover
    ├── Activity      (.activity, "Actividad", clock.arrow.circlepath)
    └── Profile       (.profile,  "Perfil",    person.crop.circle.fill)
```

### GroupSwitcherHeader

Pill superior con `app.activeGroup?.name` + chevron. Tap → presenta
`GroupSwitcherSheet` (ya existe — incluye lista de grupos + "Crear" + "Unirme").

Al cambiar grupo:
- `AppState.activeGroupId` se actualiza (didSet persiste a UserDefaults)
- `onChange(activeGroupId)` en MainTabView dispara `rebuildCoordinators(for:)`
- Todos los coordinators (Home, Inbox, Rules, Profile, GroupHistory) se reconstruyen
- `currentGroupContext` re-evalúa: `resources[]` · `inbox_items` · `capabilityResolver` · `roleStack` · `rules[]` · `defaults` · `balances`

Profile **no** lleva el header porque es cross-group.

---

## 1. Home — centro operativo

```
HomeView
├── NeedsAttention      ← inbox items urgentes contra recursos del grupo
├── Upcoming            ← next occurrences (resources con capability `recurring` o `next_at`)
├── ActiveResources     ← Resource[] del grupo (polimórfico, capability-driven cards)
├── QuickActions        ← buttons generados por CapabilityResolver del grupo
├── SuggestedActions    ← RuleEngine advisory (vacíos → no render)
└── RecentActivity      ← preview top 5 de system_events
```

### Sections

**NeedsAttention** — `inboxCoordinator.actions` filtrados por `urgency ≥ medium OR deadline < 24h`, mapeados a cards polimórficas (RSVPCard / VoteCard / FineCard / etc.). Render driven por `action.actionType` + el resource referenciado, no por resource_type.

**Upcoming** — `homeCoordinator.upcomingEvents` (hoy) + futuro: cualquier `Resource` con campo `next_occurrence` < ventana 14d. Item muestra `time · resource.icon · participants · quickOpen`.

**ActiveResources** — `LiveResourceRepository.list(groupId: active)` polimórfico. `ResourceCard` decide su contenido leyendo capabilities habilitadas del resource (`rsvp` → "8 attending", `rotating_host` → "Daniel hosting", `booking` → "Next: tomorrow"). Sin switch por `resource_type`.

**QuickActions** — `CapabilityResolver.creatableTypes(group:)` → tile por cada `ResourceType` que el template+modules del grupo permite crear. Sin lista fija. Tap → opens ResourceWizard pre-filled con ese type.

**SuggestedActions** — RuleEngine en modo `advisory`: triggers tipo `no_host_assigned_for_next_occurrence`, `fund_balance_below_target`. Si vacío, no render. Phase 2+.

**RecentActivity** — top 5 de `systemEventRepo.list(groupId, limit:5)`, cada uno una línea `actor · verb · object`. CTA "Ver todo" → Activity tab.

### Empty states

- `app.groups.isEmpty` → empty hero "Únete a un grupo o crea uno" con CTAs a sheets existentes (createGroupPresented / joinGroupPresented).
- Grupo sin recursos → empty state con QuickActions prominente.

---

## 2. Inbox — action center

```
InboxView
├── Filter chips: Urgent · Approvals · Votes · Payments · Requests · Confirmations · Reminders
└── ActionList (polimórfica)
```

**Modelo**: `inbox_items` es vista derivada, no tabla nueva. Hoy el
`InboxCoordinator` ya consume `userActionRepo` que proyecta sobre
`votes` + `fines` + `system_events` con `actor=me AND status=pending`.

### Categorías (mapeo)

| Chip | Source |
|---|---|
| Urgent | `actions where priority=high OR deadline < 24h` |
| Approvals | `system_events of permission_request` + booking `approval_required` capability |
| Votes | `actions where actionType ∈ {votePending, ruleChangeApplyPending, appealVotePending}` |
| Payments | `actions where actionType ∈ {finePending, contributionDue, compensationDue}` |
| Requests | swap_request, guest_request, expense_dispute system_events |
| Confirmations | `actions where actionType = rsvpPending` + assignment offers |
| Reminders | timers del RuleEngine con `consequence=notify(actor=me)` |

Acciones inline: `Approve / Reject / Open detail`. Al resolverse, item
pasa de `pending` → `resolved` (no borrado), se mueve a Activity.

---

## 3. Create — polymorphic resource creation

```
CreateCover (ResourceWizard)
├── TypePicker
│   ├── Popular         ← top resource_types creados en este grupo (telemetry)
│   ├── Coordination    ← capabilities: rsvp, rotating_host, assignment, checklist
│   ├── Money           ← capabilities: expense, fund, contribution, settlement
│   ├── SharedThings    ← capabilities: asset, booking, slot, guest_pass
│   ├── Governance      ← votes, proposals, rule edits
│   └── Custom          ← Resource genérico + capabilities ad-hoc
└── Builder (ResourceBuilderRegistry[type])
    ├── Form fields del builder específico
    └── Submit → rpc build_resource_from_draft
```

**Importante** — defaults vienen de `templates.config.defaultRules` del
grupo, nunca hardcoded por `resource_type` (memoria
`feedback_create_flow_defaults`). Tile catalog es **runtime** filtrado por:
1. `modules` habilitados en `group.active_modules`
2. `templates.config.resource_catalog` del template base
3. `has_permission('resource.create.<type>')` del rol del usuario

---

## 4. Activity — memoria viva

```
ActivityView
├── FilterChips: All · Money · Resources · Governance · Members
├── Timeline (agrupado por día)
└── Search (full-text sobre system_events.payload + resource titles)
```

Source única: `system_events` (append-only, polimórfico por `event_type`).
El renderer de cada evento se resuelve por su `event_type` igual que
`ResourceDetail` se resuelve por capabilities.

NO chat, NO replies. Cada línea: `actor · verb · object → resource`.

---

## 5. Profile — cross-group

```
ProfileView
├── MyGroups         ← memberships con quick switch
├── MyBalances       ← sum(fines) + sum(contributions) across groups
├── Participation    ← attendance, hosting, assignments completed
├── Reputation       ← Phase 2/3 (deferred)
├── Notifications    ← APNs preferences
├── Settings         ← privacy, account, identity
└── ConnectedApps    ← deferred
```

Sin GroupSwitcherHeader. Cross-group aggregations calculadas desde
`group_members` join con métricas (fines paid, events hosted, etc.).

---

## ResourceDetail — pieza polimórfica clave

> Memoria `project_resource_detail_capability_driven`: un solo view, secciones
> aparecen desde capabilities. Nunca per-vertical screens.

```
ResourceDetail
├── Header               ← title, resource_type pill, owner
├── Summary              ← derivado de capabilities (next, status, balance…)
├── NeedsAttention       ← inbox_items where reference_id = este resource
├── PrimaryActions       ← CapabilityResolver.primaryActions(resource, me)
├── DynamicSections      ← una sección por capability habilitada
│   ├── RSVPSection         (capability rsvp)
│   ├── MoneySection        (capability basic_fines | expense)
│   ├── BookingSection      (capability booking)
│   ├── GuestsSection       (capability guest_pass)
│   ├── RotationSection     (capability rotating_host)
│   ├── VotingSection       (capability vote | appeal_voting)
│   └── AssignmentsSection  (capability assignment)
├── RulesSection         ← rules scope hierarchy + heredadas (badge de scope)
├── ActivitySection      ← system_events where resource_id = este
└── SettingsSection      ← permissions, notifications, archive, danger
```

### RulesSection en lenguaje humano

- Scope hierarchy: `occurrence > resource > series > group > global_default` (memoria `project_rules_hierarchy`)
- Renderiza cada regla como "Si X → Y" — nunca expone `trigger / condition / consequence` (memoria `feedback_rules_ux_human`)
- Badge muestra de qué scope se hereda

---

## Group Settings (dentro de GroupSwitcher o Profile→Este grupo)

```
GroupSettings
├── Members              ← roles, invites, remove (governed)
├── Governance           ← governance rules kind (memoria project_group_governance_rules)
│                          quién crea recursos / cambia reglas / cambios requieren voto
├── Permissions          ← role × capability matrix (jsonb groups.roles)
├── Defaults             ← edita templates.config.defaultRules para este grupo
├── Modules              ← toggle capabilities (rpc set_group_module)
├── Notifications        ← per-group APNs prefs
└── Advanced             ← archive, transfer ownership, danger
```

Governance es categoría distinta de "behavior rules": meta-reglas
("cambiar una regla requiere voto") viven aquí (rule kind = `governance`).

---

## Fases de implementación

### Fase 1 — Shell rename + chrome (this PR)
- [x] Plan doc
- [ ] Rename tab `.groups` → `.home`, label "Inicio"
- [ ] Home tab body aterriza directo en `HomeView(coordinator: homeCoordinator)`
- [ ] Persistent `GroupSwitcherHeader` mounted en Home/Inbox/Activity (Profile sin él)
- [ ] Empty-state cuando `app.groups.isEmpty`

### Fase 2 — Home sections refactor
- [ ] HomeView estructurado en las 6 secciones canónicas
- [ ] NeedsAttention deriva de `inboxCoordinator.actions` filtrado por urgencia
- [ ] ActiveResources lee `resourceRepo.list(groupId:)` polimórfico (no eventRepo)
- [ ] QuickActions tile catalog desde `CapabilityResolver.creatableTypes(group:)`
- [ ] RecentActivity preview top-5 de `systemEventRepo`

### Fase 3 — Create unification
- [ ] TypePicker en ResourceWizard con las 6 categorías (Popular / Coordination / …)
- [ ] Tile catalog runtime desde modules + template + permissions
- [ ] Builder routing por `ResourceBuilderRegistry`

### Fase 4 — Inbox filter chips
- [ ] Filter chips horizontales en `ActionInboxView`
- [ ] Mapeo `actionType` → chip
- [ ] Inline approve/reject donde aplica (sin push)

### Fase 5 — ResourceDetail polymorphic
- [ ] Un solo `ResourceDetailView`
- [ ] DynamicSections registradas por Capability
- [ ] RulesSection con scope hierarchy + badges
- [ ] Activity feed embebido

### Fase 6 — Profile cross-group
- [ ] MyGroups switcher
- [ ] MyBalances aggregation
- [ ] Participation metrics

---

## DoD por fase

- Compila en Xcode 16+ sin warnings nuevos
- `xcodebuild test` pasa
- Codegen sin diff
- Smoke en simulador iOS 26: cambiar de grupo desde cualquier tab actualiza Home/Inbox/Activity
- Profile sigue accesible sin el switcher
- Empty states (zero groups, zero resources) renderean correctamente

---

## No-goals (explícitos)

- NO Chat / Twitter feed / Slack clone en Activity
- NO dashboard enterprise / lista infinita en Home
- NO Notion-database creator en Create
- NO notifications spam en Inbox
- NO per-vertical screens (sólo polymorphic ResourceDetail)
- NO switch por `resource_type` en SwiftUI

---

## Referencias

- Memoria: `project_four_layer_model`, `project_resource_detail_capability_driven`, `project_rules_hierarchy`, `project_group_governance_rules`, `project_capabilities_vs_rules`, `feedback_rules_ux_human`, `feedback_no_hardcoded_verticals`, `feedback_create_flow_defaults`
- Plans relacionados: `Plans/Active/Taxonomy_Resources_and_Capabilities.md`, `Plans/Active/AtomProjection.md`, `Plans/Active/Phase2Readiness.md`, `Plans/Active/Beta1.md`
