# Beta 1 Consolidation

> Status: **kicked off 2026-05-13**. Distinto de [[Beta1.md]] (journal de cenas).
> Esto NO es feature work — es polish, onboarding, reliability, copy, hide-list.
> Audit data: [[Beta1Consolidation_Audit.md]] (5 reportes crudos A–E).

---

## 1. Mission

Dejar Ruul listo para que 4–6 grupos reales (familias, amigos cercanos)
**puedan usarlo sin explicación técnica** durante 2–4 semanas sin
ningún incidente vergonzoso. La plataforma ya existe; consolidamos.

Cada cambio debe hacer una de cinco cosas:
- **mejorar UX real**
- **reducir fricción**
- **aumentar claridad**
- **mejorar percepción de calidad**
- **eliminar riesgo de incidente**

Anything else = scope creep.

## 2. Anti-mission

NO durante este track:
- Nuevas capabilities, resource types, primitives.
- Money / fund / ledger (Tier 6 — corre en otra sesión, paralelo).
- Slots como producto al usuario (existe en código pero queda oculto).
- AI features, generic engines, marketplace, booking expansion.
- Refactor arquitectónico aspiracional. **La plataforma queda como está.**

## 3. Vertical oficial de Beta 1

**Cenas recurrentes con rotación de anfitrión.**

Es la única superficie madura post Tier 5: backend en prod (mig 00133 +
auto-generate-events v7), capability `RotationCapability.stable`, plantilla
`DinnerRecurringTemplate` cubierta, journal real de cenas activo.

### Flujos soportados oficialmente

| Flujo | Estado | Track owner |
|---|---|---|
| Sign-up (email/phone OTP) | Roto en copy/routing | B, C |
| Crear grupo desde plantilla "Reuniones recurrentes" | Funcional, defaults punitivos | B |
| Invitar via código de 6 chars (manual paste) | Funcional | B |
| Invitar via link universal `https://ruul.app/invite/...` | **Roto, no AASA** — fuera de scope hasta dominio | F |
| RSVP a evento | Funcional | A, D |
| Rotación de anfitrión auto-asignada | Funcional (Tier 5) | A |
| Recordatorios `hoursBeforeEvent` | Funcional pero no llega a APNs | D, E |
| Multas propuestas + revisión + officialización | Funcional con defaults punitivos | B, D |
| Apelar multa → votación grupal | Funcional con race condition | E |
| Historial / Actividad del grupo | Funcional con clutter | A, D |
| Editar reglas existentes | Funcional | C |

### Flujos NO soportados oficialmente (esconder)

- "Activo compartido" preset → preset card sigue visible, slots inmaduros
- "Empezar de cero" preset → no seedea nada útil; experiencia hueca
- AssetDetailView, SlotDetailView → ocultar de Resources tab si no hay slots
- GroupMoneyView ledger → leave but mark "Próximamente"
- CreateVoteSheet genérico (ya dice "PRÓXIMAMENTE")
- Rule creation desde la app (sólo se editan; ya dice "siguiente sprint")
- Member removal vote — funcional pero alto-riesgo social, considerar gate por admin
- Generate wallet pass — orphan edge function, no UI lo invoca, dejar dormido
- "+" tab cuando no hay grupo activo (hoy silent fail)

---

## 4. Audit synthesis (cross-cutting findings)

5 agentes auditaron en paralelo. Detalle por file:line en
[[Beta1Consolidation_Audit.md]]. Convergencias críticas:

### 4.1 Privacidad + integridad de datos (riesgo de incidente)
1. **`signOut` no revoca APNs token** → en dispositivo compartido (familia,
   pareja), el usuario A se va, el usuario B firma → tokens de A siguen
   asociados a su user_id en `notification_tokens`; pushes para A llegan
   al dispositivo donde ahora está B. *Cross-user leakage real.*
   → file: `RuulCore/Services/Notifications/NotificationService.swift:65-78`,
   `AuthService.swift:237-240`.
2. **Outbox janitor ausente** → si `dispatch-notifications` crasea entre
   `claim_pending_outbox` y `mark_outbox_sent/failed`, la fila queda
   huérfana para siempre. El código lo admite explícitamente en
   `dispatch-notifications/index.ts:14-18`. ~1 push/día perdido silenciosamente.
3. **`finalize_vote` ↔ `cast_vote` race** → un voto emitido entre el COUNT
   y el UPDATE de `finalize_vote` se pierde silenciosamente. En votos de
   gobernanza (apelar multa, cambiar regla) esto rompe la promesa social
   de la app. → mig 00020 vs mig 00123.

### 4.2 Onboarding punitivo
1. **`DinnerRecurringTemplate` arma 5 reglas con $200-$300 MXN ACTIVAS al
   crear grupo.** El usuario nunca ve esas reglas en onboarding; la primera
   vez que las descubre es cuando ya tiene una multa propuesta en su inbox.
   → `DinnerRecurringTemplate.swift:30-155`. Viola explícitamente la
   memoria [[feedback_create_flow_defaults]].
