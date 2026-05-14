# Beta 1 Consolidation — Raw Audit Reports

> Generated 2026-05-13 by 5 parallel researcher agents.
> Synthesis + roadmap: [[Beta1Consolidation.md]].
> Each report is verbatim from the agent; preserves file:line refs.

---

# Track A — AppShell / Navigation Audit

## Current shape
Five top-level tabs: **Inicio / Grupo / + (intercept) / Decisiones / Perfil** (`MainTabView.swift:103-128, 197-217`). "+" is a fake tab whose selection is intercepted to present a `fullScreenCover` ResourceWizard (`:176-190`). Group tab contains a sub-tab bar: **Resumen / Recursos / Dinero / Miembros / Más** (`GroupTabView.swift:127-159, 193-209`). Group-level history ("Actividad") and governance surfaces (Acuerdos, Decisiones, Sanciones, Gobierno) live one level deeper under **Grupo → Más** (`GroupMoreSubTab.swift`). Inbox content is folded into the Inicio tab as a "Pendientes" section (`HomeView.swift:583-613`); the standalone `ActionInboxView` exists but is not mounted by the shell. Switching groups happens via `GroupSwitcherSheet` triggered from a `RuulGroupSwitcher` chip rendered inside Inicio, Grupo, and Decisiones (`HomeView.swift:163`, `GroupTabView.swift:111-123`, `MainTabView.swift:343-350`). All chrome inside the NavigationStacks is hand-rolled — every stack hides the system nav bar (`MainTabView.swift:363, 497, 948, 1039`).

## Must-fix (blocker for beta)
- **"Perfil → Historial" routes to the wrong tab.** Callback is `onOpenHistory: { selectedTab = .home }` (`MainTabView.swift:434`) with comment "Activity folded into Home (CTA 'Ver actividad')", but Inicio has no "Ver actividad" CTA in `HomeView.swift` and Activity is documented in `GroupMoreSubTab.swift:62-86` as living under Grupo → Más. The link is dead from the user's POV — file:line `MainTabView.swift:434`. Fix: either route to `selectedTab = .group` and trigger `groupHistoryRoute = true`, or remove the row from Settings entirely.
- **"Necesita atención → Ver todas" reopens the first action instead of a list.** `GroupOverviewSubTab.swift:263-269` calls `onOpenInboxAction(actions.first!)` on tap, which routes into a single detail. There is no "all pendings" surface — the embedded HomeView section is also a top-3 trim. Promised escape hatch ("ver todas") is a lie. Fix: either wire to a real list view (the orphan `ActionInboxView` still exists, `Inbox/Views/ActionInboxView.swift:1`) or remove the affordance.
- **"+" tab has zero context awareness when there's no active group.** `MainTabView.swift:180-184` only fires `creationRoute = true` when `app.activeGroup != nil`; otherwise the tap is silently swallowed and `selectedTab` is reverted — user gets no feedback. With the EmptyGroupsView landing state this is the only path that's silent. Fix: present `createGroupPresented` instead, or disable/hide the "+" tab when groups empty.
- **No deep-link handler for fine / vote / appeal / rule pushes.** `TandasApp.swift:196-203` forwards `onOpenURL` to `app.handleIncomingURL`, and `MainTabView` only observes `pendingEventDeepLink` and `pendingRuleChangeDeepLink` (`:236-241`). Push notifications for `finePending`, `votePending`, `appealVotePending` etc. land in `appDelegate.handleIncomingNotification` (`TandasApp.swift:255-256`) but there is no surfaced inbox-action deeplink path comparable to event/rule. Verify before beta — half of v1's notification surface (fines/votes) may dead-end.

## Should-fix (degrades trust if shipped as-is)
- **Tab name "Decisiones" duplicates Grupo → Más → "Decisiones abiertas"** (`MainTabView.swift:211`, `GroupMoreSubTab.swift:131`). Two entry points to the same `OpenVotesListView`. Either de-duplicate (remove from Más or remove the tab) or rename the tab. The tab also has zero badge when there are open votes (`:339-365` builds no badge), but Más does (`GroupMoreSubTab.swift:131-134`) — inconsistent.
- **`HomeView` still has its own "Próximamente" hero/list + Memoria** (`HomeView.swift:220-282`) while `GroupOverviewSubTab` independently re-derives `upcomingResources` from the same data (`GroupOverviewSubTab.swift:373-381`). Two surfaces show the same upcoming list under different visual treatments. Decide: dashboard in Resumen or hero in Inicio. Pick one.
- **Group switcher chip is in three places, missing in two** — present in Inicio (`HomeView.swift:163`), Grupo (`GroupTabView.swift:113`), Decisiones (`MainTabView.swift:343-350`); absent from Perfil tab (intentional per AppShell.md comment in `SettingsTabView.swift:5`) and absent from "+" intercept (no surface). Acceptable, but Perfil shows a `ProfileTabStub` when there's no active group (`MainTabView.swift:494`) — that stub doesn't help the user create one. Wire to `createGroupPresented`.
- **`HistoryTabView` is orphaned code.** `History/Views/HistoryTabView.swift:1-48` is annotated "No conectado a MainTabView todavía — Fase 4b hará el swap" and is not referenced anywhere; the shell now uses `GroupHistoryView` directly inside the Grupo → Más push (`MainTabView.swift:986-990`). Delete the file or finish the swap.
- **`MainTabStubs.swift` ships `ProfileTabStub`** as the no-active-group placeholder (`MainTabView.swift:494`) — name says "stub", users will see it. Either rename or replace with a real EmptyGroupsView-style screen.
- **`feedRoute` (`MainTabView.swift:48,883-885`) and `MyFeedView` are wired** but no UI surface presents them in the current shell. Either remove or expose.

## Polish (nice-to-have)
- Loading state inconsistency: Inicio shows a real skeleton `HomeViewSkeleton` (`MainTabView.swift:1095-1139`); Grupo / Decisiones use `RuulLoadingState()` (`:1043, :355`); Inbox/Members use `ProgressView()` (`ActionInboxView.swift:28`, `GroupTabView.swift:449`). Pick one.
- Empty state inconsistency: `EmptyGroupsView` (custom hero, `MainTabView.swift:1052-1090`) vs `EmptyStateView` (compact, `GroupTabView.swift:298-302`, `ActionInboxView.swift:64-70`) vs none-at-all for resources subview when only metadata empty.
- Every top-level NavigationStack calls `.toolbar(.hidden, for: .navigationBar)` then re-implements headers manually (`MainTabView.swift:363, 497, 948, 1039`). Pushed destinations like Actividad set `.navigationTitle("Actividad")` (`:988`) but the title is only visible because that one push doesn't hide the toolbar — the inconsistency feels accidental.
- `RuulGroupSwitcher` in Decisiones uses a different init (`activeGroup:`) than Grupo (`activeGroupName:`/`activeCategory:`/`activeInitials:`) — `MainTabView.swift:344` vs `GroupTabView.swift:113-117`. Two APIs for the same component.

## Inconsistencies catalogued
- **modal vs push**: `EditMembersSheet` opens both as a sheet from `GroupInfoSheet.swift:131-140` *and* as a sheet from Settings (`MainTabView.swift:476-482`) — duplicated entry. Group settings (`GroupSettingsSheet`, `GovernanceSettingsView`, `GroupRulesSettingsView`) are all sheets, but `RulesView`/`MyFinesView`/`OpenVotesListView` are pushes. Mental model: "config is a sheet, content is a push" mostly holds, *except* `OpenVotesListView` appears as both a push (groupTab `acuerdosRoute`, `sancionesRoute`, `openVotesRoute`) *and* as direct content in the Decisiones tab (`MainTabView.swift:351`). Same screen, two presentation modes.
- **navigation titles**: 4 of 5 tab roots hide nav bar; only the Actividad push exposes a real large title.
- **empty states**: 3 styles (EmptyGroupsView hero, EmptyStateView card, ProgressView fallback for unknown).
- **loading states**: HomeViewSkeleton (shimmer), RuulLoadingState, raw ProgressView — three.

## Inbox vs Activity vs Home — clarity verdict
**Not clear enough for beta.**
- "Inicio" is *both* the home feed (próximo evento hero) *and* the inbox (Pendientes section embedded, `HomeView.swift:583-613`). The badge on the Inicio tab counts inbox actions (`MainTabView.swift:154-156`) — but the tab is named "Inicio" and visually leads with an event hero. A new user with 3 pending fines sees an event card, not the fines, and a "3" badge with no obvious meaning.
- "Actividad" (history timeline) is buried two taps deep: Grupo tab → Más sub-tab → Historial del grupo row. The Necesita-atención section in Resumen also doesn't link to the history.
- Resumen's `attentionSection` (`GroupOverviewSubTab.swift:247-290`) shows the same Pendientes as Home's "Pendientes" — same list rendered in two visual styles, sourced from the same `inboxCoordinator`. Users will tap one, expect changes to mirror, then get confused.

