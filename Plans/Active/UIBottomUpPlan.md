# UI Bottom-Up Plan — Páginas específicas → Shell al final

> **Plan complementario activo.** Hermano de `Plans/Active/Plan.md`
> (que cubre la convergencia backend). Este plan rige la siguiente
> fase: construir las páginas iOS específicas de cada primitiva
> antes de armar el shell de navegación. Acordado 2026-05-27.
>
> Doctrina vigente:
> - backend/RPCs son fuente de verdad
> - iOS no escribe tablas directo
> - iOS no conoce joins internos
> - UI Apple-native (iOS 26+ Liquid Glass cuando aplique)
> - slices chicos, mergeables y testeables
>
> Foundation set (Primitivas 1-5 + DecisionRules + Sanctions parcial
> + Reputation RPC + GroupProfileView) cerrado al commit `097964ea`.
> Próximo trabajo arranca desde aquí.

---

## 0. Marco

### Estrategia: bottom-up

Construir las páginas específicas de cada primitiva ANTES de armar
el shell (group switcher + tab bar interno + perfil avatar). Cuando
todas las páginas existan, se monta el shell y se migra la
`GroupHomeView` dashboard actual a "Inicio del grupo" (situational
stream con 5 clusters per `doctrine_group_space_situational`).

### Arquitectura final acordada

```
[▼ Group switcher]                    [Avatar]
─────────────────────────────────────────────
              Inicio del grupo
                  (feed)
─────────────────────────────────────────────
🏠 Inicio · 💰 Dinero · 📦 Recursos · 👥 Miembros · ⚙️ Ajustes
```

- **Group switcher** arriba-izquierda (Calendar/Reminders-style):
  sheet con lista grupos + crear + tengo código.
- **Avatar** arriba-derecha: sheet con perfil personal + ajustes
  personales + cerrar sesión.
- **Tab bar interno DEL grupo** (no nested al root): 5 tabs.
- **Perfil del grupo** accesible desde toolbar "Más" o tap en
  header.
- **Inicio NO es cross-group** — es del grupo actualmente
  seleccionado en el switcher.

### Mapa primitiva → surface

| # | Primitiva | Vive principal en | También en |
|---|---|---|---|
| 1 | Members | Tab Miembros | Header del grupo (count) · Member detail · Inicio (joins recientes) |
| 2 | Boundary | Ajustes → Política de entrada | Inicio (pending invites) |
| 3 | Purpose | Perfil del grupo | Ajustes → Propósito (edit) |
| 4 | Rules | Perfil del grupo (read) | Ajustes → Reglas (edit) · Inicio (reportar rota) |
| 5 | Roles | Ajustes → Roles y permisos | Member detail (chips) |
| 6 | Decision rules | Ajustes → Cómo decidimos | Perfil del grupo (read) · Decision detail |
| 8 | Resources | Tab Recursos | Inicio (en uso esta semana) · Dinero (fondos) |
| 9 | Contributions | Resource detail | Tab Dinero · Member detail |
| 11 | Sanctions | Tab Dinero → Multas | Inicio (necesita atención) · Member detail · Ajustes (política) |
| 12 | Trust/Reputation | Member detail | Historia |
| 13 | Memory/Audit | Historia | Inicio ("Acabó de pasar") · cada detalle |
| 14 | Disputes | Dispute detail | Inicio (activas) · Member detail (reportar) · Ajustes |
| 15 | Entry/Exit | Tab Miembros | Inicio · Historia · Ajustes (boundary) |
| 16 | Decisions/Voting | Decision detail | Inicio (abiertas) · Historia |
| 17 | Permissions | Ajustes → Roles y permisos | Member detail (efectivos) |
| 18 | Ownership | Resource detail → History | Member detail (custodia) |
| 19 | Accounting | Tab Dinero | Inicio (movimientos) · Member detail (balance) |
| 20 | Culture | Perfil del grupo (read) | Ajustes → Cultura |
| 21 | Rituals | Perfil del grupo (read) · Tab Recursos (series) | Inicio (próximo ritual) · Ajustes |
| 22 | Legitimacy | Ajustes → Cómo decidimos | Decision detail (qué método) |
| 23 | Mandates | Ajustes → Mandatos | Member detail (qué representa) |
| 25 | Dissolution | Ajustes → Zona destructiva | Inicio (banner si activo) · Historia |