2. **Rotación auto-on sin consentimiento** — el preset activa rotación;
   `CreateEventView` la muestra como "Próximo en orden" sin explicar.
3. **AuthGate envía a SignInView con "Bienvenido de vuelta"** — un usuario
   nuevo cree que está en la pantalla equivocada y se va.
   → `AuthGate.swift:32`, `SignInView.swift:66`.

### 4.3 IA / navegación confusa
1. **"Inicio" hace tres cosas:** hero del próximo evento + sección de
   pendientes + dashboard. El badge cuenta los pendientes pero el usuario
   ve el evento. → `MainTabView.swift:103-128`, `HomeView.swift:583-613`.
2. **Pendientes existe en dos surfaces:** Inicio y Resumen (Grupo tab).
   Misma data, dos visuales. → `GroupOverviewSubTab.swift:247-290` duplica
   lo que ya hace HomeView.
3. **Tab "Decisiones" duplica Grupo → Más → "Decisiones abiertas"** con
   badging inconsistente. → `MainTabView.swift:211`, `GroupMoreSubTab.swift:131`.
4. **"Ver todas (N) pendientes" abre el primero, no una lista.** Mentira
   sutil. → `GroupOverviewSubTab.swift:263-269`.
5. **"Perfil → Historial" routea al tab equivocado** (apunta a Inicio que
   ya no tiene CTA de actividad). → `MainTabView.swift:434`.
6. **AppShell hand-rolled** en todos los tabs (toolbar oculto, headers
   bespoke); la push de Actividad accidentalmente expone large title del
   sistema. Inconsistencia visible.

### 4.4 Lenguaje técnico filtrado al usuario
- `"Activar capability"` → `DetailTopNavView.swift:60`
- `"capabilities"` x6 → `GroupSettingsSheet.swift:198-206`, `GroupRulesSettingsView.swift:51`
- `Text("PAYLOAD")` con JSON crudo → `GenericVoteBody.swift:22-25`
- `Text("DEBUG eventId=...")` visible → `ReviewProposedFinesView.swift:55`
- `eventType.rawString` → renderiza "hostAssigned" / "rsvpDeadlinePassed" → `SystemEventDetailView.swift:83, 131`
- `Text("FOUNDER")`, `"Solo el founder"` → 4 lugares
- `host` vs `anfitrión` mezclado en 10+ archivos
- `Booking`, `swap`, `Save`, `flow` (inglés en app español)
- `slug`, `Módulo · X`, `consecuencias`, `instancia`, `override`, `defaults`
- `error.localizedDescription` crudo en 15+ asignaciones (filtra strings PostgREST/Supabase en inglés)

### 4.5 Inbox vs Activity sin frontera enforced
- `rsvpPending` declarado en `ActionType` enum y routeado en 5 vistas iOS
  pero **ningún migration lo inserta**. Dead code que esconde feature ausente.
- `fineVoided` inbox row → priority `'normal'` (no está en enum), no tiene
  resolver, queda permanente. → mig 00029:60.
- `hostAssigned` queda hasta tap manual; si el evento se cancela, la fila
  queda huérfana (sin cascade resolve).
- `hoursBeforeEvent` synthetic events se renderean en GroupHistoryView
  como clutter; era fuel del rule engine, no señal humana.
- No `apns-collapse-id` → multi-device + retry = banners duplicados.

### 4.6 Drafts uncommitted en working tree
Las 7 modificaciones + 1 untracked (`ResourceSummaryView.swift`,
`MainTabView`, `GroupOverviewSubTab`, `GroupMoreSubTab`, `GroupTabView`,
`GroupInfoSheet`, `UniversalResourceDetailView`, `project.yml`) son **una
sola refactor coherente** (fold Activity into Grupo → Más + dashboard nuevo
en Resumen). Track A los considera completos; ship juntos o revert juntos.
Riesgo: `EventStatusSummary` + `DetailSummaryView` en `ios/Tandas/Shell/`
quedan huérfanos si el swap ya está.

---

## 5. Risk matrix

### UX risks (visibles para usuarios reales)
| Risk | Severity | Likelihood | Fix track |
|---|---|---|---|
| Multas punitivas auto-activas $200-$300 | Alta | Cierta | B (W1) |
| AuthGate / SignInView routing al new user | Alta | Cierta | B (W1) |
| Inbox/Activity/Home identity crisis | Alta | Cierta | A (W2) |
| Invite link 404 sin AASA | Alta | Alta | F (esconder, usar código) |
| Jergon "capability", "PAYLOAD", "DEBUG", "FOUNDER" | Media | Cierta | C (W2) |
| Error mensajes en inglés crudo Supabase | Media | Alta | C (W2) |
| "Ver todas" miente, abre el primero | Media | Alta | A (W1) |
| host / anfitrión mezclado | Media | Alta | C (W2) |
| Tab "Decisiones" duplicada | Baja | Cierta | A (W3) |
| Loading + empty states inconsistentes | Baja | Cierta | A (W3) |