Verdict: collapse Pendientes into one canonical home — either keep it in Inicio and remove from Resumen, or vice versa. Rename the badge target so the count maps to a visible word.

## Group switcher verdict
**Works, but two integration bugs reduce trust.**
- The sheet (`GroupSwitcherSheet.swift`) is correct: lists groups, sets `app.activeGroupId`, haptic, dismiss.
- However: `groupSwitcherPresented` is on `MainTabView`, but the Grupo tab's switcher chip in `GroupTabView.swift:111-118` fires `onSwitchGroup` which the parent maps to the same sheet — works. The Decisiones tab uses a *different* `RuulGroupSwitcher` init (`MainTabView.swift:344`). One avatar style across tabs is fine but the API drift is a smell.
- Real fricción: after switching, `onChange(of: app.activeGroupId)` rebuilds *every* coordinator (`MainTabView.swift:242-250, 1286-1336`). For a user with 3+ groups switching repeatedly, this is a network burst per tap with no optimistic UI. The HomeViewSkeleton mitigates Inicio only; Grupo shows `RuulLoadingState()` (`MainTabView.swift:1043`).
- No issue on the sheet itself. Switcher is good enough for beta.

## Drafts in working tree
- `ResourceSummaryView.swift` (untracked) replaces the old per-type branching (`EventStatusSummary` / `DetailSummaryView`) per `UniversalResourceDetailView.swift:85-89`. The capability-driven design is sound, but `EventStatusSummary` and `DetailSummaryView` are still in `ios/Tandas/Shell/` (`ls` output) — dead code if the swap shipped, half-finished if not. Verify both are removed before merging.
- `GroupOverviewSubTab.swift` (+343 net lines, biggest diff) — the new dashboard. Looks complete and self-contained.
- `GroupMoreSubTab.swift` — adds `onOpenActivity` linkout (+37 lines). Complete.
- `GroupTabView.swift` — adds wiring for Activity push (+130 lines). Complete.
- `MainTabView.swift` (+14 lines) — adds `groupHistoryRoute`. Minimal/safe.
- `GroupInfoSheet.swift` — −1 line, trivial, complete.
- `project.yml` — 1-line bump, fine.

The whole working-tree set looks like one coherent "fold Activity into Grupo → Más + new Resumen dashboard" change. Ship together; revert as a unit if you back out. The risk is `EventStatusSummary` / `DetailSummaryView` becoming orphans.

## Brutally honest top-3 if shipped today
1. **Inbox identity crisis.** "Inicio" being simultaneously the event hero *and* the inbox *and* duplicated in Resumen's "Necesita atención" is the single biggest source of beta confusion. Pick one canonical home for pendings and remove the other two surfaces. The badge on Inicio counts something the user can't immediately see, and the "Ver todas (N)" button is a soft lie (opens detail of first item, not a list).
2. **Tab count is one too many.** With "+" as an intercept, Decisiones duplicating a Más row, and Perfil mostly a settings shelf, the 5-tab bar feels padded. Either kill the dedicated Decisiones tab (one tap deeper under Grupo → Más → Decisiones abiertas already exists) or kill the redundant Más row. Two voting entry points with different badging behavior will be noticed.
3. **Navigation chrome is hand-rolled across the entire app** (every NavigationStack hides the system bar; titles are bespoke headers). It looks intentional and on-brand, but the Actividad push (`MainTabView.swift:988`) accidentally exposes a real large title, breaking the illusion. Either commit to no-system-toolbars-anywhere (and rip the Actividad title) or to the system pattern. The current mid-way state will read as "two designers" to anyone outside the team.

---

# Track B — Onboarding Audit

## Current first-run path (founder, brand-new device)

1. **Bootstrap** — `BootstrappingView` spinner — 0 decisions — `AuthGate.swift:19`
2. **SignInView** — "Bienvenido de vuelta" — `SignInView.swift:66` — Wrong copy for a first-time user. Must tap "¿No tienes cuenta? → Crear nueva" (line 175) just to find onboarding
3. **WelcomeView** — "Bienvenido a ruul" — 1 decision (Empezar) — `WelcomeView.swift:25` — fine
4. **FounderIdentityView** — Name + avatar — 2 decisions, skip allowed — `FounderIdentityView.swift:16-37` — fine
5. **GroupIdentityView** — Group name + 4 chip suggestions + cover picker — 3 decisions — `GroupIdentityView.swift:9,31,38-43`. Cover is purely cosmetic but blocks visual real estate before the user has any sense of the product
6. **PresetPickerView** — 3 cards: "Reuniones recurrentes / Activo compartido / Empezar de cero" — irreversible in UX — `PresetPickerView.swift:22-29` — auto-advances 350 ms after tap; user can't un-pick a preset
7. **InviteMembersView** — Share link + contacts picker — 2 decisions, skip allowed — `InviteMembersView.swift:14-19` — "Mínimo 3 personas" subtitle is a lie; skip is one tap
8. **ConfirmationView** — "Tu grupo está vivo" — 3 CTAs — `ConfirmationView.swift:58-63`

Total: 7 visible screens after sign-up, 9+ decisions.

## Friction inventory by flow

### Sign-up
- AuthGate `AuthGate.swift:32` routes new device to SignInView, not a welcome. SignInView shows "Bienvenido de vuelta" (returning-user copy). The "Crear nueva" link (`SignInView.swift:175`) is below the fold and styled as small body text.
- Apple Sign In + Phone OTP both auto-create accounts (`AuthGate.swift:31`), but the UI says "Inicia sesión", which a first-timer will read as "I don't have one yet" and abandon.

### Create group
- 3 steps (identity → group → preset) before a group exists. Cover picker (`GroupIdentityView.swift:38-43`) is visual-noise for a parent-grade user.
- Preset cards are not visually equivalent: "Reuniones recurrentes" silently activates `basic_fines + rotating_host + rsvp + check_in + appeal_voting` (5 modules) — see `00021_templates_table.sql` `defaultModules`. "Empezar de cero" ships zero, no rules seeded (`FounderOnboardingCoordinator.swift:182`). Massive behavior delta with zero copy difference.
- Auto-advance on preset tap is hostile (`PresetPickerView.swift:41`). No back button on this step (only goBack from confirm); the user is committed.

### Invite + Join
- ShareLink (`InviteMembersView.swift:56-86`) outputs `https://ruul.app/invite/<code>` (`InviteLinkGenerator.swift:21`). AASA isn't live (per the docstring in `InviteLinkGenerator.swift:8`). Tapping the link in WhatsApp opens Safari to a 404; the invitee has nowhere to go.
- Custom scheme `ruul://invite/<code>` exists (`InviteLinkGenerator.swift:13`) but isn't sent in the share message.
- Once the invitee installs the app, they must use `JoinGroupSheet` (`JoinGroupSheet.swift:80-88`) and type the code by hand. The share message includes the URL but no plaintext code, so they're copy-pasting a URL the app can't open.

### First event
- `CreateEventView.swift` has 6 sections rendered at once (cover, title, date, location, host, description, rules toggle). No progressive disclosure.
- `applyRules` toggle (`CreateEventView.swift:171-177`) is pre-ticked because the dinner template enables `basic_fines`. Copy: "Si está apagado, este evento no genera multas al cerrarse" — leaks engine vocabulary ("eventos", "multas", "cerrarse") and assumes the user has a mental model of event lifecycle.
- Host section (`CreateEventView.swift:135-161`) shows "Próximo en orden" without naming who. Phase 2 placeholder, but it ships today.

### First rotation
- Auto-on for "Reuniones recurrentes" preset. The user did NOT consent to rotation; it appears in CreateEventView with no explanation.
- The user can disable rotation only via Group settings → Modules — five taps deep. Memory note `feedback_create_flow_defaults.md` explicitly forbids this; the dinner template breaks it.

### First RSVP
- Term "RSVP" is never defined to the invitee. `InvitedVerifyView.swift:14-15` mentions "recordatorios y multas si aplica" before the user has even joined. Punitive vibe at OTP screen.

### First reminder
- No user configuration in any onboarding screen. Reminders ship as a dinner-template rule with `triggerEventType: .hoursBeforeEvent` and fines pre-active (4 of 5 rules — see `DinnerRecurringTemplate.swift:42,75,99,123`). The user never sees the schedule and never consents.

### First rule
- The founder never sees a rule during onboarding. They get a preset card and a confirm screen. Five rules with `$200/$200/$200/$300 MXN` fines are silently inserted (`DinnerRecurringTemplate.swift:30-155`). First time they see them is at `EditRulesView` after the group exists. Direct violation of "monetary fines never pre-ticked unless strict" — and `defaultEnabled` filtering only runs inside `ResourceWizardCoordinator` (line 187), not for template-seeded group rules.