### Regla mental para nuevas primitivas

¿Cuándo la consulto?
- **Hoy** → Inicio
- **Cuando preguntan qué es el grupo** → Perfil del grupo
- **Ante duda o conflicto** → Historia
- **Para configurar** → Ajustes

---

## 1. Convenciones inviolables

| Regla | Por qué |
|---|---|
| iOS no escribe tablas directo | Doctrina founder: backend = fuente de verdad |
| Toda mutación pasa por RPC canónica | RLS + auditabilidad |
| Views no importan `Supabase` | Aislamiento; solo `RuulCore/Supabase/` lo hace |
| Strings visibles → `L10n.<Namespace>.<key>` | Localización futura |
| Stores `@MainActor @Observable` | Swift 6 concurrency strict |
| Tolerant Codable para enums | Backend forward-compatible no crashea cliente |
| Errores backend → `CanonicalBackendError` → `UserFacingError` | Mensajes ES-MX |
| Slices chicos (1-2 días) y mergeables a `main` | Reversibilidad |
| Commits: `foundation: <verb> <thing>` + Co-Author Claude | Convención repo |
| Cada slice: build green + tests green + device install + push | DoD repo |
| No reintroducir legacy (`RuulFeatures`, `RuulUI`, etc.) | Lean |
| No ContactsUI / Realtime / Push (out of scope) | Fase E lejana |
| Liquid Glass cuando aplique (`.glassEffect()`, `.glassProminent`) | iOS 26 native |
| Append-only se respeta (no `DELETE` en `group_*_versions`, `group_events`) | Schema doctrine |

---

## 2. Estado al cierre del plan (2026-05-27)

- **Branch**: `main`
- **Último commit**: `097964ea foundation: add GroupProfileView`
- **Tests RuulCore**: 186/186 verdes en 29 suites
- **Foundation set**: Primitivas 1-5 + Decision Rules + Sanctions
  (parcial) + Reputation RPC + GroupProfileView ✅
- **Páginas con stores wired listas para usar**:
  - Members (List + Detail history)
  - Purpose (Card + Edit)
  - Rules (List + Card + Edit + Row)
  - Resources (List + Card + Create + Row)
  - Sanctions (List + Card + Issue + Row)
  - Decision Rules (Card + Edit)
  - Disputes (List + Card + Row + Dispute sanction sheet)
  - Foundation Status (Card)
  - GroupProfile (Read-only)
- **Stores en RuulCore**:
  - profileStore, membersStore, purposeStore, rulesStore,
    resourcesStore, decisionRulesStore, sanctionsStore,
    disputesStore, foundationStatusStore, reputationStore,
    moneyStore, currentGroupStore, sessionStore, groupsStore.

---

## 3. Roadmap por fases

### Fase A · Páginas de detalle 🟢 (sin backend nuevo)

#### A1. MemberDetailView
- **Scope**: extender/reemplazar `MemberHistoryView` con sections
  completas: identidad · participación · dinero · reputación ·
  roles · history.
- **Archivos**:
  - Nuevo `RuulApp/Features/Members/MemberDetailView.swift`
  - Modificar `MembersListView.swift` (push hacia MemberDetailView)
  - `L10n.MemberDetail` namespace
- **Stores**: `membersStore`, `reputationStore`, `moneyStore`,
  `sanctionsStore`
- **Apple pattern**: Contacts card scroll + collapsible sections
- **Commit**: `foundation: add MemberDetailView`

#### A2. MoneyDashboardView + sub-vistas
- **Scope**: convertir `MoneyBlock` en página completa con tu
  posición hero + balance + movimientos recientes + multas a pagar.
- **Archivos** (puede ser 2 slices):
  - `MoneyDashboardView.swift` (root)
  - `MoneyMovementsListView.swift` (filtros: gastos · settlements ·
    multas · contribuciones · pool charges)
  - `MoneyMovementDetailView.swift`
  - `DebtsListView.swift` (a quién le debes / quién te debe + CTA
    Liquidar inline)
  - `StakeHistoryView.swift`
  - `PoolChargesListView.swift`
  - `PaySanctionSheet.swift`
- **Backend extra**: posiblemente RPC
  `group_money_movements(p_group_id, p_limit, p_filter)`.
  Verificar si existe; si no, slice backend mini.