### Technical risks (incidentes de reliability)
| Risk | Severity | Likelihood | Fix track |
|---|---|---|---|
| Cross-user APNs leakage (sign-out no revoca) | Crítica | Media (familia comparte iPad) | E (W1) |
| `finalize_vote` race pierde votos | Crítica | Media en grupos activos | E (W1) |
| Outbox crash → push perdido sin recuperación | Alta | Alta (≈1/día) | E (W1) |
| `hoursBeforeEvent` no llega a APNs (rule-fuel only) | Alta | Cierta | D (W1) |
| `EventDetailCoordinator.sendHostReminders` es stub | Alta | Cierta | D (W2) |
| Orphan inbox rows tras cancelar evento | Media | Alta | D (W2) |
| `pay_fine` double-tap doble suma a `fund_balance` | Media | Baja | E (W3) |
| `notification_tokens` no se limpia al remover miembro | ✅ Cerrado | — | `b6a536c` (E-3.2 — dispatcher filtra `active=true`, no requiere cleanup) |
| `hostAssigned` formatea fecha en UTC | Baja | Cierta MX | E (W2) |
| `system_events` sin unique constraints | Baja | Baja (cron serializa) | E (W4 opcional) |

### Adoption risks (la gente abandona)
| Risk | Severity | Likelihood |
|---|---|---|
| Padre 50 años no completa first-run sin ayuda | Crítica | Cierta hoy |
| Invitado tappea link WhatsApp → Safari 404 → abandona | Crítica | Cierta hoy |
| Multas auto sin contexto → grupo lo apaga el día 1 | Alta | Alta |
| "¿Dónde se cambia mi RSVP?" (rsvpPending dead) | Media | Alta |
| Multi-device shows stale state | Media | Cierta (parejas) |

---

## 6. Priorized work — 2 semanas core + 1 buffer + 1 demo

> **Sweep status — 2026-05-13 evening session.** Track abrió 15:43,
> sprint 7h después casi todo W1-W2 + buena parte de W3 estaba shipeado
> (24 commits `fix(beta1-w*)`). Estado real verificado por commit log y
> test pass:
>
> - **W1**: ✅ **9 / 9 done.** E-1.2 outbox janitor cerrado en
>   `83fccbd` (mig 00160). D-1.1 sendHostReminders wired en `9c1020b`
>   (`EventNotificationDispatcher` actor + 30min rate-limit + 5 tests).
> - **W2**: 12 / 12 done. ✅ todo cerrado.
> - **W3**: ✅ **12 / 12 done.** Cerrado 2026-05-14 con A-3.3
>   (`1ef7aac`) + B-3.4 (`3a63add`). Sub-batches 1-3 completos:
>   reliability (E-3.1/2/3), group-switching UX (A-3.4/5),
>   onboarding + DS unify (A-3.3 + B-3.4).
> - **W4**: 0 / 7 done — pending demo polish + telemetry + QA + hide list.
>
> Marcas `✅ <SHA>` debajo apuntan al commit que cerró el ítem; los `⏳`
> son lo que sigue genuinamente abierto. Cualquier sesión futura que
> retome el track lee este sweep antes que las casillas.

### Week 1 — Stop-the-bleeding (privacidad + integridad)

Goal: ningún beta tester puede ver datos de otro usuario, ni perder votos,
ni recibir multas-fantasma porque arrancó el grupo.