## Bad defaults catalogued

- **Dinner preset auto-activates 5 modules with $200-$300 fines pre-on** — `DinnerRecurringTemplate.swift:30-155` + `00021_templates_table.sql` `defaultModules` — punitive for casual families — fines should ship `isActive: false` (suggestion mode) with a one-tap "Activar las reglas" affordance after first event
- **`applyRules` defaults to true on event create** — `EventCreationCoordinator.swift:45` — pre-arms fines on first event — default false for first 1-3 events; honor a real grace period
- **Cover image required-feeling step** — `GroupIdentityView.swift:38-43` — adds a vanity decision before product value — auto-pick default, expose in settings later
- **Preset auto-advance on tap** — `PresetPickerView.swift:41` — irreversible, no confirm — require explicit "Continuar" tap
- **"Mínimo 3 personas"** — `InviteMembersView.swift:16` — false floor (skip ignores it) — say "Invita después" or enforce it
- **"Bienvenido de vuelta" for new users** — `SignInView.swift:66` — new-device default copy — show neutral "Continúa con tu número" plus prominent "Crear cuenta" toggle
- **rotation_active proxy uses module-list presence** — `CreateEventView.swift:281-287` — rotation gets pre-activated by dinner template — should require explicit member opt-in during invite step

## Jargon leakage in onboarding

- "**Acuerdos sugeridos por capacidad activa**" — `ResourceWizardSheet.swift:15` — replace with "Reglas que aplican a esto"
- "**Aplicar reglas del grupo**" — `CreateEventView.swift:173` — replace with "Cobrar multas si alguien falla"
- "**Reglas pre-armadas**" — `EditRulesView.swift:124` — replace with "Lo que el grupo acordó"
- "**período de gracia: las primeras 3 reuniones no aplican multas**" — `GroupTourOverlay.swift:62` — copy promises a behavior that does NOT exist in code (only 24h per-fine grace). Delete or implement.
- "**Save**" — `EditRuleSheet.swift:84` — English in a Spanish app — "Guardar"
- "**Activo compartido / Slots / Rotación de uso**" — `PresetPickerView.swift` via `OnboardingPreset.sharedResource` (`FounderOnboardingCoordinator.swift:323-330`) — "Slots" is product jargon; replace with "Turnos para usarlo"
- "**Tu grupo se vuelve vivo en cuanto le pongas nombre**" / "**Tu grupo está vivo**" — `GroupIdentityView.swift:18`, `ConfirmationView.swift:45` — aspirational poetry, opaque meaning
- "**Te llamamos primero por WhatsApp**" — `InvitedVerifyView.swift:25` — "llamamos" reads as voice call; it's a message

## Decisions the user shouldn't see yet

- **Cover image picker on group create** — `GroupIdentityView.swift:38-43` — deferred (settings)
- **Preset choice with hidden modular consequences** — `PresetPickerView.swift` — should be reframed as "¿Para qué se reúnen?" with NO module activation until first event creation
- **Apply-rules toggle on first event** — `CreateEventView.swift:171-177` — hidden first time; default off; appear on event #4
- **5 fine rules at group birth** — `DinnerRecurringTemplate.swift:30-155` — deferred until the group has at least one closed event
- **Avatar upload during identity step** — `FounderIdentityView.swift:99-126` — deferred (post-onboarding profile screen)
- **Host rotation pre-decision** — `CreateEventView.swift:135-161` — deferred until invite-completion + first event creation, with explicit "¿Quieres que se rote el anfitrión?" sheet

## Progressive disclosure verdict

**Mostly absent.** The founder funnel is 5 screens linear with no branching, but each step dumps everything (e.g., GroupIdentityView shows name + 4 suggestion chips + cover grid simultaneously; CreateEventView shows 7 sections at once). The "Empezar de cero" preset is the only true progressive option — and it's the most-buried card. The dinner preset is a one-tap acceptance of 5 modules + 5 fine rules with no preview.

## Concept-load score (1-5, 5=overwhelming)

- Sign-in vs sign-up confusion: **4**
- Create group (name → preset): **4** (preset side effects invisible)
- Invite/Join (broken universal link): **5** (invitee likely fails)
- First event create: **4** (7 sections, jargon-y rules toggle)
- First rotation: **5** (silent auto-on, no explanation)
- First RSVP: **3**
- First reminder: **3** (invisible to user)
- First rule: **5** (5 fines exist before user knows what a rule is)

## Brutally honest verdict

**Could a 50-year-old parent complete first-run without help? No.** Three blockers:

1. The sign-in-first gate (`AuthGate.swift:32`) says "Bienvenido de vuelta" to a brand-new user. They tap nothing and abandon, or they enter their phone and get an OTP for an account they don't think they have.
2. The invite link `https://ruul.app/invite/<code>` is dead without AASA (`InviteLinkGenerator.swift:8` admits this). The invitee taps the WhatsApp link, lands in Safari on a 404, and gives up. The fallback (paste code into `JoinGroupSheet`) requires them to (a) install the app, (b) navigate to "join", (c) type 6 chars they probably haven't copied.
3. Picking "Reuniones recurrentes" silently arms `$200/$200/$200/$300 MXN` fines + rotation + RSVP + check-in. The first time the parent sees these is in `EditRulesView`, by which point a no-show fine may already exist in the inbox. This is the founder's "create flow defaults" feedback violated at the template-seed level (`DinnerRecurringTemplate.swift`), not just the wizard level.

### Top 3 first-run killers if shipped today

1. **The dinner template silently activates 5 modules + 5 monetary fines.** `DinnerRecurringTemplate.swift:30-155` is the smoking gun. A family that picks "Reuniones recurrentes" enters a punitive system without knowing it. Fix: ship rules `isActive: false` and gate modules behind explicit toggles in a post-creation "set up your group" sheet.
2. **The invite universal link is broken.** `InviteLinkGenerator.swift:8,21` — until AASA ships, an invited user CANNOT open the app from a tap. Workaround: send the 6-char code as plaintext in the share message AND/OR use the `ruul://` scheme (deeplinked but only if installed); pair with App Store fallback.
3. **AuthGate routes new users to a "sign in" screen.** `AuthGate.swift:22-32` + `SignInView.swift:66` — first impression is "you should already have an account." Add a true zero-state "Crear cuenta" CTA at top of SignInView, or split routing so `!hasOnboarded && session==nil` goes to a sign-up shell that does Apple/phone auth then drops into FounderOnboarding.

---

# Track C — Product Language Audit

## Register verdict

**El register es 85 % correcto y 15 % roto.** Cuando funciona es excelente: "Tu grupo está vivo", "Sin cuentas pendientes", "Saluda a los demás" — es cálido, conversacional, mexicano. Pero hay tres tipos de fugas que rompen la promesa:

1. **Jerga arquitectónica filtrada literal**: "capability", "capabilities", "PAYLOAD", "Activar capability", "Booking", `event.eventType.rawString`, `slot.status.capitalized` (renderiza "Unassigned" en inglés a usuarios mexicanos).
2. **Incoherencia léxica del mismo concepto**: regla / acuerdo conviven sin criterio; host / anfitrión también; recurso / activo / cupo / slot también.
3. **Copy de power-user/founder**: "Las 5 reglas del template ya están activas en el servidor", "La flow llega en una próxima versión", "Reglas pre-armadas" — el usuario escucha al equipo de ingeniería, no a un producto.

Además: errores se muestran como `error.localizedDescription` crudo (mensajes Supabase/HTTP en inglés a Mexico). Inaceptable para Beta 1.

## Forbidden-term violations

