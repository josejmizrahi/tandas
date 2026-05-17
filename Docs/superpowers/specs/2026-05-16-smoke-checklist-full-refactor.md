# Smoke Checklist — End-to-End del Refactor Jerárquico

**Fecha:** 2026-05-16
**Cobertura:** 11 niveles (L0, L1, L2, L3, L5, L8, L9, L10, L11, L12, L15) — 22 tags shipped.
**Branch:** `main` @ `4e4be69` (origin sincronizado).
**Build:** Xcode 16+ green, ~95 commits ahead de baseline pre-refactor.

## Setup mínimo

1. Boot iOS 26+ simulator (`xcrun simctl boot 'iPhone 17 Pro'`).
2. Build & launch app: `xcodebuild -project ios/Tandas.xcodeproj -scheme Tandas -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -quiet build && xcrun simctl install booted ...`.
3. Sign in con teléfono/Apple/email.
4. Crear o entrar a un grupo con ≥2 miembros + ≥1 evento futuro + ≥1 multa.

---

## Nivel 0 — Identity

### Pass 1 (structural)
- [ ] Tab **"Yo"** muestra header limpio: avatar + nombre + "Miembro de N grupos"
- [ ] **NO aparece** "TODO AL CORRIENTE / $X PENDIENTE" en header (eso era pre-refactor)
- [ ] **NO aparece** sección "Este Grupo" al fondo (movida a GroupHome)
- [ ] Secciones visibles: TU ACTIVIDAD · IDENTIDAD · PREFERENCIAS · NOTIFICACIONES · AJUSTES · APARIENCIA · signout
- [ ] Theme picker (Apariencia) cambia el modo en vivo
- [ ] Botón "Cerrar sesión" → revoke APNs + sign out

### Pass 2 (wire-up)
- [ ] **IDENTIDAD** muestra teléfono + email
- [ ] Tap "Teléfono" → `ChangePhoneFlow` (2 steps OTP)
- [ ] Tap "Correo" → `ChangeEmailFlow` (2 steps OTP)
- [ ] **PREFERENCIAS** tap "Idioma" → `LanguagePickerView` con 5 BCP-47, persiste
- [ ] Tap "Zona horaria" → `TimezonePickerView` filterable (busca "Tokyo"), persiste
- [ ] Cambiar idioma rota dates en otras views vía `\.locale`

---

## Nivel 1 — Group

### Pass 1 (GroupHome consolidation)
- [ ] **Tap nombre del grupo** en HomeView header → abre `GroupHomeView` (no la antigua `GroupInfoSheet`)
- [ ] Hero: avatar + nombre + invite code + member count + botón "Compartir"
- [ ] Secciones: RESUMEN (Nivel 12) · CONFIGURACIÓN · COMUNIDAD · AVANZADO
- [ ] CONFIGURACIÓN tap "Reglas del grupo" → entra a `GovernanceView` (sin nested NavStack bug)
- [ ] CONFIGURACIÓN tap "Presets de reglas" → entra a `RulePresetsView`
- [ ] Back button en cualquier subscreen funciona correctamente
- [ ] **GroupInfoSheet** + **GroupSettingsSheet** ya NO existen como archivos

### Pass 2 (wire-up)
- [ ] CONFIGURACIÓN tap "Nombre y foto" → `EditGroupIdentitySheet` (rename + descripción + PhotosPicker)
- [ ] Tap "Moneda" → `GroupCurrencyPickerView` (9 currencies LATAM/global), persiste
- [ ] Tap "Zona horaria" → `GroupTimezonePickerView` (shared con Nivel 0 via `RuulUI.TimezonePicker`)
- [ ] Tap "Módulos" → `ModulesPickerView` con 5 toggle (basic_fines, rotating_host, rsvp, check_in, appeal_voting); conflicts/deps bloquean
- [ ] AVANZADO tap "Rotar código de invitación" → `RegenerateInviteCodeSheet` con confirm + nuevo code + ShareLink

---

## Nivel 2 — Membership

### Pass 1 (list vs admin split)
- [ ] Como **admin** (founder) tap "Miembros" en COMUNIDAD → `MembersAdminView` con drag-reorder + swipe-kick
- [ ] Como **member regular** tap "Miembros" → `MembersListView` read-only sin acciones destructivas
- [ ] Cada row tap → `MemberDetailView` con hero + roles + joined date
- [ ] **EditMembersSheet** ya NO existe como archivo