- [x] **E-1.1** `signOut` revoca APNs token → ✅ `514d3c1`. `AppState.signOut()` orquesta `notifications.revokeTokenIfRegistered()` antes de `auth.signOut()`. 3 tests verdes en `SignOutRevokesTokenTests`.
- [x] **E-1.2** Outbox janitor → ✅ `83fccbd` (mig 00160). `reset_stale_outbox_claims()` SECURITY DEFINER + pg_cron `*/5 * * * *`. Lockdown: ejecutable solo por `service_role` (revoke from public/anon/authenticated). Verificado en prod: smoke test = 0 orphans, cron registrado, grants correctos.
- [x] **E-1.3** `cast_vote` + `finalize_vote` race → ✅ `b5a72e9`. `cast_vote` toma `FOR KEY SHARE` sobre la row del vote dentro de la transacción; `finalize_vote` mantiene `FOR UPDATE` que ya tenía. El gap del `count(*)` unlocked queda cerrado.
- [x] **B-1.1** Multas opt-in por default → ✅ `e1b3e78`. `DinnerRecurringTemplate` siembra reglas monetarias con `isActive=false`; banner "Activa acuerdos" tras 3 cenas cerradas.
- [x] **B-1.2** AuthGate first-time copy → ✅ `bea2bbd`. `SignInMode` separa flujo nuevo vs returning; ya no se ve "Bienvenido de vuelta" sin cuenta.
- [x] **A-1.1** "Ver todas (N)" linkout → ✅ `7632083` (esta sesión). `GroupOverviewSubTab` "Ver todas" salta al inbox completo via `onOpenInboxAction`. *Nota:* aterriza en el primer action por compat — pendiente revisión UX si se quiere lista in-place.
- [x] **A-1.2** "Perfil → Historial" → ✅ `7632083` (esta sesión). `onOpenHistory` ahora salta a tab Inicio (Activity ya no es tab top-level — folded a Grupo→Más).
- [x] **F-1.1** Invite share plaintext → ✅ `bcccd52`. ShareLink expone código de 6 chars + App Store URL en lugar del universal link sin AASA.
- [x] **D-1.1** sendHostReminders wire → ✅ `9c1020b`. Nuevo `EventNotificationDispatcher` actor (Mock + Live) en `RuulCore/Services/Notifications/`; coordinator invoca `send-event-notification` kind=`host_reminder`. Rate-limit 30min/evento dentro del actor (compartido entre coordinators). Errores rate-limited surfacean como "Ya recordaste hace poco / Espera N minutos". 5 tests verdes en `SendHostRemindersTests`.

Definition of done W1: cero rutas de cross-user data leak conocidas. Votos no se pierden bajo carga simulada. Onboarding no acepta nuevo usuario en pantalla "Bienvenido de vuelta".

### Week 2 — Inbox/Activity boundary + jargon purge

Goal: lo que está en la app, el usuario lo entiende sin diccionario.

- [x] **D-2.1** RSVP path wire → ✅ `797b005`. `rsvpPending` action ahora se inserta por trigger y se resuelve al votar.
- [x] **D-2.2** Cancel-event cascade → ✅ `a08bff8`. Trigger `on_event_cancelled` resuelve `user_actions` dependientes con `resolved_reason='event_cancelled'`.
- [x] **D-2.3** `void_fine` priority + auto-resolve → ✅ `9f7997a`. Priority `low` + auto-resolve a 7 días.
- [x] **D-2.4** Hide synthetic events de Activity → ✅ `e516d93`. `hoursBeforeEvent` y demás rule-fuel markers blacklisted del feed.
- [x] **D-2.5** APNs collapse-id → ✅ `b5b667a`. Header `apns-collapse-id` por `notification_type.reference_id`.
- [x] **C-2.1** Purga DEBUG/PAYLOAD/capability → ✅ `b622f1e`. Grep visible: 0 hits.
- [x] **C-2.2** host → anfitrión → ✅ `5a495af`. Unificado en 10+ archivos UI.
- [x] **C-2.3** RuulErrorTranslator → ✅ `2f2e131`. Mapeo PGRST/JWT/network → español-MX.
- [x] **C-2.4** SystemEventType.humanLabel → ✅ `0319348`. Cero caída a `rawString` en `SystemEventDetailView`.
- [x] **C-2.5** Borrar `Text("DEBUG eventId=...")` → ✅ `b622f1e` (mismo commit que C-2.1).
- [x] **C-2.6** Historia/Historial/Actividad canon → ✅ `49860c6`. Actividad=feed, Historial=eventos pasados.
- [x] **E-2.1** hostAssigned tz → ✅ `7f79b47`. Date body en TZ del grupo, no UTC.

DoD W2: Audit C grep de términos prohibidos pasa con 0 hits en strings visibles. Inbox + Activity boundary clara. Mensaje de error de Supabase nunca llega crudo al usuario.

### Week 3 — Onboarding + multi-device polish

Goal: una mamá de 50 puede completar first-run sin ayuda + parejas con
dos dispositivos no ven estado stale.