| Term | File:Line | Current copy | Suggested replacement |
|------|-----------|--------------|----------------------|
| capability | RuulFeatures/Features/Resources/Detail/Zones/DetailTopNavView.swift:60 | `Button("Activar capability", ...)` | "Agregar función" |
| capabilities | RuulFeatures/Features/Groups/GroupSettingsSheet.swift:198 | "Solo los admins pueden activar o desactivar capabilities en este grupo." | "Solo los admins pueden activar o apagar funciones en este grupo." |
| capabilities | RuulFeatures/Features/Groups/GroupSettingsSheet.swift:202 | "Este grupo requiere votación para activar capabilities. La flow llega en una próxima versión." | "Este grupo necesita votación para activar funciones nuevas. Pronto lo vas a poder hacer desde acá." |
| capability | RuulFeatures/Features/Groups/GroupSettingsSheet.swift:206 | "No se puede cambiar esta capability: …" | "No pudimos cambiar esta función: …" |
| capabilities | RuulFeatures/Features/Groups/GroupRulesSettingsView.swift:51 | `"¿Quién puede activar capabilities?"` | "¿Quién puede activar funciones nuevas?" |
| capacidades | RuulFeatures/Features/Resources/ResourceWizardSheet.swift:276 | "Estos acuerdos van con las capacidades que escogiste." | "Estos acuerdos van con lo que activaste arriba." |
| opciones (eufemismo confuso) | ResourceWizardSheet.swift:435, 560-562 | "OPCIONES ACTIVAS", "Crear con N opciones · N acuerdos" | "QUÉ INCLUYE" / "Crear con N funciones y N acuerdos" |
| PAYLOAD | RuulFeatures/Features/Votes/Detail/Bodies/GenericVoteBody.swift:22-25 | Renderiza `Text("PAYLOAD")` + JSON crudo | Eliminar bloque; mostrar resumen humano por tipo de voto o "Sin detalles adicionales" |
| eventType.rawString | RuulFeatures/Features/History/Views/SystemEventDetailView.swift:83, 131 | `row("Tipo", event.eventType.rawString)` + `default: return event.eventType.rawString` | Mapear cada caso a copy mexicano; nunca caer en `rawString` (filtra "hostAssigned", "rsvpDeadlinePassed") |
| hostAssigned | EventDetailHost.swift / HomeView.swift:630 / Group/Overview/GroupOverviewSubTab.swift:347 / Inbox/ActionInboxView.swift:82 | switch externalizado al icon, pero confirmar que ningún label use `.hostAssigned` raw | Auditar `labelFor(_ ActionType:)` y forzar todos los casos en mexicano |
| capability_slug | GroupSettingsSheet.swift:168 | `targetPayload: ["capability_slug": …]` | sólo interno; pero asegurar que jamás se logue a UI |
| Booking (inglés) | RuulFeatures/Features/Resources/Views/AssetDetailView.swift:121 | `Text("Booking")` | "Reserva" |
| Booking (inglés) | RuulFeatures/Features/Resources/Views/AssetDetailView.swift:58 | empty `"Sin reservas"` (OK) pero header dice "Booking" |  |
| swap (inglés) | SlotDetailView.swift:59 | `Button("Solicitar swap a otro miembro")` | "Pedirle el cupo a alguien" / "Cambiar de cupo" |
| swap | SlotDetailView.swift:230 | `.navigationTitle("Pedir swap")` | "Pedir intercambio" |
| status raw | AssetDetailView.swift:132-133, SlotDetailView.swift:30 | `Text(status)` y `slot.status.capitalized` filtran "Unassigned", "Booked", "Pending" | mapping `assigned → "Asignado"`, `unassigned → "Libre"`, `booked → "Reservado"` |
| uuidString prefix | SlotDetailView.swift:46,133 | "Reserva: 3f2a8b1d…" | Quitar; nadie identifica una reserva por hash |
| uuidString prefix | History/SystemEventDetailView.swift:89 | `row("Recurso", resourceId.uuidString.prefix(8) + "…")` | Mostrar el nombre del recurso resuelto, o quitar la fila |
| DEBUG ... eventId= | Fines/Views/ReviewProposedFinesView.swift:55 | `Text("DEBUG eventId=… loaded=… proposed=… resolved=…")` | **Borrar antes de Beta 1.** Es debug residual visible. |
| MUST FIX preview text | Resources/Detail/UniversalResourceDetailView.swift:126 | `Text("UniversalResourceDetailView needs AppState + AppState-bound repos…")` | Asegurar que ese branch nunca se renderice en runtime (sólo `#Preview`) |
| Slug | Rules/RuleDetailView.swift:135 | `metadataRow(label: "Slug", value: slug)` | Eliminar fila. "Slug" no le dice nada al usuario. |
| Módulo · X | Rules/RuleDetailView.swift:153 | `return rule.moduleKey.map { "Módulo · \($0)" } ?? "Módulo"` | "Para X" o "En la función de X" (resuelto en humano) |
| sprint, template, servidor | Events/Views/MainTabStubs.swift:30 | "Las 5 reglas del template ya están activas en el servidor. La pantalla para verlas y editarlas llega en el siguiente sprint." | "Las reglas del grupo ya están activas. Pronto vas a poder verlas y editarlas desde acá." |
| Próximamente | Votes/Sheets/CreateVoteSheet.swift:44, Groups/GroupRulesSettingsView.swift:209, RuulUI/Primitives/TemplatePickerCard.swift:79 | "PRÓXIMAMENTE" | OK pero usar consistentemente (no mezclar con "La flow llega en una próxima versión") |
| flow (inglés) | Groups/GroupSettingsSheet.swift:202 | "La flow llega…" | "La opción llega…" |
| founder | Events/MainTabView.swift:491, Groups/EditMembersSheet.swift:254, Votes/Detail/Bodies/MemberRemovalVoteBody.swift:58 | `Text("Esta acción es permanente. Solo el founder puede agregarte de vuelta.")` / `Text("FOUNDER")` | "creador" / "CREADOR" (o "ADMIN" si la jerarquía lo permite) — "founder" es jerga del equipo |
| host | Events/Views/EditEventView.swift:128, CreateEventView.swift:142, EventDetailHost interno, Resources/Detail/Sections/HostActionsSectionView.swift:41 ("Como host"), Events/Sheets/MemberQRSheet.swift:27 ("Muestra este código al host…"), EventLedgerCoordinator.swift:53 ("ej. reembolso al host") | mezcla "host" / "anfitrión" inconsistente | **Canon: "anfitrión"**. Reemplazar todos los "host" visibles. |
| RSVP (sigla cruda) | varias (Inbox, EmptyState, MainTabStubs) | "RSVPs sin contestar" | "confirmaciones pendientes" |
| Check-in (inglés) | History/Views/SystemEventDetailView.swift:130 | `case .checkInRecorded: return "Check-in"` | "Llegada registrada" |
| Booking / unable to render payload | GenericVoteBody.swift:40 | `"(unable to render payload)"` | jamás visible; eliminar bloque entero |
| reglas vs acuerdos | TODO el feature Rules/ vs Events/Sheets/EventRulesSheet.swift | inconsistente: `RuleDetailView` dice "Regla", `RulesView` dice "acuerdos", `EditRulesView` dice "Editar acuerdos" pero contenido dice "Sin reglas" / "reglas configuradas" / "Reglas pre-armadas" | **Canon: "acuerdo"** en TODO el UI. "Regla" sólo en contextos formales si el founder lo decide. |
| Trigger interno detectado | Group/Money/GroupMoneyView.swift:26 (comentario) | "Triggered by the …" | OK (comentario interno), pero hay que verificar que `triggerLabel` (EventRulesSheet.swift:120) nunca se renderice como label crudo |
| recurso (inconsistente) | Group/Views/GroupTabView.swift:301, 332 | "Toca el botón + para crear un activo, slot, fondo u otro recurso." / "\(resources.count) recursos" | "Toca + para crear lo que el grupo necesite (un evento, un fondo, un cupo, lo que sea)" |
| cupos / slot mezcla | AssetDetailView.swift:42, SlotDetailView.swift navTitle/Section | "Sin cupos creados todavía" + "Cupo" + "swap" | OK con "cupo"; eliminar "swap" |
| acceso rápido (vacío) | Group/Overview/GroupOverviewSubTab.swift:300 | "ACCESO RÁPIDO" | OK pero verificar contenido real |
| Generación automática | Resources/Detail/Sections/HostActionsSectionView.swift:182 | OK | OK |
| Reglas pre-armadas | Rules/EditRulesView.swift:123, 131 | "Reglas pre-armadas" + "Las reglas personalizadas estarán disponibles…" | "Acuerdos que vienen por defecto" + "Pronto vas a poder agregar los tuyos" |
| QUÉ HACE | Rules/RuleDetailView.swift:96 | `sectionContainer(title: "QUÉ HACE")` con "Sin consecuencias configuradas." | Header OK; sub-copy debe decir "Sin acciones todavía" — `consecuencias` es jerga |
| consecuencias | Rules/RuleDetailView.swift:98 | "Sin consecuencias configuradas." | "Esta regla no tiene acciones definidas." |
| Aplica a / scope leak | Rules/RuleDetailView.swift:137 + 150-157 | `scopeLabel`: "Toda la recurrencia" / "Esta instancia" / "Por miembro" | "instancia" es jerga; "Esta instancia" → "Sólo este evento"; "Toda la recurrencia" → "Todas las cenas de esta serie"; "Por miembro" → "Aplica a cada miembro" |
| Módulo · …  | Rules/RuleDetailView.swift:153 | "Módulo · X" | Eliminar caso o traducir a "En X" |
| ocurrencias | Events/Sheets/EventRulesSheet.swift:59 | "Aplican a todas las ocurrencias de esta recurrencia." | "Aplican a todas las cenas (o lo que sea) de esta serie." |
| override | EventRulesSheet.swift:65 | "Defaults del grupo. Aplican salvo override más específico." | "Reglas del grupo. Si hay una regla más específica, esa manda." |
| Sobrescriben | EventRulesSheet.swift:53 | "Sobrescriben las heredadas." | "Le ganan a las del grupo." |
| heredadas | EventRulesSheet.swift:53 (mismo) | "heredadas" | "las generales" |
| Defaults | EventRulesSheet.swift:65, CreateGroupSheet.swift:77 | "Defaults del grupo" / "5 reglas por defecto" | "Reglas por defecto" (ya existe traducido) — consistencia |
| host (en error) | Fines/FineDetailView.swift:362 | "espera a que el host la revise" | "espera a que el anfitrión la revise" |