### Pass 2 (bulk invite + self-leave)
- [ ] Admin: GroupHome COMUNIDAD muestra row "Invitar miembros" → `InviteMembersFromGroupView` (share-link + phone + pending invites)
- [ ] Admin: MembersAdminView toolbar "+" abre el mismo flow
- [ ] AVANZADO "Salir del grupo" → `LeaveGroupConfirmationSheet`
- [ ] **Si soy único admin** → blocker "Eres el único admin" (no destructive button)
- [ ] **Si NO soy único admin** → confirmation destructive → leave funciona

---

## Nivel 3 — Resource

### Pass 1 (Fund/Space/Right detail views)
- [ ] Crear un Fund vía ResourceWizard → tap detail → `FundDetailView` (hero + currency + status + goal si aplica)
- [ ] Crear un Space → tap detail → `SpaceDetailView` (hero + capacity + address)
- [ ] Crear un Right → tap detail → `RightDetailView` minimal scaffold
- [ ] Event tap detail → `UniversalResourceDetailView` eventBodyInner (rich existing)
- [ ] **Nota**: Right todavía routea a eventBodyInner por el merge con upstream's `activeRightAction` sheet — esperado

### Pass 2 (HomeView polimórfico + cover chrome)
- [ ] HomeView "PRÓXIMAS ACTIVIDADES" feed merge eventos + recursos no-event (chronological order)
- [ ] Events render como `EventRow` con RSVP badge
- [ ] Otros recursos render como `resourceCard` con chrome
- [ ] Cover height en `UniversalResourceDetailView` viene de `ResourceTypeChrome.coverHeroHeight` (no switch hardcoded)

---

## Nivel 5 — Capability

### Pass 1 (Manage + config edit)
- [ ] Resource Detail → SettingsSection → tap "Manejar capabilities" → `ManageCapabilitiesSheet`
- [ ] Sección "ACTIVAS" muestra capabilities ON con ⋯ menu
- [ ] Sección "DISPONIBLES" muestra capabilities OFF con "Activar" button
- [ ] Tap ⋯ → menu con "Editar configuración" + "Desactivar"
- [ ] Tap "Editar configuración" → `EditCapabilityConfigSheet` con `BuilderFieldRenderer` cargado con valores actuales
- [ ] Save persiste el config jsonb

### Pass 2 (dependency cascade)
- [ ] **Disable RSVP cuando check_in está ON** → alerta "Esto desactivará también: Check-in" con `[Desactivar todas]` / `[Cancelar]`
- [ ] **Enable check_in cuando RSVP está OFF** → alerta "Activar también: RSVP" con `[Activar todas]` / `[Cancelar]`
- [ ] Cascade resuelve correctamente

---

## Nivel 8 — Governance/Rules

### Pass 1 (edit rule params)
- [ ] Admin tap regla en `RulesView` → `RuleDetailView` muestra "Editar parámetros" navrow
- [ ] Tap → `EditRuleParamsSheet` carga params actuales (e.g. monto + minutos para late_arrival_fine)
- [ ] Cambiar valores + Save → `publishRuleVersion` crea new `rule_versions` row (audit preserved)
- [ ] **Si hay voto pendiente sobre esta regla** → "Editar parámetros" gated/oculto

### Pass 2 (scope picker + resource-scoped)
- [ ] Crear regla desde Acuerdos → step "scopePick" con opción "Todo el grupo"
- [ ] Desde **ResourceRulesSheet** tap "+" toolbar → builder con `initialScope: .resource(id)` (skip step)
- [ ] Regla creada queda scopeada al recurso

---

## Nivel 9 — Workflow/Votes

### Pass 1 (member removal flow)
- [ ] CreateVoteSheet → card "Quitar a un miembro" ahora habilitada
- [ ] Tap → `CreateMemberRemovalSheet` (picker member + reason ≥30 + duración + warning manual-removal)
- [ ] MembersAdminView swipe → "Proponer voto" abre el mismo flow con target prefilled
- [ ] VoteDetailView para vote_type=memberRemoval → `MemberRemovalVoteBody` (target avatar + reason + warning)

### Pass 2 (cancel + manual finalize)
- [ ] Como **creator** de vote recién abierto (sin casts) → VoteDetailView muestra "Cancelar voto" → confirmation → status=cancelled
- [ ] **Si alguien ya votó** → cancel rechazado (`votes_already_cast` error)
- [ ] Como **admin** con vote open + `closes_at < now()` → "Finalizar voto ahora" visible → `finalize_vote` RPC

---

## Nivel 10 — Atom layer

### Pass 1 (MyTimelineView cross-group)
- [ ] Profile → TU ACTIVIDAD tap "Mi línea de tiempo" → `MyTimelineView`
- [ ] Feed agrupado por día (HOY · AYER · HACE 3 DÍAS · ...)
- [ ] Items heterogéneos: RSVP / Check-in / Voto / Movimiento de dinero
- [ ] Cada item: icon kind-specific + label humano + group origin tag + relative time