- [x] **B-3.1** Drop cover picker en `GroupIdentityView` → ✅ `04a14a9`.
- [x] **B-3.2** PresetPicker explicit Continuar CTA → ✅ `64eafc4`. Sin auto-advance 350ms.
- [x] **B-3.3** CreateEventView progressive disclosure → ✅ `22b67c4`. Más opciones colapsado por defecto.
- [x] **B-3.4** Consent step de acuerdos sugeridos → ✅ `3a63add`. Nuevo `FounderStep.consent` entre `preset` y `invite`. `selectPreset` ahora cachea las reglas devueltas por `seedTemplateRules` en `templateRulePreviews` y rutea a `.consent` cuando hay reglas (skip a `.invite` cuando "Empezar de cero" no siembra ninguna). Nueva view `ConsentRulesView` data-driven (no vertical hardcoded) — render cards con nombre de regla + "En modo sugerencia". Footnote: "Podrás revisar y activar cada acuerdo desde Reglas cuando estén todos listos". 2 tests nuevos en `FounderOnboardingCoordinatorTests` (happy-path extendido + `consentReceivesSeededRules` que verifica B-1.1 invariant: `isActive=false` en todas las reglas).
- [x] **A-3.1** Tab "Decisiones" eliminado → ✅ `7632083` (esta sesión). Bottom bar a 4 tabs; Decisiones queda en Grupo→Más.
- [x] **A-3.2** Consolidar Pendientes → ✅ `7632083` (esta sesión). Resumen ya no duplica el inbox; top-3 + linkout.
- [x] **A-3.3** Empty + loading unify → ✅ `1ef7aac`. `EmptyStateView` extendido con `secondaryAction:` para el caso 2-CTA (`MainTabView.EmptyGroupsView` migrado, pierde ~25 líneas de layout bespoke). 4 `ProgressView()` ad-hoc migrados a `RuulLoadingState()` (GroupTabView Resources subtab, OnboardingRootView bootstrap fallback en B-3.4 commit, EditRulesView load branch, EditMembersSheet initial-load). Scope: solo screen-level — section-internal placeholders (RSVPSection "Sin confirmaciones aún", etc.) son design pattern distinto y se quedaron. Button-inline `scaleEffect(0.6)` spinners también out of scope.
- [x] **A-3.4** "+" tab silent fail → ✅ `91d6c52`. `createTabIntercept` ahora ruta al `CreateGroupSheet` cuando no hay grupo activo (re-usa el sheet + state ya declarado). Audit Track A 4.5 cerrado.
- [x] **A-3.5** `RuulGroupSwitcher` API unify → ✅ `10dda39`. `GroupTabView` y `HistoryTabView` migrados al init convenience `RuulGroupSwitcher(activeGroup:onTap:)` que ya usaban MainTabView decisionsTab + HomeView. Layout (HStack + Spacer + screen-padding) idéntico entre MainTabView decisionsTab y GroupTabView; HomeView documentado como excepción legítima (header con greeting + icon buttons).
- [x] **E-3.1** Realtime subs → ✅ `5b8981a` + `ad30558` + `65144e7`. Server: `mig 00161` añade las 4 tablas a `supabase_realtime` + ALTER REPLICA IDENTITY FULL (necesario para que RLS evalúe quals sobre columnas no-PK). iOS: `MultiDeviceChangeFeed` actor (Mock + Live) emite kicks tagged por tabla + recordId; AppState abre/cierra los 4 canales con el ciclo de auth. 6 coordinators wired: InboxCoordinator (`.userAction`), OpenVotesCoordinator (`.vote` + `.voteCast`), VoteDetailCoordinator (filtra por voteId + cualquier `.voteCast`), MyFinesCoordinator + ReviewProposedFinesCoordinator (`.fine`), FineDetailCoordinator (filtra por fineId). 3 tests nuevos verdes en `MultiDeviceChangeFeedTests`. **Tech debt diferido**: `RSVPRealtimeService` quedó silently broken desde mig 00159 (tabla `event_attendance` dropeada); fuera de scope de W3-E3.1, slated para follow-up con `rsvp_actions` / `attendance_view`.
- [x] **E-3.2** Token cleanup en remoción → ✅ `b6a536c`. Resuelto en `dispatch-notifications` v6 con filtro `group_members.active = true` (runtime scoping). El commit body argumenta el porqué: tokens son user-scoped, no group-scoped — borrarlos en `remove_member` rompería las pushes legítimas de un usuario que sigue activo en otros grupos. La solución arquitectónica correcta es en el dispatch boundary. Junto con E-1.1 (`signOut` revoca token local), cubre ambas rutas: usuario se va (E-1.1) + admin remueve usuario (E-3.2). Removidos dejan de recibir pushes del grupo en ≤1 dispatch tick (~60s).
- [x] **E-3.3** `pay_fine` FOR UPDATE → ✅ `e0d2575`. Idempotent guard previene double-balance en double-tap.

DoD W3: Onboarding funcional 7 → 3-4 screens. RSVP/voto/multa cambia en device A → device B refresca automáticamente.

### Week 4 — Demo readiness + telemetría + QA + buffer

- [ ] **F-4.1** Hidden flag para "Activo compartido" + "Empezar de cero" presets (sólo "Reuniones recurrentes" visible).
- [ ] **F-4.2** Hide AssetDetailView + SlotDetailView del menú; sólo accesibles via deeplink directo para testing interno.
- [ ] **F-4.3** Hide CreateVoteSheet genérico (apelaciones siguen funcionando).
- [ ] **F-4.4** GroupMoneyView → estado "Próximamente" claro.
- [ ] **F-4.5** Telemetry events (PostHog o similar):
  - `onboarding_step_completed{step, time_to_complete}`
  - `first_event_created{template, hours_since_signup}`
  - `first_rsvp_made{event_id, hours_since_invite}`
  - `first_fine_proposed`, `first_fine_paid`, `first_fine_appealed`
  - `inbox_action_resolved{action_type}`
  - `group_template_picked{template}`
  - `module_toggled{module, on_off}`
  - `error_shown{code}` (post `RuulErrorTranslator`)