(48 violaciones cubren los flujos más visibles. Quedan ~6 más menores en logs/showcase no críticos.)

## Cross-screen inconsistencies

- **host / anfitrión / encargado / founder**: "host" aparece en CreateEvent, EditEvent, MemberQR, EventLedger, FineDetail; "anfitrión" en EditMembers (turno), RotationSection, GroupInfoSheet ("Vocabulario, multas, anfitrión"). **Canon: "anfitrión"** en TODO el UI. "host" sólo en código.
- **regla / acuerdo**: usados intercambiablemente. RuleDetailView/EditRule/RulesView/EditRulesView mezclan. **Canon: "acuerdo"** en navegación primaria, "regla" sólo en headers viejos que migran. Decidir y unificar.
- **recurso / activo / cupo / slot**: GroupTabView dice "activo, slot, fondo u otro recurso"; SlotDetail dice "Cupo"; AssetDetail dice "Recurso". El usuario no sabe qué es un "recurso". **Canon: en UI no decir "recurso"; usar el nombre humano de cada cosa.**
- **Historia / Historial / Actividad**: GroupHistoryView dice "Historia"; PastEventsView dice "Historial"; MainTabView dice "Actividad"; GroupMoreSubTab dice "ACTIVIDAD". **Canon: "Actividad"** para feed; "Historial" para listado pasado de eventos. Quitar "Historia".
- **founder / fundador / creador / admin**: "FOUNDER" badge en EditMembersSheet vs "Solo el founder" en alert vs "del founder" en MemberRemoval body. **Canon: "Creador del grupo"** o "ADMIN" si no necesitas distinguir.
- **opciones / capacidades / funciones**: ResourceWizard cambia de "Opciones" → "capacidades" → "funciones" en 3 strings adyacentes. **Canon: "funciones"**.
- **Cierra en Xh / Cierra X / Cierra \(rel)**: CreateGeneralProposalSheet usa "Cierra en \(N)h"; OpenVotesListView usa "Cierra \(relativeDescription)". Unificar formato.

## Empty-state copy issues

- **MainTabStubs.swift:30 Reglas** — "Las 5 reglas del template ya están activas en el servidor. La pantalla para verlas y editarlas llega en el siguiente sprint." → Lenguaje de ingeniero. Reemplazar.
- **MainTabStubs.swift:17 Inbox** — "Aquí van a aparecer multas pendientes, apelaciones por votar y RSVPs sin contestar. Próximamente." → OK pero "RSVPs" debe ser "confirmaciones".
- **GroupTabView.swift:298-301** — "Sin recursos aún / Toca el botón + para crear un activo, slot, fondo u otro recurso." → 3 palabras técnicas en una frase. Sugerido: "Aún no hay nada acá / Toca + para crear el primer evento o lo que el grupo necesite."
- **RulesView.swift:71-72** — "Sin acuerdos / Este grupo aún no tiene acuerdos configurados." → "configurados" es jerga. Sugerido: "Aún no hay acuerdos / Cuando el grupo decida cómo manejar algo, va a aparecer acá."
- **AssetDetailView.swift:42** — "Sin cupos creados todavía" → OK. ✓
- **GroupMoneyView.swift:306-309** — "Aún no hay movimientos / Toca + Gasto o + Aportación..." → ✓ buena.

## Error/alert copy issues

- **All `self.error = error.localizedDescription`** (15+ ocurrencias) — filtra mensajes Supabase/HTTP en inglés ("PGRST116: no rows", "JWT expired"). Inaceptable. Wrappear en `RuulErrorTranslator` que mapee códigos a mensajes mexicanos.
- **GroupSettingsSheet.swift:211** — "No pudimos guardar los cambios: \(error.localizedDescription)" → mismo problema; el sufijo es opaco.
- **InvitedOTPView.swift:33** — "Código incorrecto. Te quedan \(3 - attempts) intentos." → ✓ buena.
- **EventRulesCoordinator.swift:342** — Detecta string EN crudo "only group admins or the event host" y traduce. Frágil; lógica debería estar en backend o usar error codes.

## Date/time/plural issues

- `ruulRelativeDescription` se usa consistente para "hace 5 min" / "Cierra en 3h" — bien.
- `EventLedgerSheet.swift:133` — "Registra el primer gasto o aportación de esta \(groupVocabulary.lowercased())." — interpolación de palabra en mid-sentence; verificar que `groupVocabulary` ya viene en lowercase consistente (riesgo de "esta Cena").
- **Plurales sin handling**: `ResourceWizardSheet.swift:551` hace `"acuerdo\(count == 1 ? "" : "s")"` manual — OK pero frágil. `GroupTabView.swift:332` `"\(resources.count) recursos"` no maneja 1. `MyFeedView.swift:93` `Text("\(count)")` sin sufijo. Centralizar en helper `pluralES(_:_:)`.
- **Fechas absolutas**: `SystemEventDetailView` usa `DateFormatter` con `.long` + `.short` time — está bien.
- **Mezcla relativo/absoluto**: Algunos sitios muestran "Cierra en 3h", otros "Cierra el martes a las 19:00". Definir regla: <24h relativo, >24h absoluto.

## Final UX dictionary (proposed, Spanish-MX)

- **Anfitrión** — quien organiza un evento (NO host, NO encargado).
- **Creador del grupo** o **Admin** — quien lo fundó (NO founder).
- **Función** — capacidad activable del grupo o del recurso (NO capability, NO capacidad, NO opción, NO módulo).
- **Acuerdo** — regla de comportamiento del grupo (NO regla en headers primarios).
- **Evento / Cena / [vocabulario del grupo]** — instancia (NO occurrence, NO ocurrencia, NO instancia).
- **Serie** — recurrencia de un evento (NO recurrence raw).
- **Cupo** — slot asignable (NO slot).
- **Fondo** — pot/fund común.
- **Multa** — fine.
- **Apelación** — appeal.
- **Anular** — voidFine.
- **Confirmación / Confirmar asistencia** — RSVP (NO RSVP suelto).
- **Llegada / Marcar llegada** — check-in (NO check-in en UI).
- **Votación** — vote (NO voto cuando es la acción de abrir).
- **Voto** — vote cast.
- **Quórum / Mayoría** — OK como están.
- **Turno** — rotation slot.
- **Rotación** — rotation capability surface ("Rotar anfitrión").
- **Recordatorio** — notification/reminder.
- **Actividad** — feed del grupo (NO Historia).
- **Historial** — listado de eventos pasados.
- **Movimiento** — ledger entry (gasto / aportación).
- **Acceso rápido** — quick actions.

## Forbidden terms list (checklist para revisión de copy)

```
capability / capabilities / capacidad (cuando se refiere a feature)
projection / proyección
atom / atomic / atómico
system event / SystemEvent / evento de sistema
resource_series / ResourceSeries
trigger / triggerEventType / disparador (cuando se refiere a Rule)
consequence / consecuencia (cuando se refiere a Rule)
condition (cuando se refiere a Rule)
WHEN / IF / THEN  (visibles; OK internos)
scope / alcance (en sentido jerárquico de rules)
override / sobreescribir / heredar (jerga rules engine)
polymorphic / polimórfico
jsonb / json / PAYLOAD / payload
rpc / RPC
primitive / primitiva
hostAssigned (string raw)
phase_target / phase target
occurrence (cuando significa una instancia)
namespace
uuid / uuidString (visible)
module (sentido técnico)
engine
registry
outbox
slug (visible)
flow (inglés)
template (visible al usuario final)
booking / swap / host (inglés sin traducir)
founder (visible)
default / defaults (visible — usar "por defecto")
sprint / servidor / endpoint (cualquier término de dev)
DEBUG ... (cualquier prefijo de debug residual)
```

## Top-3 copy fixes si sólo hay 1 día

1. **Borrar la fuga literal de "capability" / "PAYLOAD" / "DEBUG"** en 4 archivos: `DetailTopNavView:60`, `GroupSettingsSheet:198/202/206`, `GroupRulesSettingsView:51`, `GenericVoteBody:22-25`, `ReviewProposedFinesView:55`, `SystemEventDetailView:83/131` (mapear todos los `eventType` casos, nunca `.rawString`).
2. **Unificar "host" → "anfitrión"** en todos los strings visibles (~10 ocurrencias en Events/, Resources/Detail/Sections/, Fines/). Es el término más visible del producto.
3. **Wrappear `error.localizedDescription`** en un `RuulErrorTranslator` simple que traduzca al menos los 5-6 errores más comunes de Supabase a copy mexicano. Reemplazar las 15+ asignaciones directas.