- **Apple pattern**: Wallet hero card + transactions list + sheet
  detents
- **Commit**: `foundation: add MoneyDashboardView + movements + debts`

#### A3. ResourceDetailView
- **Scope**: detalle envelope (sin subtype-specific). Identity +
  ownership + activity feed + actions placeholders.
- **Archivos**:
  - `RuulApp/Features/Resources/ResourceDetailView.swift`
  - Modificar `ResourcesListView.swift` (push detail al tap)
- **Stores**: `resourcesStore`
- **Apple pattern**: Wallet card hero + sections
- **Commit**: `foundation: add ResourceDetailView (envelope-only)`

#### A4. SanctionDetailView + AppealSanctionView
- **Scope**: detalle de una multa con info + pay action + appeal
  placeholder.
- **Archivos**:
  - `RuulApp/Features/Sanctions/SanctionDetailView.swift`
  - `RuulApp/Features/Sanctions/AppealSanctionView.swift`
    (UI placeholder; appeal RPC pendiente)
- **Stores**: `sanctionsStore`
- **Commit**: `foundation: add SanctionDetailView + appeal placeholder`

#### A5. GroupHistoryView (Primitiva 13)
- **Scope**: timeline paginated de `group_events`.
- **Backend**: posiblemente RPC
  `group_events_paginated(p_group_id, p_limit, p_cursor)` si no
  existe. Verificar antes.
- **Archivos**:
  - `RuulCore/Domain/GroupEvent.swift`
  - `RuulCore/Repositories/CanonicalEventsRepository.swift`
  - `RuulCore/Stores/EventsStore.swift`
  - `RuulApp/Features/History/GroupHistoryView.swift`
  - `HistoryFiltersSheet.swift` (filtros: dinero · decisiones ·
    miembros · reglas · disputes · todo)
  - `HistoryEventDetailView.swift`
- **Apple pattern**: Photos Memories timeline
- **Commit**: `foundation: add GroupHistoryView + audit timeline`

#### A6. PersonalProfileSheet + PersonalSettingsView
- **Scope**: sheet desde el avatar (hoy accesible vía menu de
  GroupListView mientras el shell aterriza).
- **Archivos**:
  - `RuulApp/Features/PersonalProfile/PersonalProfileSheet.swift`
  - `PersonalSettingsView.swift`
  - `AccountSecurityView.swift` (phone/email change usa
    `AuthService.startPhoneChange/startEmailChange` existentes)
- **Stores**: `profileStore`, `sessionStore`
- **Apple pattern**: Settings.app + Contacts edit
- **Commit**: `foundation: add PersonalProfileSheet + Settings`

### Fase B · Ajustes del grupo (Settings.app pattern) 🟢🟡

#### B1. GroupSettingsView (root)
- **Scope**: Settings.app-style root con sections por categoría.
  Solo links a sub-vistas, sin lógica propia.
- **Archivos**:
  - `RuulApp/Features/GroupSettings/GroupSettingsView.swift`
  - `L10n.GroupSettings` namespace
- **Sections** (solo links inicialmente):
  - Foundation status hint
  - Quién pertenece (Boundary policy · Tipos de membresía · Roles ·
    Mandatos)
  - Cómo nos organizamos (Propósito · Reglas · Decisiones · Cultura ·
    Rituales)
  - Dinero y recursos (Moneda · Política de fondos · Política de
    sanciones)
  - Notificaciones
  - Privacidad
  - Zona destructiva (Salir · Cerrar grupo)
- **Commit**: `foundation: add GroupSettingsView root`

#### B2-B8. Sub-vistas de ajustes (uno por slice)

Cada uno es un slice 1-2 días: backend mig (si aplica) + smoke +
RuulCore wiring + UI + tests + push.

- **B2 BoundaryPolicyView** 🟡 — backend pendiente
  (mig nueva `set_group_boundary_policy`)
- **B3 RolesAndPermissionsListView + RoleEditorView** 🟡 — RPCs
  nuevas: `list_group_roles`, `create_role`, `update_role_permissions`,
  `assign_role_to_member` (existe), `revoke_role_from_member` (existe)
- **B4 MandatesView** 🟡 — Primitiva 23 (tabla
  `group_mandates` existe sin RPCs)