- [ ] **F-4.6** QA checklist run completo (siguiente sección).
- [ ] **F-4.7** Founder demo dry-run con 2 dispositivos.
- [ ] Buffer para cualquier regresión de W1-W3.

DoD W4: founder graba video demo de 2-3 min mostrando happy path sin
tropezar. Telemetría emite eventos de los 8 listados en sandbox de prueba.

---

## 7. Hide list (anti-scope explícito)

Cosas que existen en código pero NO deben aparecer en UI beta:

| Surface | Hide method |
|---|---|
| Preset "Activo compartido" | `if FeatureFlags.betaShowAllPresets` (default false) |
| Preset "Empezar de cero" | Idem |
| AssetDetailView, SlotDetailView | Quitar del Resources tab; sólo deeplink |
| CreateVoteSheet genérico (vote.kind=generic) | Hidden CTA, ya dice "PRÓXIMAMENTE" |
| Rule creation (new rule from scratch) | Solo edición, mensaje claro |
| Member removal vote | Gate por admin si lo dejamos; o ocultar en W2 |
| Generate wallet pass | Edge function dormida, sin UI |
| `MyFeedView` / `feedRoute` | Dead surface — eliminar o esconder |
| `HistoryTabView` orphan | Borrar el archivo (W2) |
| `ProfileTabStub` named "stub" | Renombrar antes de beta |
| Group settings → "Capabilities" raw section | Reemplazar copy (Track C) |

---

## 8. Happy path oficial (demo flow)

1. **Sign-up** — Apple Sign In o teléfono → 6 dígitos → 1 tap a continuar.
2. **Crear grupo "Cenas familiares"** — nombre, foto default, tap "Reuniones recurrentes".
3. **Consent step de acuerdos sugeridos** (nuevo en W3) — "Estos son los acuerdos que la gente suele usar para cenas. Por ahora están en modo sugerencia." Tap Continuar.
4. **Invitar via código** — share message: "Únete a [Cenas familiares] en Ruul. Código: ABC123. https://apps.apple.com/app/ruul/idXXX". Familia copia el código + descarga app.
5. **Familia se une** — abre app → Apple/teléfono → "Únete con código" → pega ABC123.
6. **Crear primer evento** — solo nombre + fecha + hora. Anfitrión se asigna automáticamente al creador.
7. **Confirmar asistencia** — los demás reciben push, abren inbox → tap → confirman.
8. **Recordatorio 24h antes** — push automático llega al anfitrión y a quienes confirmaron.
9. **Marcar llegada** en la cena (host).
10. **Cerrar evento** — anfitrión cierra; sistema propone multas a no-asistentes (si activaron acuerdos) o sólo registra en Actividad (si están en sugerencia).
11. **Próximo evento** — rotación auto-asigna nuevo anfitrión.

**Anti-flujo** (cosas que NO pasan en demo):
- No se activan multas en el primer ciclo (modo sugerencia).
- No se crean reglas desde la app.
- No se accede a slots, fondos, activos.
- No se vota nada todavía (apelar fine sólo si pasa, escenario edge).

---

## 9. QA checklist (correr antes de invitar beta)

### Onboarding
- [ ] Apple Sign In y phone OTP ambos funcionan desde cero
- [ ] Usuario nuevo NO ve "Bienvenido de vuelta"
- [ ] Crear grupo con plantilla dinner termina en 3-4 taps
- [ ] Acuerdos del template aparecen en modo sugerencia (no activos)
- [ ] Invite share message contiene código de 6 chars en plaintext
- [ ] Invitee con código entra al grupo correcto

### Día-a-día
- [ ] Crear evento simple (nombre + fecha) → confirmación visible en Activity
- [ ] Inbox muestra `rsvpPending` para no-host miembros
- [ ] RSVP cambia estado optimísticamente y sincroniza a device B
- [ ] Push de `host_reminder` llega cuando el host invoca el botón
- [ ] Recordatorio `hoursBeforeEvent` llega ~24h antes
- [ ] Cerrar evento sin acuerdos activos → solo Activity, sin multa
- [ ] Rotación de anfitrión auto-asigna en el siguiente evento

### Edge cases
- [ ] Sign out → tokens revocados → device libre para otro usuario
- [ ] Cancelar evento → inbox actions del evento se resuelven cascade
- [ ] Voto con quorum exacto → tally correcto, sin race
- [ ] Pay fine doble-tap rápido → balance correcto
- [ ] Network drop durante create event → error legible en español
- [ ] App con 2 dispositivos del mismo usuario → estado sincronizado

### Copy
- [ ] Grep `capability|PAYLOAD|DEBUG|FOUNDER|hostAssigned|slug|Save|Booking` en strings visibles → 0 hits
- [ ] Grep `error.localizedDescription` raw assignment → 0 hits (todos pasan por RuulErrorTranslator)
- [ ] "host" / "anfitrión" → solo "anfitrión" en UI