### Pass 2 (ActivitySection parity)
- [ ] Resource Detail → sección Actividad muestra atoms con copy descriptiva
- [ ] Eventos como `groupRenamed`, `voteResolved`, `fineOfficialized` ya NO aparecen como "Actividad" genérico
- [ ] Misma copy que group-level ActivityView (60+ event types parity)

---

## Nivel 11 — Atom-ish (Inbox)

### Pass 1 (resolved history)
- [ ] Inbox tab → chip nuevo "Resueltas" después de Recordatorios
- [ ] Tap chip → ves historial greyed (opacity 0.6) con "Resuelta hace X" trailing
- [ ] Sin chevron, tap-disabled (pure history)

### Pass 2 (swipe/contextMenu + bulk)
- [ ] **Long-press** en cualquier ActionCard pendiente → context menu "Marcar como hecho"
- [ ] Acción desaparece + analytics fire
- [ ] Toolbar "Marcar todas" (cuando pending count > 1) → confirmation alert
- [ ] Confirm → todas se resuelven secuencialmente
- [ ] Toast "X acciones resueltas" aparece 5s

---

## Nivel 12 — Projections (Dashboard)

### Pass 1+2 (RESUMEN + workflow shortcuts)
- [ ] GroupHomeView muestra **sección RESUMEN** entre hero y CONFIGURACIÓN
- [ ] 3-4 stat tiles: Miembros · Próximos · Mi balance · Multas (si pendientes > 0)
- [ ] Tap "Miembros" → MembersList/Admin
- [ ] Tap "Multas" → MyFinesView
- [ ] COMUNIDAD: si `openVotesCount > 0` → "X votos abiertos" navrow
- [ ] Si `pendingActionsCount > 0` → "Y acciones pendientes" navrow

---

## Nivel 15 — Notifications

### Pass 1 (devices + deeplinks)
- [ ] MyProfileView muestra **NOTIFICACIONES** section entre PREFERENCIAS y AJUSTES
- [ ] Tap "Dispositivos" → `DevicesView` con sección "ESTA SESIÓN" (este iPhone) + "OTRAS SESIONES" (otros tokens)
- [ ] "Revocar sesión" en otro device → token borrado del BE → re-load lista
- [ ] Test deeplinks: `ruul://event/<uuid>` · `ruul://vote/<uuid>` · `ruul://fine/<uuid>` · `ruul://rule/<uuid>?proposedAmount=N` → cada uno routea al detail correspondiente

### Pass 2 (preferences)
- [ ] Tap "Preferencias" → `NotificationPreferencesView`
- [ ] 6 toggles: Votaciones · Resultados · Multas · Eventos · Recordatorios RSVP · Gastos reversados
- [ ] Default ON; toggle OFF persiste vía `set_notification_preference` RPC

---

## Validación cross-cutting

- [ ] **Build clean** — `xcodebuild build` sin warnings
- [ ] **No crashes** en hot path (HomeView → ResourceDetail → SettingsSection → ManageCapabilities → back)
- [ ] **Locale change** propaga a todas las fechas (RelativeDateTimeFormatter usa `app.profile?.locale`)
- [ ] **Tag navigation**: `git checkout level0-pass1-complete` → app construye en ese estado
- [ ] **Modal policy uniforme**: TODO modal es `.fullScreenCover` (no `.sheet` orphaned)

## Si algo falla

- Reportar como issue: `[L{N}] {síntoma} en {pantalla}`
- Probable causa por nivel:
  - **L0-L2**: callsite drift en RootShellSheets / ProfileTab
  - **L3**: routing dispatch en UniversalResourceDetailView line ~40
  - **L5**: BuilderFieldRenderer field key mismatch
  - **L8**: publishRuleVersion params shape
  - **L9**: VoteDetailCoordinator.myRole no inyectado (admin button no visible)
  - **L10**: my_activity_v1 view RLS gate falla → empty feed
  - **L11**: contextMenu no aparece → ActionInboxView se renderea fuera de List context
  - **L12**: groupSummaryRepo no wired en AppState → summary nil → no se renderiza
  - **L15**: dispatch-notifications cron sigue ignorando preferences (Pass 3 pendiente)

## Resumen ejecutivo

**11 capas refactoreadas, 22 tags, ~95 commits, 2 migraciones BE nuevas, 0 build breaks pendientes.**

Cada capa del modelo Constitution (`HierarchyReference.md §1`) tiene Spec + Plan + Implementación shipped y wireable end-to-end. Layers 4, 6, 7 cubiertos transversalmente; 13, 14, 16, 17 quedan como specs futuros (sin tablas BE para los primeros dos, fuera de Beta-1 para los últimos).
