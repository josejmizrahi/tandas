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
| `notification_tokens` no se limpia al remover miembro | Media | Media | E (W3) |
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

### Week 1 — Stop-the-bleeding (privacidad + integridad)

Goal: ningún beta tester puede ver datos de otro usuario, ni perder votos,
ni recibir multas-fantasma porque arrancó el grupo.

- [ ] **E-1.1** `signOut` revoca APNs token → llama `NotificationTokenRepository.revokeToken(lastDeviceToken)` antes de `auth.signOut()`. Verificar también `MainTabView:438` "Cerrar sesión" path.
- [ ] **E-1.2** Outbox janitor — pg_cron 5min: `UPDATE notifications_outbox SET dispatched_at=NULL, dispatch_status='pending' WHERE dispatch_status='pending' AND dispatched_at < now()-interval '5 minutes';`
- [ ] **E-1.3** `finalize_vote` lock: `SELECT count(*) FROM vote_casts WHERE vote_id = p_vote_id FOR UPDATE;` dentro del bloque ya locked + advisory lock keyed on vote_id en `cast_vote` y `finalize_vote`.
- [ ] **B-1.1** `DinnerRecurringTemplate.rules[*].isActive = false` por defecto + flag de "modo sugerencia" en `seed_template_rules`. Después de 3 cenas cerradas, banner "Activa los acuerdos para empezar a cobrar multas".
- [ ] **B-1.2** AuthGate: si `!hasOnboarded && session==nil`, route a una `SignUpWelcomeView` no a `SignInView`. SignInView se usa sólo si el usuario tappea "Ya tengo cuenta".
- [ ] **A-1.1** "Ver todas (N)" en HomeView + GroupOverviewSubTab → routea a `ActionInboxView` montada como push (el orphan view ya existe).
- [ ] **A-1.2** "Perfil → Historial" → corregir route o eliminar la fila si redundante.
- [ ] **F-1.1** Esconder universal invite link en ShareLink — usar plaintext "Únete a [grupo] en Ruul. Código: ABC123. https://apps.apple.com/app/ruul/idXXX" hasta que AASA esté.
- [ ] **D-1.1** Wire `EventDetailCoordinator.sendHostReminders` para que realmente invoque `send-event-notification` con kind=`host_reminder` (con rate-limit cliente: 1 reminder por evento cada 30 min).

Definition of done W1: cero rutas de cross-user data leak conocidas. Votos no se pierden bajo carga simulada. Onboarding no acepta nuevo usuario en pantalla "Bienvenido de vuelta".

### Week 2 — Inbox/Activity boundary + jargon purge

Goal: lo que está en la app, el usuario lo entiende sin diccionario.

- [ ] **D-2.1** Decidir RSVP path: o agregar trigger en `create_event_v2` que inserta `rsvpPending` por miembro no-host → resuelto en `set_rsvp`, o **eliminar `rsvpPending` del enum y de las 5 vistas iOS**. Recomendado: agregar (es lo que el modelo mental promete).
- [ ] **D-2.2** Trigger `on_event_cancelled` que resuelve `user_actions` dependientes (`hostAssigned`, `fineProposalReview`, futuro `rsvpPending`) con `resolved_reason='event_cancelled'`.
- [ ] **D-2.3** `void_fine` (mig 00029:60) — priority `'medium'` (no `'normal'`) + auto-resolve `fineVoided` action después de 7 días o de tap.
- [ ] **D-2.4** Filtrar `hoursBeforeEvent` y demás synthetic markers de `GroupHistoryView` (`LiveSystemEventRepository.query` o `HistoryItemPresentation` blacklist).
- [ ] **D-2.5** APNs `apns-collapse-id = '${notification_type}.${reference_id}'` en `dispatch-notifications/index.ts:213`.
- [ ] **C-2.1** Reemplazar `Text("capability"|"PAYLOAD"|"DEBUG ...")` en los 5 archivos listados en Audit C. Ninguno debe sobrevivir grep.
- [ ] **C-2.2** Unificar **host → anfitrión** en todo el UI visible (10+ archivos).
- [ ] **C-2.3** `RuulErrorTranslator` — wrappear `error.localizedDescription` para mapear PGRST116 / JWT expired / network / etc a mensajes en español-MX. Reemplazar 15+ asignaciones directas.
- [ ] **C-2.4** Mapeo completo de `SystemEventType` → label humano en `SystemEventDetailView`. **Cero** caída a `rawString`.
- [ ] **C-2.5** **Borrar el `Text("DEBUG eventId=...")`** en ReviewProposedFinesView:55.
- [ ] **C-2.6** Unificar "Historia" / "Historial" / "Actividad" — canon: **Actividad** = feed, **Historial** = eventos pasados.
- [ ] **E-2.1** Cambiar `to_char(... at time zone 'UTC')` en mig 00133:52 a TZ del grupo (o quitar la fecha del body, formatear en iOS).

DoD W2: Audit C grep de términos prohibidos pasa con 0 hits en strings visibles. Inbox + Activity boundary clara. Mensaje de error de Supabase nunca llega crudo al usuario.

### Week 3 — Onboarding + multi-device polish

Goal: una mamá de 50 puede completar first-run sin ayuda + parejas con
dos dispositivos no ven estado stale.

- [ ] **B-3.1** Eliminar/auto-default cover image en `GroupIdentityView`.
- [ ] **B-3.2** Quitar auto-advance 350ms del PresetPickerView; agregar "Continuar" explícito.
- [ ] **B-3.3** CreateEventView progressive disclosure: nombre+fecha primero, luego sección opcional "ajustes avanzados" (host, descripción, multas).
- [ ] **B-3.4** Mostrar las 5 reglas (en modo sugerencia tras B-1.1) en un consent step durante onboarding: "Estos son los acuerdos sugeridos para cenas. Puedes activarlos uno por uno cuando quieras."
- [ ] **A-3.1** Decidir: ¿matar el tab "Decisiones" o el row "Decisiones abiertas" de Grupo → Más? Recomendado: matar el tab top-level, queda 4 tabs.
- [ ] **A-3.2** Consolidar Pendientes en una sola surface: Inicio. Quitar duplicado de Resumen.
- [ ] **A-3.3** Unificar empty states a un componente (`EmptyStateView`) y loading a uno (`HomeViewSkeleton` o `RuulLoadingState`).
- [ ] **A-3.4** "+" tab cuando no hay grupo activo → presenta `CreateGroupSheet` en vez de silent fail.
- [ ] **A-3.5** `RuulGroupSwitcher` — una sola API (`activeGroup:` o init unificado) y mismo behavior across los 3 tabs.
- [ ] **E-3.1** Realtime subscriptions en `votes`, `vote_casts`, `fines`, `user_actions` para multi-device.
- [ ] **E-3.2** `notification_tokens` cleanup en `remove_member` RPC o trigger.
- [ ] **E-3.3** `pay_fine` con `FOR UPDATE` en `fines` para evitar double-tap double-balance.

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

**Hard gates:**
- [ ] Cero items en Risk Matrix con severity Crítica + likelihood ≥ Media sin fix
- [ ] QA checklist W4 pasa 100%
- [ ] Founder demo dry-run sin tropezar
- [ ] Telemetría emitiendo (verificable en dashboard)
- [ ] Sentry capturando crashes (TandasApp.swift confirmando)
- [ ] Working tree limpio (los AppShell drafts o committed o reverted)
- [ ] Audit C grep de jargon: 0 hits
- [ ] Audit E top-3 reliability blockers: fixed + verified

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