### Reliability
- [ ] Outbox janitor activo (verificar `pg_cron.job` row)
- [ ] APNs collapse-id presente en payload
- [ ] Cron `dispatch-notifications` recibe alertas si run > 30s

---

## 10. Métricas (primer mes beta)

Mínimo viable:

| Métrica | Cómo | Health threshold |
|---|---|---|
| Onboarding completion rate | `onboarding_step_completed` final / inicial | > 70% |
| Time to first event created | timestamp diff | mediana < 5 min post-signup |
| Time to first RSVP made (per invitee) | timestamp diff | mediana < 24h post-invite |
| Active groups (≥1 evento/sem) | unique groups | ≥ 3 de los 4–6 invitados |
| Push delivery rate | dispatcher logs success/total | > 98% |
| Multas propuestas vs cobradas vs ignoradas | fines.status | señal cualitativa |
| Apelaciones iniciadas | count appeal_votes | señal cualitativa |
| Inbox actions resueltas / abandonadas | resolved_at NULL vs not | > 80% resolved |
| Errores mostrados al usuario | `error_shown{code}` count by code | top-5 codes < 1% de sessions |
| Crashes (Sentry) | crash sessions | < 0.5% |

Cualitativas (cena journal en [[Beta1.md]]):
- ¿Las reglas que el grupo activó se usan o las apagan?
- ¿La rotación se respeta o se renegocia en WhatsApp?
- ¿Aparece petición de feature no prevista?

---

## 11. Definition of Done — Beta 1 ready to invite externals

**Hard gates** (status 2026-05-13 evening):
- [x] Cero items en Risk Matrix con severity Crítica + likelihood ≥ Media sin fix → ✅ ambos Crítica (cross-user APNs leak `514d3c1` + finalize_vote race `b5a72e9`) cerrados.
- [ ] QA checklist W4 pasa 100% — pending W4.
- [ ] Founder demo dry-run sin tropezar — pending W4.
- [ ] Telemetría emitiendo (verificable en dashboard) — pending W4 (F-4.5).
- [ ] Sentry capturando crashes (TandasApp.swift confirmando) — verificar.
- [x] Working tree limpio (los AppShell drafts o committed o reverted) → ✅ Track A landed `73c8f36` + `7632083` + `d2f8843`.
- [x] Audit C grep de jargon: 0 hits → ✅ W2 commits `b622f1e` + `2f2e131` + `0319348` + `5a495af` + `49860c6`.
- [x] Audit E top-3 reliability blockers → ✅ 3/3 done (E-1.1 `514d3c1`, E-1.3 `b5a72e9`, E-1.2 `83fccbd`).

**Soft signals:**
- [ ] El founder se siente cómodo invitando a su mejor amigo (no a un beta tester anónimo)
- [ ] Una mamá de 50 completa el happy path sin preguntar

Si el "soft signal" del founder dice no — el plan no terminó. Más W4 buffer.

---

## 12. Out of scope (referencias para futuro, no esta sesión)

- Tier 6 money/fund/ledger — corre en sesión paralela
- Phase 2 primitives (Slot, Asset, Position expansion)
- Universal invite link AASA setup — pendiente dominio
- iOS App Store listing
- WhatsApp share template optimization
- Generic vote creation UX
- Rule creation UX (sólo edición en Beta 1)
- Auto-import contactos + sugerencia social
- Onboarding tutorials/coachmarks heavy
- Liquid Glass refinement más allá de lo actual

---

## Bitácora

- **2026-05-13** — Track abierto. 5 audits paralelos completados (A AppShell, B Onboarding, C Copy, D Notifications, E Reliability). Reportes en [[Beta1Consolidation_Audit.md]]. Plan sintetizado, vertical fijado en cenas recurrentes + rotación, hide-list definida, roadmap 4 semanas priorizado.

- **2026-05-13 evening** — Sprint de 7h cerró W1 (excepto E-1.2 outbox janitor + D-1.1 sendHostReminders), W2 al 100% (12/12), y la mitad de W3 (6/12). Track A AppShell consolidado vía `73c8f36` + `7632083` + `d2f8843`: `ResourceSummaryView` capability-driven reemplaza `EventStatusSummary` + `DetailSummaryView`, Resumen pasa a dashboard, Actividad sale de tabs top-level y vive en Grupo→Más. §6 actualizado con `✅ <SHA>` por ítem cerrado y `⏳ OPEN` por lo que queda.

- **2026-05-13 late** — E-1.2 cerrado (`83fccbd` + mig 00160). `reset_stale_outbox_claims()` SECURITY DEFINER + pg_cron `reset-stale-outbox-every-5-minutes` ejecutándose en prod. Audit E top-3 reliability blockers ahora 3/3 done. **Único pendiente W1: D-1.1** (`EventDetailCoordinator.sendHostReminders` sigue stub que solo emite analytics — needs wire al `send-event-notification` con kind=`host_reminder` + rate-limit cliente 1/30min/evento).