---

# Track D — Notifications / Inbox / Activity Audit

## Current taxonomy (table)

| Type | Source (event/cron) | Push? | Inbox? | Activity? | Actionable? | Lifecycle |
|------|--------------------|-------|--------|-----------|-------------|-----------|
| `eventCreated` | `create_event_v2` (mig 00097) | No outbox writer | No | Yes (`system_events`) | n/a | Permanent log |
| `eventClosed` / cancelled | `close_event_no_fines` / `cancel_event` (mig 00098) | No (cancelled push only if `send-event-notification` is invoked, no caller found) | No | Yes | n/a | Permanent |
| `host_reminder` / `deadline_warning` / created / cancelled push | `send-event-notification` edge fn (manual invoke only — `EventDetailCoordinator.sendHostReminders()` line 271 is a stub that doesn't even call the edge fn) | Yes (when invoked) | No | No | Tap → deep link | Outbox only |
| `hoursBeforeEvent` reminder | `emit-event-reminder-events` cron 5m (mig 00131) → `system_events` only | **No push** (just feeds rule engine) | No | Yes | n/a | Dedup by `(resource_id, hours)` |
| `rsvpSubmitted` / `rsvpChangedSameDay` | `set_rsvp` RPC | No | No | Yes | n/a | Permanent |
| `voteOpened` | `start_vote` (mig 00023) | Yes (1 outbox row per voter) + on_appeal_vote_seeded inserts `appealVotePending` inbox | Yes (`appealVotePending` for fine_appeal; **none for plain `votePending`** because the appeal_votes trigger only fires for appeal votes — there's no equivalent for generic votes) | Yes | Yes (cast) | Inbox resolved on cast (mig 00043) or vote close (mig 00044) |
| `voteResolved` | `finalize_vote` (mig 00023, 00123) | Yes (every cast + appellant) | `ruleChangeApplyPending` inserted (mig 00032) if rule_change | Yes | Yes (for apply) | Resolved by mig 00044 trigger when rule.consequences updated |
| `fineOfficialized` | `finalize-fine-reviews` cron + `officialize_fine` + trigger `on_fine_officialized` (mig 00016) | Yes (`finalize-fine-reviews` writes outbox) | `finePending` (high priority) | Yes | Pay/appeal | Auto-resolved on pay/waive/void/in_appeal (mig 00044) |
| Proposed fine (auto) | `on_fine_inserted` trigger | No push | `fineProposalReview` for host | n/a | Review | Resolved when all proposed→officialized/voided |
| `fineVoided` | `void_fine` (mig 00029) | No | `fineVoided` **informational** action (priority `'normal'` — invalid value; no resolver, no router) | Yes | No tap target | **Never resolves** |
| `hostAssigned` | events insert trigger (mig 00133) | No push | Yes (medium) | No | Open event | **No resolver** — stays until manually resolved on tap |
| `fineReminderSent` | `send-fine-reminders` cron | Push (claim is outbox, but file says outbox writing is "pending wiring") | No | Yes | n/a | Can repeat |

## Inbox boundary verdict
**Mostly enforced, with one informational leak.** `user_actions` is keyed by `action_type` enum and rendered as actions. But `fineVoided` (mig 00029:60) is informational, has no resolver and no tap router — it lingers as a permanent "ghost" inbox row. Also `rsvpPending` is declared in the Swift enum (`UserAction.swift:63`) and routed in 5 view files, but **no migration ever inserts it** — pure dead code that hides a missing pipeline. RSVPs never appear in the inbox even though the user model says they should.

## Activity boundary verdict
Pure history layer (`system_events`) is correctly separated from `user_actions`. But `hoursBeforeEvent` synthetic markers (mig 00131 / `emit-event-reminder-events`) land in `system_events` and render in `GroupHistoryView` as "Quedan horas para un evento" timeline items (`HistoryItemPresentation.swift:37`). That's clutter — 24h reminders for every recurring dinner will pile up. They were meant as internal rule-fuel, not user-visible signals.

## Spam risk scenarios
- **10-person weekly recurring dinner, 24h reminder rule active**: zero push spam today (the 24h reminder never hits APNs — `emit-event-reminder-events` only writes `system_events`). But if/when wired, that's 1 push × 9 non-host members = 9 pushes per occurrence per reminder horizon.
- **3 events same day with manual host reminders**: each `sendHostReminders` invocation could fan out to N pending RSVPs, but the iOS coordinator currently no-ops (`EventDetailCoordinator.swift:271-278`) — silent regression.
- **Vote on a 10-person group**: `start_vote` writes 10 outbox rows + `finalize_vote` writes 10 more (mig 00023:149, 265). For a single vote that's 20 pushes per voter cycle. Acceptable.
- **Rule-change cascade**: voting passes → 10 `voteResolved` pushes + 1 `ruleChangeApplyPending` inbox to host. Bounded.
- **Real worst case observed**: 3 votes concurrent + 3 fine officializations = 30+ outbox rows; cron drains 100/min batch so no backlog, but the user sees a stream.

## Dedup gaps
- **`fineVoided` inbox**: `void_fine` mig 00029:60 has no `ON CONFLICT` — repeated programmatic void calls would insert duplicates (unlikely in practice, but no guard).
- **`hostAssigned`**: mig 00133:38 has no `ON CONFLICT` — if event row is ever UPDATEd with same host_id and trigger were rebound to UPDATE (not today), duplicates possible. Today fine, but fragile.
- **`emit-event-reminder-events`**: in-app dedup only (index.ts:147-179); no DB-level unique constraint on `(resource_id, event_type, payload->>'hours')`. Two concurrent invocations could double-insert.
- **APNs sends to multiple devices**: `dispatch-notifications/index.ts:142` iterates all tokens per user — multi-device is intentional fan-out, not a dedup gap.

## Stale-item / orphan risks
- **Cancelled events leave inbox rows behind**: `cancel_event` (mig 00098) does NOT resolve dependent `user_actions` (`rsvpPending` doesn't exist anyway, but `fineProposalReview` for that event, and `hostAssigned`, remain pending forever). No trigger on `events.status = 'cancelled'` cleans up.
- **`hostAssigned` orphans**: if event is deleted, `user_actions.reference_id` has no FK — row lingers. mig 00014 declared `user_actions` without `on delete cascade`.
- **Outbox janitor missing**: `dispatch-notifications/index.ts:14-18` explicitly warns: rows claimed but un-finalized (function crash mid-batch) stay orphaned. "V1 doesn't ship the janitor; stuck rows are observable via SQL." Confirmed not shipped.
- **Token cleanup on user removal**: removing a member from a group does not delete `notification_tokens` — user will still receive pushes for groups they were removed from until the token expires (410 Gone).

## Multi-device sync verdict
**Read state: not synced.** Inbox is server-truth via `user_actions.resolved_at`; both devices see the same pending list. But "tapped/seen but not yet resolved" is local-only (`InboxCoordinator.resolve` updates server). APNs delivers to **all** registered tokens — dismissing a push on device A leaves the badge on device B until next inbox refresh. There is no APNs `apns-collapse-id` set in `dispatch-notifications/index.ts:213` — if same push is sent twice (e.g. retry), both devices show two separate notifications.

## Cron reliability
- **dispatch-notifications retry**: `claim_pending_outbox` (mig 00031) uses `FOR UPDATE SKIP LOCKED` — concurrent invocations safe. But marks `dispatched_at=now()` **before** the APNs call (line 33-44) and never reverts on failure. If `sendApns` succeeds but `mark_outbox_sent` RPC fails (e.g. DB blip), row stays with `dispatched_at` set + `dispatch_status='pending'` → permanently orphaned (`dispatch-notifications/index.ts:14-18` acknowledges this). **No retry of transient APNs 5xx errors** — single attempt, then `mark_outbox_failed`.
- **Idempotency keys**: outbox row `id` is the only key; no `apns-collapse-id`, no logical dedup. If `start_vote` were called twice (shouldn't happen due to mig 00025 unique index, but mig 00023 doesn't itself dedup), two voteOpened rows per voter ship.
- **emit-event-reminder-events**: 1h-wide window absorbs 55min cron lag (good).

## Unread-count source of truth
`InboxCoordinator.actions.count` (filtered to `resolved_at IS NULL`, ordered server-side). `MainTabView.swift:154-156` shows it as the Home tab badge. **No iOS APNs badge sync** — pushed `aps.badge` is not set in `buildApnsBody` (`dispatch-notifications/index.ts:177-194`), so the OS-level app icon badge will never increment from a push. The user sees the in-app badge only when they open the app. `pendingCountsByGroup` (cross-group) is used by `GroupOverviewSubTab.swift:138` and computed client-side from the same fetched actions — consistent.

## Recommended changes (priority order)
1. **[must] Wire `rsvpPending` or remove from enum.** Either add an insert path (event_created trigger → one row per non-host member, resolved on `set_rsvp`) or strip from `ActionType`. Right now 5 iOS routers exist for a row that never spawns.
2. **[must] Resolve `user_actions` on `events.status = 'cancelled'`.** Add a trigger to cascade-resolve `hostAssigned` + `fineProposalReview` + future `rsvpPending` when event cancelled. Orphan inbox rows kill trust.
3. **[must] Fix `void_fine` priority `'normal'`** (mig 00029:67) — not in `ActionPriority` enum; iOS decoder would crash if it ever happens. Use `medium`. Also: either give `fineVoided` a resolver (auto-resolve after 7d) or remove the inbox write (info belongs in Activity, which it already does).
4. **[must] Add APNs `apns-collapse-id`** in `buildApnsBody` — use `notification_type + group_id + reference_id` so a re-send replaces the prior banner. Multi-device + retry safety.
5. **[should] Janitor for stuck outbox rows.** 5-min cron: where `dispatched_at < now()-5min AND dispatch_status='pending'`, reset `dispatched_at=NULL` so dispatcher retries (`dispatch-notifications/index.ts:14-18` already names this).
6. **[should] Stop surfacing `hoursBeforeEvent` synthetic events in `GroupHistoryView`.** Filter by event_type in `LiveSystemEventRepository.query` or hide in `HistoryItemPresentation`. They are rule-fuel, not history.
7. **[should] Set `aps.badge`** in dispatcher so OS-level badge ≈ inbox unread count (requires per-recipient count lookup; can be deferred to V1.x but currently zero feedback at lock screen).
8. **[should] Wire `EventDetailCoordinator.sendHostReminders`** (line 271) to actually invoke `send-event-notification` with kind=`host_reminder`. Currently a 0-byte UX promise.
9. **[polish] FK + `ON DELETE CASCADE`** from `user_actions.reference_id` (polymorphic — needs trigger-based cascade rather than FK). Or accept orphans + ignore on UI when reference resource is gone.
10. **[polish] Remove `notification_tokens`** when `group_members.active=false` everywhere (or scope tokens per active membership). Today a removed user gets pushes from the dispatcher's blanket `in_('user_id', userIds)` fan-out as long as they retain *any* membership.

## Brutally honest verdict
- **Would a real 10-person family group find the current notification volume tolerable?** Yes today — because too little works, not because it's well-tuned. Push reach is silent for RSVP nudges (`sendHostReminders` is a stub) and for event creation (no caller of `send-event-notification` with kind=`created` was found in repo). Vote + fine pushes are bounded (≤2N per cycle). The *real* problem will surface when item 8 is shipped: a host hitting "Mandar recordatorio" twice in 10 minutes will fire 9+9 pushes with no rate-limit, no collapse-id, no idempotency.
- **Top 3 risks before external beta**:
  1. **Inbox feels broken** — `rsvpPending` is dead code while founder's mental model expects RSVPs in the inbox. Family beta WILL ask "where's my RSVP nag list?"
  2. **Orphan + ghost rows** — cancel an event, `hostAssigned`/`fineProposalReview` stay forever; `fineVoided` action never clears. After 2 weeks of real use the inbox looks corrupted.
  3. **Multi-device + retry collisions** — no `apns-collapse-id`, no janitor, OS badge unset. A user on iPhone + iPad will see double banners; a transient APNs failure leaves an unsent row no one notices.

---

# Track E — Reliability Audit

## Cron + Edge Function inventory

| Function | Schedule | Idempotent? | Retry on fail? | Risk |
|----------|----------|-------------|----------------|------|
| `process-system-events` | every 1 min | Partial — only marks `processed_at` after consequences commit; `proposeFine` dedups on (resource_id, user_id, rule_id) in open states | Yes (unprocessed → next run) | Crash mid-event → re-run re-emits whatever consequences are NOT internally idempotent (outbox writes, non-fine consequences) |
| `dispatch-notifications` | every 1 min | `claim_pending_outbox` uses `FOR UPDATE SKIP LOCKED`; sets `dispatched_at` on claim | Crashes after claim leave orphan rows (`dispatched_at` set, `dispatch_status='pending'`) — **no janitor exists** (acknowledged in `dispatch-notifications/index.ts:14-18`) | Permanent silent loss of notifications on edge crash |
| `auto-generate-events` v7 | every 2h | Yes — partial unique index `uniq_events_series_starts_at` + `ON CONFLICT DO NOTHING` (mig 00126) | Errors per-series don't abort batch | Solid |
| `auto-close-events` | hourly | Status filter prevents re-close; but `eventClosed` emit failure does NOT roll back close, leaving rules unfired (`auto-close-events/index.ts:90-98`) | None on emit failure | Silent rule miss for stuck events |
| `emit-deadline-events` | every 5 min | App-level dedup query on existing system_events | Errors abort whole run | Pre-insert dedup → concurrent runs can both insert; pg_cron serializes so practical risk low |
| `emit-event-reminder-events` (Tier 4) | every 5 min | App-level dedup only — **NO unique index on `(resource_id, event_type, payload->>'hours')`** in `system_events` | Errors skip N continue | Manual cron+curl overlap → duplicate `hoursBeforeEvent` rows → rule fires twice → duplicate fines |
| `finalize-votes` | every 5 min | `finalize_vote` re-entry returns cached resolution (mig 00123 v4) and takes `FOR UPDATE` on vote | Per-vote try/catch | Race with `cast_vote`: see below |
| `finalize-fine-reviews` | hourly | `officialized_at` filter | None on emit/outbox errors (logged only) | Officialization commits but notification can silently fail |
| `emit-slot-system-events` | every 5 min | (slot lifecycle, dormant in v1) | n/a | Low — no real slots in prod yet |
| `send-event-notification`, `send-otp`, `verify-otp`, `send-whatsapp-invite`, `send-fine-reminders`, `generate-wallet-pass` | on-demand HTTP | Various | Various | Not surveyed in depth |

## Top reliability risks (ranked by severity × likelihood)

### Critical (blocker for external beta)

1. **Stale APNs tokens after sign-out** — `ios/Packages/RuulCore/Sources/RuulCore/Services/Notifications/NotificationService.swift:65-78` + `AuthService.swift:237-240`. `signOut()` never calls `tokenRepo.revokeToken(...)`. If user A signs out and user B signs in on the same device, A's `notification_tokens` row stays. APNs uses the same device token, so the row is owned by user A's UUID → dispatcher resolves push for someone who joined a group as A → notification arrives on B's device. With family/shared devices this leaks group activity. Fix: `revokeToken(lastDeviceToken)` inside `SettingsSheet.swift:128` / `signOutButton` paths, or wire `onAuthStateChange(signedOut)` to clear tokens.

2. **`notifications_outbox` orphan-on-crash** — `claim_pending_outbox` (mig 00031:31-49) sets `dispatched_at=now()` on claim. If dispatch-notifications crashes between claim and `mark_outbox_sent/failed/skipped`, the row is invisible forever (cron filter is `dispatched_at IS NULL`). Doc acknowledges the gap (`dispatch-notifications/index.ts:16-18`) but no janitor ships. With 1-min cron + APNs latency spikes, an Edge timeout once a day silently drops one notification. Beta users will say "no me llegó".

3. **`cast_vote` ↔ `finalize_vote` race** — `cast_vote` (mig 00020) reads `votes.status` without lock then UPDATEs `vote_casts`. `finalize_vote` (mig 00123) takes `FOR UPDATE` on votes but runs `count(*) from vote_casts` under READ COMMITTED. A vote committed by `cast_vote` AFTER finalize's COUNT but BEFORE finalize's UPDATE → cast silently lost, vote resolves with the older tally. With governance-changing votes (rule_change, fine_appeal) this is fairness-shattering.

### High (visible in normal use)

- **`pay_fine` double-counts `fund_balance`** — mig 00003:235-251. SELECT-then-UPDATE without row lock + non-atomic `fund_balance = fund_balance + f.amount`. Concurrent double-tap on Pay → balance off by amount. Likelihood low (one user pays one fine) but ugly when it happens.
- **`auto-close-events` emits `eventClosed` system_event in best-effort mode** — mig flow `auto-close-events/index.ts:86-98`. Close commits, emit fails → no-show fines never fire. No retry, only logged. With a 1-hour cron and platform redeploy, a batch could lose rules silently.
- **`hoursBeforeEvent` duplicate emission** — `system_events` has no unique constraint on `(resource_id, event_type, payload->>'hours')`. The cron's pre-insert dedup query is racey under operator-triggered manual runs. Duplicate emission → rule engine runs twice → duplicate fine (proposeFine dedups by `(resource_id, user_id, rule_id)` so we're saved — but only for fine consequences; non-fine consequences like `addUserAction` or `outboxNotify` would duplicate). Recommend adding unique partial index.
- **Cross-TZ `rsvpChangedSameDay`** — `EventDetailCoordinator.swift:362-364` uses `Calendar.current.isDate(.now, inSameDayAs: event.startsAt)`. Two members in different TZs disagree → identical action emits a system_event for one user, not the other. With Mexico-only audience low likelihood; flag if any beta user is traveling.
- **`hostAssigned` user_action shows UTC date** — mig 00133:52 hardcodes `at time zone 'UTC'`. Mexico beta user opens inbox at 22:00 local → date shows "14 May" instead of "13 May". Visible UX bug for Spanish-speaking users in Mexico (UTC-6).

### Medium (rare but ugly)

- **`process-system-events` non-fine consequences not idempotent** — only `proposeFine` ships dedup logic (`process-system-events/index.ts:212-220`). Other consequences (e.g. `addUserAction` from rotation = 'hostAssigned', notify, lockResource) don't dedup. Engine crash after consequence #1 + re-run repeats consequence #1. Adds noisy inbox rows but no correctness break.
- **`fine_review_periods` is unique on `event_id`** — fine_review_periods only covers fines tied to events (mig 00014:227-235). Polymorphic fines on non-event resources (post-00041) can't enter the review-period flow → either no grace period or NULL row blocking the unique constraint.
- **`create_event_v2.cycle_number`** — computed as `max(cycle_number)+1` without lock (mig 00126:249-252). Concurrent calls on same group produce duplicate cycle_number; no unique constraint to surface the bug. Rotation logic in `next_host_for_series` uses caller-provided cycle so it's robust, but legacy `next_host_for_group(group_id, cycle)` callers could pick same host.
- **`record_system_event` raises NOTICE for unknown types but still inserts** — mig 00094 + 00092. A typo'd event_type lands in the log; no rule fires; no surface on iOS. Operator-only signal.
- **`sync_event_to_resource` trigger runs SECURITY DEFINER on every event INSERT/UPDATE/DELETE** — mig 00039. Heavy jsonb_build_object per row; benchmark unbounded. With 50-member groups doing N events/day it's fine; if a backfill loops events this could be slow.

### Low (theoretical)

- **`finalize_vote` quorum math uses INT division** — mig 00123:90, `ceil(v_total::numeric * v_vote.quorum_percent / 100)::int`. Fine for percent ≤ 100, but if quorum_percent is stored unbounded (no CHECK seen in survey), values >100 break.
- **JWT cache in `dispatch-notifications`** — `getApnsJwt` caches for 50 min in a module-level var; Deno deploy may snapshot instances longer than 60 min during redeploy. APNs would 403; the function's only fallback is to mark failed. Minor.
- **Pattern `validatePattern` rejects only invalid shapes** — anything looking valid (e.g. `frequency=year, count=10000`) generates up to MAX_PER_SERIES_PER_RUN events on each run forever. Cap exists per-run; could fill years of cycle_numbers if left alone.

## Idempotency gaps catalogued

- `system_events`: no unique constraint anywhere. The append-only design assumes idempotency via in-app `processed_at` filter + per-emitter dedup queries. Vulnerable to: dual emit-event-reminder-events runs, dual auto-close-events runs (status filter saves it), manual operator emits.
- `notifications_outbox`: no idempotency key. Two `start_vote()` calls → two outbox rows → two pushes. RPCs that gate themselves (start_vote checks open vote unique mig 00025) are safe; raw inserts from edge functions are not.
- `user_actions`: no unique constraint on `(user_id, action_type, reference_id)`. mig 00133 (hostAssigned) comments say "events insert is the only fire path" — fragile assumption. Future swap mechanism will need a `ON CONFLICT` strategy.
- `event_attendance`: unique on `(event_id, user_id)` — solid.
- `vote_casts`: unique on `(vote_id, member_id)` — solid.
- `fines`: no unique on `(resource_id, user_id, rule_id, status)` — proposeFine dedups in app code instead. Bypass risk if a future caller forgets.
- `rule_firings`: **table doesn't exist** despite being referenced in `emit-event-reminder-events/index.ts:41` as a downstream idempotency layer. Comment lies.

## Race conditions identified

- **finalize_vote vs cast_vote** (critical, see above).
- **pay_fine double-pay** vs `fund_balance` increment (high, see above).
- **create_event_v2 cycle_number collision** under concurrent creates (low, but lurks).
- **emit-event-reminder-events + manual curl** → dupes (medium).

## Multi-device sync gaps

- Realtime present on: `event_attendance` only (`RSVPRealtimeService.swift:43-67`).
- Missing on: `votes`, `vote_casts`, `fines`, `user_actions`, `rules`, `system_events`, `resources`, `group_members`, `resource_capabilities`.
- Symptom: User A opens a vote on iPhone; user B on iPad sees nothing until manual pull-to-refresh. User pays a fine on phone; the same fine row still shows "Pendiente" on tablet until refresh.

## Offline / network-drop behavior

- No caching layer in any Live repository. All reads hit network. Offline → blank screens with toast errors. No optimistic write queue.
- RSVP errors silently log via `log.warning` in `RSVPRepository.swift:86`+ — UI state doesn't reflect failure unless coordinator surfaces it.
- Sentry MVP only captures crashes (`TandasApp.swift:174` `tracesSampleRate=0`). Repo-level errors during normal flow are invisible.

## Time zone / DST risks

- Server stores everything `timestamptz` — correct.
- iOS uses `Calendar.current` for same-day comparisons → wrong for cross-TZ groups.
- `hostAssigned` user_action body string hardcodes UTC formatting (mig 00133:52) — date shifts by 1 day for users west of UTC after ~18:00.
- DST: no observed special handling. The `next_host_for_series` logic is hash/index-based, not date-arithmetic, so DST transitions don't shift rotation; but recurrence pattern generation in `recurrence.ts` (not surveyed deeply) could shift the wall-clock hour after DST.

## Auth / session edge cases

- `signOut` does not revoke APNs token (critical).
- Anonymous → phone link via `link_anon_user` (not surveyed; CLAUDE.md mentions it).
- `LiveOTPService.swift:82` does a single `refreshSession()` after OTP verify. No periodic refresh loop on app launch — relies on supabase-swift's internal refresh.
- `record_system_event` correctly gates on membership for authenticated callers (mig 00094) — privilege escalation surface is closed.

## Cron overlap / duplicate-execution risks

- pg_cron serializes by job name, so a single job can't overlap with itself. But an operator triggering via curl + the scheduled run is unprotected for: `emit-event-reminder-events`, `emit-deadline-events`, `process-system-events` (last one's `processed_at` filter saves it).
- The hard-coded anon JWT in every cron migration (`00030`, `00069`, `00131`) means anyone with the public anon key can manually trigger crons — by design but the JWT-as-source-of-trust assumption is implicit. `verify_jwt=true` on the function only gates anon vs nothing.

## Brutally honest verdict

**Could the app survive 30 days with 5 real groups (50 users) without an embarrassing incident? Maybe — but with at least 1 visible glitch most weeks.**

Most paths are solid; the architecture is conservative (server-only rule engine, polymorphic ON CONFLICT, audited migrations). The risks are concentrated in three failure modes:
1. Push notifications cross-contaminating across users on shared devices (critical privacy concern with family/friends).
2. Silently-dropped pushes when the dispatcher crashes mid-row (1/day expected with edge cold-starts).
3. The lack of realtime sync across most tables — a couple swapping phones during a vote will see stale state and re-tap, masking other bugs.

**Top 3 reliability blockers before external beta:**

1. **Fix `signOut` to revoke APNs token + delete `notification_tokens` row.** Two lines in `SettingsSheet.swift:128` and `MainTabView.swift:438`. Without this, every shared-device beta tester is a privacy incident waiting.
2. **Add an `outbox janitor`** that resets `dispatched_at=NULL, dispatch_status='pending'` for rows where `dispatch_status='pending' AND dispatched_at < now() - interval '5 minutes'`. Doc literally asks for it.
3. **Fix `finalize_vote` race:** add `SELECT ... FROM vote_casts WHERE vote_id = p_vote_id FOR UPDATE` inside the locked section, or take an advisory lock keyed on vote_id at the top of both `cast_vote` and `finalize_vote`. Governance votes losing ballots is the single worst possible Beta 1 perception.

Bonus quick wins: unique partial index on `system_events(resource_id, event_type, (payload->>'hours'))` to harden `hoursBeforeEvent`; swap the UTC `to_char` in mig 00133 for group-tz formatting (or move the formatting to iOS).