- **B5 CulturalNormsListView + EditCulturalNormView** 🟡 — Primitiva
  20 (tabla `group_cultural_norms` existe sin RPCs)
- **B6 RitualsListView + CreateRitualSheet** 🟡 — Primitiva 21 sobre
  `group_resource_series`
- **B7 NotificationsSettingsView + GroupPrivacyView** 🟡 —
  `notification_preferences` + `groups.visibility_settings`
- **B8 DissolveGroupConfirmation** 🟡 — Primitiva 25 (mig nueva,
  destructive con cuidado)

### Fase C · Primitivas pendientes con backend nuevo 🟡

#### C1. Decisions/Voting (Primitiva 16)
- **Backend**: tablas `group_decisions`, `group_decision_options`,
  `group_votes` existen. Faltan RPCs:
  - `propose_decision(p_group_id, p_title, p_body, p_decision_type, p_options)`
  - `cast_vote(p_decision_id, p_option_id?, p_value?)`
  - `finalize_decision(p_decision_id)`
  - `list_decisions_active(p_group_id)`
  - `decision_detail(p_decision_id)`
- **iOS**:
  - `RuulCore/Domain/GroupDecision.swift` + `Vote.swift`
  - `CanonicalDecisionsRepository` + `DecisionsStore`
  - `DecisionsListView` · `DecisionDetailView` (Apple Mail thread
    pattern) · `ProposeDecisionSheet` · `VoteSheet` (.medium detent)
- **Commit**: `foundation: add Decisions/Voting (Primitiva 16)`

#### C2. Disputes UI completo (Primitiva 14)
- **Backend**: tabla `group_disputes` + `group_dispute_events`
  existen. Migración ya empezada
  (`20260527090000_group_disputes_foundation.sql`). Faltan RPCs si
  no se cerraron en esa mig.
- **iOS** (parcial ya existe):
  - `DisputesListView` ✅ existe
  - `DisputeRowView` ✅ existe
  - `DisputeSanctionSheet` ✅ existe
  - **Faltan**: `DisputeDetailView` (timeline + evidence + mediation),
    `OpenDisputeSheet`, `AddDisputeEvidenceSheet`,
    `ResolveDisputeView`
- **Commit**: `foundation: complete Disputes UI (Primitiva 14)`

#### C3. Contributions (Primitiva 9)
- **Backend**: tabla `group_contributions` existe. RPCs faltantes:
  - `log_contribution(p_group_id, p_kind, p_amount?, p_description, p_resource_id?)`
  - `list_contributions(p_group_id, p_member?, p_resource?)`
- **iOS**:
  - `ContributionsListView` · `LogContributionSheet` ·
    `ContributionDetailView`
- **Commit**: `foundation: add Contributions (Primitiva 9)`

#### C4. Reputation UI completo (Primitiva 12)
- **Backend**: RPC `member_reputation_events` ya existe. Falta
  `record_reputation_event` para UI admin (o se mantiene
  solo backend-triggered).
- **iOS**:
  - `RecordReputationEventSheet` (admin)
  - `ReputationFeedView` (cross-member del grupo)
- **Commit**: `foundation: add Reputation UI (Primitiva 12)`

### Fase D · Shell (al final) 🔴

#### D1. GroupSwitcherSheet
- **Scope**: sheet/popover desde header con lista de grupos + crear
  + tengo código.
- **Archivos**: `RuulApp/Features/Shell/GroupSwitcherSheet.swift`
- **Stores**: `groupsStore`
- **Apple pattern**: Calendar calendar switcher / Reminders list
  switcher
- **Commit**: `foundation: add GroupSwitcherSheet`

#### D2. GroupTabsHost
- **Scope**: TabView interna del grupo con 5 tabs (Inicio · Dinero ·
  Recursos · Miembros · Ajustes). Reemplaza el push directo a
  GroupHomeView.
- **Archivos**:
  - `RuulApp/Features/Shell/GroupTabsHost.swift`
  - `RuulApp/Features/Shell/GroupHomeFeedView.swift` (nueva landing
    simplificada con 5 clusters per
    `doctrine_group_space_situational`)
- **Commit**: `foundation: add GroupTabsHost shell`

#### D3. AppShell (root)
- **Scope**: reemplaza `RuulAppShell` con header group switcher +
  avatar + GroupTabsHost. Migra `GroupListView` a sheet del switcher.