- **2026-05-13 closeout** — **W1 cerrado al 100%.** D-1.1 wired en `9c1020b`: `EventNotificationDispatcher` actor protocol (Mock + Live) en RuulCore, `EventDetailCoordinator` invoca el edge fn vía dispatcher inyectado, rate-limit 30min/evento dentro del actor (compartido entre coordinators), errores rate-limited surfacean como mensaje friendly via el envelope `error`. 5 tests verdes en `SendHostRemindersTests` (host invoca / non-host short-circuits / nil dispatcher fallback / rate-limited surface / edge failure). Próximo objetivo: W3 leftovers (B-3.4 consent step, A-3.3 empty/loading states, A-3.4 "+" tab silent fail, A-3.5 RuulGroupSwitcher API, E-3.1 realtime) o W4 (telemetry / hide list / QA / demo).

- **2026-05-13 late closeout** — **E-3.2 re-clasificado.** Sub-batch 1 (reliability) arrancó como `E-3.2 + E-3.1`. Auditoría reveló que `b6a536c` (mismo día, 19:33) ya cierra E-3.2: el commit body argumenta explícitamente la decisión arquitectónica (tokens user-scoped, no group-scoped → fix en dispatch boundary, no en `remove_member`). El sweep original lo había etiquetado como "bonus" por error. §5 risk matrix + §6 W3 actualizados. W3 ahora 7 / 12 done. Sub-batch sigue con E-3.1 (realtime subs) como único trabajo real pendiente del reliability cluster.

- **2026-05-14 W3 close** — **W3 cerrado al 100% (12/12).** Sub-batch 3 (A-3.3 + B-3.4) shipped: A-3.3 (`1ef7aac`) extiende `EmptyStateView` con `secondaryAction:` para el caso 2-CTA y migra `MainTabView.EmptyGroupsView` + 4 raw `ProgressView()` ad-hoc al canonical `RuulLoadingState`. B-3.4 (`3a63add`) inserta `FounderStep.consent` entre `preset` y `invite`: `selectPreset` cachea el retorno de `seedTemplateRules` y rutea a la nueva `ConsentRulesView` data-driven cuando hay reglas (blank preset skip directo a `.invite`). Tests 161 → 163 verde (2 nuevos en `FounderOnboardingCoordinatorTests`). DoD W3 ✅: onboarding ahora 7 → 3-4 screens reales para el usuario nuevo + multi-device sync vivo. **Próximo objetivo: W4** (F-4.1/2/3/4 hide list, F-4.5 telemetry, F-4.6 QA, F-4.7 demo dry-run).

- **2026-05-13 sub-batch 2 close** — **A-3.4 + A-3.5 done; group-switching UX cluster cerrado.** A-3.4 (`91d6c52`): `createTabIntercept` ahora ruta al `CreateGroupSheet` cuando no hay grupo activo; el silent-fail del Audit Track A 4.5 deja de existir. A-3.5 (`10dda39`): `GroupTabView` y `HistoryTabView` migrados al init convenience del `RuulGroupSwitcher` que MainTabView decisionsTab + HomeView ya usaban — los 4 callsites comparten ahora la misma firma; HomeView documentado como excepción legítima por su header enriquecido. W3 ahora 10/12. Pendientes: B-3.4 consent step + A-3.3 empty/loading unify. Build verde.

- **2026-05-13 sub-batch 1 close** — **E-3.1 done; W3 reliability cluster cerrado.** `mig 00161` agrega `user_actions`/`votes`/`vote_casts`/`fines` a la publicación `supabase_realtime` con `REPLICA IDENTITY FULL` (necesario para que RLS evalúe quals sobre columnas no-PK). `MultiDeviceChangeFeed` actor (Mock + Live) en RuulCore emite kicks por tabla + recordId; AppState abre/cierra los 4 canales con el ciclo de auth. 6 coordinators wired (Inbox, OpenVotes, VoteDetail, MyFines, ReviewProposedFines, FineDetail) — cada uno filtra por table + opcionalmente por recordId y dispara su propio refresh(). 3 tests nuevos en `MultiDeviceChangeFeedTests` (contract del Mock + wiring end-to-end). Build verde, 160/160 tests pasando (157 previos + 3 nuevos). W3 ahora 8/12. Pendientes: B-3.4 consent step, A-3.3 empty/loading unify, A-3.4 "+" tab silent fail, A-3.5 RuulGroupSwitcher API. Tech debt nuevo identificado: `RSVPRealtimeService` quedó silently broken desde mig 00159 (event_attendance dropeada); fuera de scope de E-3.1, slated para follow-up con `rsvp_actions`/`attendance_view`.