- **Archivos**:
  - Modificar: `RuulAppShell.swift`
  - Migrar: `GroupHomeView` → `GroupHomeFeedView` (situational stream)
- **Commit**: `foundation: replace shell with switcher + tab bar internal`

#### D4. DeepLinkRouter
- **Scope**: `ruul://group/X/decision/Y` → switch grupo + push
  destino.
- **Archivos**: `RuulApp/App/DeepLinkRouter.swift`
- **Commit**: `foundation: add DeepLinkRouter`

### Fase E · Cross-app (separate targets, futuro lejano)

- **E1 WidgetsExtension** — home/lock widgets (separate target)
- **E2 LiveActivityExtension** — Dynamic Island (separate target)
- **E3 ShortcutsIntents** — App Intents para Siri (separate target)
- **E4 SpotlightIndexing** — `CoreSpotlight` cross-group

---

## 4. Templates mentales (úsalos en cada slice)

### Agregar una RPC nueva (backend)

1. Migration en
   `supabase/migrations/YYYYMMDDHHMMSS_<name>.sql`.
2. `CREATE OR REPLACE FUNCTION public.<name>(...)` con
   `SECURITY DEFINER`,
   `SET search_path = 'public', 'pg_catalog'`,
   `#variable_conflict use_column` si hay return TABLE.
3. Auth gate:
   `IF auth.uid() IS NULL THEN RAISE EXCEPTION 'must be authenticated'`.
4. Membership check:
   `RAISE EXCEPTION 'caller is not an active member of group %'`.
5. Permission gate via `assert_permission(group_id, '<perm>')`
   cuando aplique.
6. `REVOKE EXECUTE FROM public, anon` +
   `GRANT EXECUTE TO authenticated`.
7. `COMMENT ON FUNCTION ...` con migration id + propósito.
8. Aplicar con `mcp__supabase__apply_migration` y correr smoke en
   `DO $$` block con
   `set_config('request.jwt.claims', json_build_object('sub', '<uuid>', 'role', 'authenticated')::text, true)`
   para simular usuarios.

### Agregar wiring iOS para una RPC

1. `RPCInputs.swift`: `Encodable` struct con `CodingKeys`
   snake_case (`p_*`).
2. `RPCOutputs.swift` (si shape complejo): DTO + `toDomain()`
   mapper.
3. `Domain/<Type>.swift`: tipos Codable con tolerant decode +
   presentation helpers.
4. `RuulRPCClient.swift`: firma async throws en el protocol.
5. `SupabaseRuulRPCClient.swift`: impl con
   `client.rpc("<name>", params: input)` +
   `RPCErrorMapper.map(error)`.
6. `CanonicalBackendError.swift`: case nueva si hay raise nueva.
7. `RPCErrorMapper.swift`: parse contains-based.
8. `UserFacingError.swift`: copy ES-MX.
9. `MockRuulRPCClient.swift`: case recorded + stub + setter + impl.
10. Si existen preview stubs en views: agregar nueva method.
11. `Repositories/Canonical<Thing>Repository.swift`: thin wrapper.
12. `Stores/<Thing>Store.swift`: `@MainActor @Observable` con
    phase + errorMessage + refresh + intents.
13. `DependencyContainer.swift`: agregar repository + store + init.
14. `L10n.swift`: namespace nuevo con todos los strings.
15. Tests:
    - `Tests/RuulCoreTests/Domain/<Thing>Tests.swift` decoding
    - `Tests/RuulCoreTests/Stores/<Thing>StoreTests.swift` state
      transitions
    - Extender `RPCInputsEncodingTests` + `RPCErrorMapperTests`.

### Agregar una View

1. `RuulApp/Sources/RuulApp/Features/<Feature>/<Name>View.swift`.
2. SwiftUI Apple-native: `Form`/`List` + `Section` + `ToolbarItem`
   + `.searchable` si list.
3. `@Bindable var store: <Thing>Store`.
4. Sheets: `.sheet(isPresented:)` con binding al store o `@State`.
5. Navigation: `NavigationLink(value: <Destination>())` +
   Hashable token + `.navigationDestination(for:)`.
6. Loading/error/empty states via `phase` switch +
   `ContentUnavailableView`.
7. Pull-to-refresh: `.refreshable { await store.refresh(...) }`.
8. `.task { await store.refreshIfNeeded(...) }` para load inicial.

---

## 5. Cheat sheet de comandos

```bash
# Build sim (vía MCP)
mcp__xcode-tools__BuildProject

# Test RuulCore
cd ios/Packages/RuulCore && \
  xcodebuild test -scheme RuulCore \
  -destination "platform=iOS Simulator,name=iPhone 17 Pro"

# Device build + install (iPhone de JJ)
xcodebuild -project ios/Tandas.xcodeproj -scheme Tandas \
  -destination "id=E63668BF-3B28-5F51-B678-519B203E48CC" \
  -configuration Debug \
  -derivedDataPath ios/build/DerivedData build

xcrun devicectl device install app \
  --device E63668BF-3B28-5F51-B678-519B203E48CC \
  ios/build/DerivedData/Build/Products/Debug-iphoneos/Tandas.app

# Commit + push
git add <files>
git commit -m "foundation: <slice description>

<body>

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
git push origin main
```

---

## 6. Orden recomendado

| Sesión | Slice | Backend nuevo |
|---|---|---|
| 1 | A1 MemberDetailView | No |
| 2 | A2 MoneyDashboardView + sub-vistas | Posible mini |
| 3 | A3 ResourceDetailView · A4 SanctionDetailView | No |
| 4 | A5 GroupHistoryView | Posible mini |
| 5 | A6 PersonalProfileSheet | No |
| 6 | B1 GroupSettingsView root | No |
| 7-13 | B2-B8 (uno por sesión) | Sí, varía |
| 14-17 | C1 Decisions · C2 Disputes UI · C3 Contributions · C4 Reputation UI | Sí, fuerte |
| 18-21 | D1 Switcher · D2 TabsHost · D3 AppShell · D4 DeepLink | No backend, shell |
| 22+ | E1-E4 cross-app extensions | Targets nuevos |

---

## 7. Prompt inicial sugerido para la nueva sesión

> Continuando Ruul. Estamos en commit `097964ea` con Foundation set
> cerrado + GroupProfileView. Lee
> `Plans/Active/UIBottomUpPlan.md` para el roadmap completo.
> Doctrina vigente: backend = fuente de verdad, iOS no escribe
> tablas, slices chicos mergeables, Apple-native UI. Hoy arrancamos
> con **A1 MemberDetailView** según el plan. Sigue las convenciones
> del §4 (templates mentales) y §1 (reglas inviolables). Cierra el
> slice con: build green + tests green + device install + commit
> + push a main + actualizar
> `Plans/Active/UIBottomUpPlan.md` marcando A1 como ✅.

---

## 8. Tracking

Marcar cada slice cerrado:

- [x] **Pre-fase** — Foundation set (1-5) + Decision Rules +
      Sanctions parcial + Reputation RPC + GroupProfileView
      (commit `097964ea`)
- [x] A1 MemberDetailView
- [ ] A2 MoneyDashboardView + sub-vistas
- [ ] A3 ResourceDetailView
- [ ] A4 SanctionDetailView + AppealSanctionView
- [ ] A5 GroupHistoryView
- [ ] A6 PersonalProfileSheet + PersonalSettingsView
- [ ] B1 GroupSettingsView root
- [ ] B2 BoundaryPolicyView
- [ ] B3 RolesAndPermissionsListView + RoleEditorView
- [ ] B4 MandatesView
- [ ] B5 CulturalNormsListView + EditCulturalNormView
- [ ] B6 RitualsListView + CreateRitualSheet
- [ ] B7 NotificationsSettingsView + GroupPrivacyView
- [ ] B8 DissolveGroupConfirmation
- [ ] C1 Decisions/Voting (Primitiva 16)
- [ ] C2 Disputes UI completo (Primitiva 14)
- [ ] C3 Contributions (Primitiva 9)
- [ ] C4 Reputation UI completo (Primitiva 12)
- [ ] D1 GroupSwitcherSheet
- [ ] D2 GroupTabsHost
- [ ] D3 AppShell (replace RuulAppShell)
- [ ] D4 DeepLinkRouter
- [ ] E1 WidgetsExtension
- [ ] E2 LiveActivityExtension
- [ ] E3 ShortcutsIntents
- [ ] E4 SpotlightIndexing
