# Ruul — UX Journey End-to-End

> Mapa completo del recorrido del usuario, desde la primera instalación
> hasta cada acción posible dentro de la app. Identifica gaps de UX,
> capacidades del backend que aún no están expuestas, y rough edges que
> rompen la fluidez.
>
> Complementa `docs/UXAudit.md` (que audita view por view) cruzando
> capacidades de backend vs. UI y trazando journeys completos.
>
> **Fuentes:**
> - Mapa de flujos iOS: 98 views/coordinators (Features/)
> - Mapa de backend: 63 migrations, 17 edge functions, 37 repositories
> - Vision canónica: `Plans/Active/Vision.md` (Group + Resource ontology)
> - DesignPrinciples: `docs/DesignPrinciples.md`
> - Audit previo: `docs/UXAudit.md` (2026-05-04, per-view)
>
> Fecha de este audit: 2026-05-17

---

## Resumen ejecutivo

**El backend está ~3× más maduro que la UI.** Hoy iOS expone ~30 % de
las capacidades del backend. Eso da margen — pero también significa que
la app se siente más estrecha de lo que realmente es. Los seis gaps que
más rompen la fluidez:

1. **El tab "Crear" es un agujero ontológico.** Hoy solo crea Event,
   Fund y Asset básicos. Slot, Space y Right están en el backend (RPCs
   + tablas) pero el wizard muestra "Próximamente". El usuario que
   activa el módulo `slot_assignment` o `common_fund` no tiene cómo
   ejercerlo desde la UI.

2. **No existe un Group Detail real.** `GroupHomeView` mezcla
   ajustes, miembros, módulos, moneda, timezone, roles, código de
   invitación, salir-del-grupo — todo en un solo scroll. No hay punto
   de entrada claro para "ver mi grupo".

3. **Reglas: leer ≠ crear ≠ editar.** Tres flujos distintos
   (`RulesView` read-only + `EditRulesView` admin + `RuleComposerView`
   free-form) con UX divergente y discoverability cero. El composer
   existe pero el usuario regular nunca lo encuentra.

4. **Inbox como sección embebida + Inbox como tab.** Hay dos UIs para
   lo mismo (top-3 en Home + full list en tab). La inconsistencia hace
   que el usuario no sepa dónde mirar.

5. **Apelaciones, votos genéricos, custom roles, archivado de grupos,
   regeneración de invite code, settlement de fondo — todos tienen
   RPC, ninguno tiene UI.** Son funciones que el founder ya pagó
   construir y nadie puede tocar.

6. **Empty states inconsistentes.** Home tiene 4 variantes
   módulo-aware (buenas). Inbox, Activity, Profile, MyFines — todos
   tienen empty states genéricos o ausentes.

**Veredicto:** la app es funcional y pasa el bar de DS en views
individuales. Pero como sistema, el journey tiene cortocircuitos cada
2-3 pantallas. Lo prioritario no es agregar features; es **cerrar los
loops abiertos** del backend en la UI y unificar los puntos de entrada.

---

## Metodología

Para cada journey:

1. **Trigger** — qué hace que el usuario entre a este flujo.
2. **Pasos** — paso a paso, con view exacta + tap/input.
3. **Estado actual** — qué funciona hoy.
4. **Gaps & fricción** — qué rompe el flujo (UX, capacidad, edge case).
5. **Mejoras** — qué cambiar para que fluya.

Al final hay un **Backlog priorizado** (P0/P1/P2) consolidando todas
las mejoras.

---

# Parte 1 — Onboarding & primera entrada

## Journey 0 — Primera instalación

**Trigger:** usuario instala la app desde TestFlight/App Store y la
abre por primera vez.

**Estado actual:**
- `TandasApp` → `AuthGate` → `BootstrappingView` (mientras `app.start()`)
- Sin sesión + nunca onboardeó → `SignInView(mode: .firstTime)`

**Gaps & fricción:**
- ❌ **No hay splash de marca.** El primer frame es un `ProgressView`
  centrado sobre `ruulBackground`. Eso es un loading state, no una
  bienvenida. Apple Invites, Luma, Sports — todas tienen una intro
  visual de 0.8-1.2 s con logo + motion sutil.
- ❌ **No hay onboarding "value-prop"** antes del sign-in. El usuario
  cae directo en "Sign In with Apple". No sabe qué es Ruul.
  Competencia (Splitwise, Luma) muestra 2-3 cards horizontales de
  "qué hace la app" antes del CTA.
- ❌ **No hay diferenciación entre `firstTime` y `returning`** más
  allá del copy del header. Las dos rutas son visualmente idénticas,
  cuando deberían sentirse distintas (la primera vez = más
  acogedora, la vuelta = más eficiente).

**Mejoras:**
- **P0** — Splash con logo Ruul + breath animation (1 s),
  honrar `Reduce Motion`.
- **P1** — En `firstTime` mode: 3 cards horizontales (paginables) ANTES
  del CTA de Apple Sign In: "Tu grupo en un lugar" / "Reglas que se
  aplican solas" / "Memoria que dura". Skip si ya vio (Keychain flag).
- **P2** — En `returning` mode: mostrar avatar + nombre del último
  usuario que firmó (si Keychain lo guardó), como Apple Music / Spotify.

---

## Journey 1 — Sign In / Sign Up

**Trigger:** usuario en `SignInView`.

**Pasos:**

```
SignInView
├── Apple Sign In (sheet nativa)
│   └── Success → AuthGate
├── Phone OTP
│   ├── Step 1: número (RuulPhoneField)
│   ├── Step 2: 6 dígitos (RuulOTPInput, auto-submit)
│   └── Success → AuthGate
└── "Crear nueva" (solo .returning)
    └── Limpia Keychain → flujo Founder
```

**Estado actual:**
- ✅ Apple Sign In funciona, OIDC + nonce.
- ✅ Phone OTP con auto-submit al completar 6 dígitos.
- ✅ Error states inline (rojo bajo el campo).
- ✅ Países detectados automáticamente.

**Gaps & fricción:**
- ❌ **No hay email OTP en la UI.** `AuthService` tiene
  `sendEmailOTP`/`verifyEmailOTP` pero no están expuestos. Un usuario
  sin Apple ID (Android-switcher, sin iCloud) + sin teléfono
  internacional confiable se queda atorado.
- ❌ **No hay "Continuar con Google".** Es un canal estándar en
  apps sociales latinoamericanas. Opcional, pero baja fricción.
- ❌ **No hay "¿No te llegó el código? Reenviar"** después de
  X segundos. Si el SMS se pierde, el usuario debe volver atrás
  manualmente.
- ❌ **No hay rate limit visible.** Si el backend bloquea por intentos,
  el usuario ve "No pudimos enviar el código" sin saber cuánto
  esperar.
- ❌ **No hay sign-out de Apple ID a nivel SO.** Si el usuario quiere
  cambiar de cuenta Apple, hay que decírselo (debe ir a Settings).
- ⚠️ **"Crear nueva" en `.returning` es ambiguo.** Suena a "crear
  nueva cuenta" pero realmente solo limpia flags de onboarding y
  fuerza el flujo de fundador. Un usuario que perdió acceso pensaría
  "perfecto, crear nueva cuenta" y terminaría borrando sus grupos
  existentes.

**Mejoras:**
- **P0** — Botón "Reenviar código" con countdown (30 s) en el step 2
  del OTP.
- **P0** — Renombrar "Crear nueva" → "Empezar grupo nuevo" o moverlo
  a un submenú (`...`) para que no compita con sign-in.
- **P1** — Exponer email OTP como tercera opción (debajo de phone),
  pequeño link "o usa email".
- **P1** — Rate-limit awareness: si el backend devuelve 429, parsear
  y mostrar "Intenta de nuevo en N minutos".
- **P2** — "Continuar con Google" via Supabase OAuth.

---

## Journey 2 — Onboarding del Fundador

**Trigger:** usuario autenticado, sin grupos, sin Keychain flag
`hasOnboarded`. O usuario tocó "Crear nueva".

**Pasos (7 vistas):**

```
WelcomeView → FounderIdentityView → GroupIdentityView →
PresetPickerView → ConsentRulesView → InviteMembersView →
ConfirmationView → RootShell
```

**Estado actual (post-refactor 2026-05):**
- ✅ Persistencia con SwiftData: si el usuario cierra la app a mitad
  del flujo, `OnboardingProgressManager` lo restaura al paso correcto.
- ✅ `WelcomeView` con mesh background — gold standard del DS.
- ✅ `PresetPickerView` ahora reemplaza el viejo `TemplateSelectorView`.
- ✅ `ConsentRulesView` reemplaza al viejo `InitialRulesView` +
  `GovernanceConfigView` — fundió 2 pantallas en 1.

**Gaps & fricción:**
- ❌ **No hay progress indicator.** El usuario no sabe si está en el
  paso 1/7 o 5/7. En un flujo de 7 pantallas eso es crítico para
  reducir abandono.
- ❌ **`GroupIdentityView` pide moneda + timezone del grupo separados
  del personal.** Para 99 % de los casos son iguales — debería
  pre-fill desde el perfil con un toggle "Usar otros para este grupo".
- ❌ **`ConsentRulesView` solo muestra las 5 reglas de
  DinnerRecurring.** Si el preset elegido en `PresetPickerView` es
  otro (cuando existan más), esta vista no se adapta. Hoy solo hay un
  template, pero el escalado fallará silenciosamente.
- ❌ **`InviteMembersView` no permite contactos del SO.** Pide
  email/teléfono manual. iOS tiene `ContactsUI` framework — debería
  abrir picker nativo.
- ❌ **`ConfirmationView` no muestra preview real.** Resume valores
  pero no muestra cómo se verá el primer evento. Sería un "wow
  moment" tener un mock del Home con datos del grupo.
- ❌ **No hay branch para "voy a unirme a un grupo, no a crear uno".**
  En el primer arranque, el founder flow se dispara automáticamente.
  Para unirse, el usuario debe terminar el flow vacío (sin invitar a
  nadie), llegar al RootShell y entonces tocar "Crear" → "Unirme".
  Eso es bizarro.

**Mejoras:**
- **P0** — Progress bar arriba con N/7 (igual que Apple Health onboarding).
- **P0** — Step 0 entre `WelcomeView` y `FounderIdentityView`: "¿Qué
  quieres hacer?" con dos cards grandes: "Crear un grupo nuevo" o
  "Unirme a uno existente". El segundo path es 2 pasos
  (identity + invite code), no 7.
- **P1** — `GroupIdentityView`: prefill moneda/timezone desde profile,
  collapse el bloque "Avanzado" por default.
- **P1** — `InviteMembersView`: integrar `ContactsUI` para picker
  nativo + invite-by-link (compartir URL con código preasignado).
- **P2** — `ConfirmationView` con preview real del Home.
- **P2** — Cuando haya >1 preset, `ConsentRulesView` debe leer reglas
  del preset elegido, no hardcodear DinnerRecurring.

---

## Journey 3 — Onboarding del Invitado

**Trigger:** usuario instala app después de tap en link de invitación
(deeplink `app.consumePendingInvite()`).

**Pasos (5 vistas):**

```
InviteWelcomeView → InvitedIdentityView → InvitedVerifyView →
InvitedOTPView → GroupTourOverlay → RootShell
```

**Estado actual:**
- ✅ Existe flujo separado, no fuerza al invitado por el flujo del fundador.
- ✅ `GroupTourOverlay` introduce el grupo al que se acaba de unir.

**Gaps & fricción:**
- ❌ **No se ve cuándo se dispara este flow vs. el founder flow.**
  Hoy `AuthGate` solo decide entre `OnboardingRootView` y `RootShell`
  basándose en `hasActiveOnboarding`/`isFirstTimeAuth`. Si hay invite
  code pendiente debe disparar `InvitedOnboardingCoordinator` en vez
  del `FounderOnboardingCoordinator`. Verificar que esto realmente
  pase — si no, el invitado entra al flow equivocado y termina creando
  un grupo nuevo en vez de unirse al original.
- ❌ **`GroupTourOverlay` solo aparece la primera vez.** Si el invitado
  cierra la app a mitad del tour, no vuelve. Debería re-mostrarse hasta
  completarse o ser dismissible explícitamente.
- ❌ **El invitado no ve quién lo invitó hasta que entra a la app.**
  Sería más cálido mostrar "Miguel te invitó a 'Cena de los Miércoles'"
  en `InviteWelcomeView`.

**Mejoras:**
- **P0** — Auditar el branching en `AuthGate`: confirmar que pending
  invite ⇒ invited flow.
- **P1** — `InviteWelcomeView` debe hidratar nombre del grupo + nombre
  del invitador desde el backend antes de auth (público para invite
  codes válidos).
- **P2** — `GroupTourOverlay` persistente hasta completar.

---

# Parte 2 — Day-to-day en el grupo

## Journey 4 — Llegar al RootShell por primera vez

**Trigger:** completar onboarding, o sign-in de usuario existente.

**Estado actual:**
- 5 tabs: Inicio, Inbox, Crear, Actividad, Perfil
- TabView iOS 26 con `tabBarMinimizeBehavior(.onScrollDown)` (Liquid Glass)
- HomeTab abre por default

**Gaps & fricción:**
- ❌ **La primera entrada cae directo en HomeView sin contexto.** Si el
  usuario acaba de crear un grupo sin eventos, ve el empty state
  "Crear evento". No hay un "Tour del primer Home" que explique los 5
  tabs (Inbox vs Actividad confunde).
- ❌ **El badge de Inbox cuenta TODAS las acciones cross-group** (Pass 1
  de la refactorización), pero el usuario en Home solo ve las del
  grupo activo. Si tiene 3 pendientes en otro grupo, el "3" en el badge
  no se explica desde el contenido visible.
- ⚠️ **Confusión Inbox vs Actividad.** Ambos son "cosas pasadas". La
  diferencia ontológica (Inbox = mías-pendientes, Actividad =
  historial-del-grupo) no se comunica en el tab label.
- ⚠️ **"Crear" tab no tiene contenido propio.** Si el usuario toca y
  cancela el sheet, vuelve a la tab anterior — pero el tab quedó
  visualmente "seleccionado" por un frame. Apple SDK no maneja bien
  intercepts de tab.

**Mejoras:**
- **P0** — Renombrar tabs: "Inbox" → "Pendientes", "Actividad" →
  "Historia" (más obvio que es del grupo, no mío).
- **P1** — First-launch tour overlay (3 dots + descripciones cortas)
  sobre los 5 tabs. Una sola vez, dismissible.
- **P1** — Badge del Inbox debe indicar visualmente si hay items
  fuera del grupo activo (chip pequeño "+2 en otros grupos" en el
  Home cuando aplique).
- **P2** — Migrar el "Crear" interceptado a un FAB flotante (no un
  tab). El tab fantasma rompe expectativas de iOS.

---

## Journey 5 — Home tab (día a día)

**Trigger:** abrir la app, ya autenticado, con grupo activo.

**Estado actual:**
- ✅ Sección "PENDIENTES" embebida (top 3 del InboxCoordinator).
- ✅ Sección "PRÓXIMO" con feed unificado event + resource.
- ✅ "MEMORIA DEL GRUPO" con stats (capped at 200).
- ✅ Empty state módulo-aware (4 variantes).
- ✅ Pull-to-refresh con 3 parallel tasks.
- ✅ Cache per-group con TTL 5 min.

**Gaps & fricción:**
- ❌ **El usuario ve PENDIENTES en Home y luego va al tab Inbox y ve
  los mismos.** Dos UIs para lo mismo. No queda claro cuál es la
  fuente de verdad. Debería ser una de dos cosas:
  - **Opción A:** Home tiene PENDIENTES → Inbox solo tiene resueltos
    + filtros avanzados.
  - **Opción B:** Home no tiene PENDIENTES, solo "PRÓXIMO" + memoria.
    Inbox queda como único acceso a pendientes.
- ❌ **El hero no existe.** El feed son rows compactos. UXAudit
  recomienda hero EventCard para "next event" (gold-standard
  pattern), pero el código actual usa rows incluso para el siguiente.
- ❌ **EventCard no muestra avatares de asistentes ni count.**
  UXAudit lo flaggea hace 13 días. Sigue sin batch-loader en
  HomeCoordinator.
- ❌ **"MEMORIA DEL GRUPO" se siente fría.** El cap a 200 evita
  inflar, pero "50 decisiones tomadas" sin un drill-down no genera
  curiosidad. Debería ser tappeable → abre Historia filtrada por
  tipo.
- ❌ **No hay quick actions sobre el evento próximo.** Hoy hay que
  tap → entrar a detail → RSVP. Apple Sports / Luma permiten RSVP
  inline desde el card.
- ⚠️ **Multi-group:** los chips de quick-switcher en el header son
  buenos pero al cambiar de grupo, todo recarga (skeleton 200 ms).
  El swap debería ser instantáneo desde el cache (ya existe el cache
  per-group, debe usarse aquí también).

**Mejoras:**
- **P0** — Resolver el solapamiento Home↔Inbox: decidir opción A o B
  y borrar la duplicación.
- **P0** — Restaurar el hero EventCard para el next event (UXAudit
  punto 1, sigue pending).
- **P0** — Batch-load attendee counts + avatares en HomeCoordinator.
- **P1** — "MEMORIA DEL GRUPO" tappeable: cada stat lleva a Historia
  con filtro pre-aplicado.
- **P1** — Inline RSVP en el hero card (3 botones segmentados sobre
  el cover, white text).
- **P2** — Group swap instantáneo desde snapshot cache (sin
  skeleton).

---

## Journey 6 — Inbox (Pendientes)

**Trigger:** tap tab Inbox, o tap en push notif.

**Estado actual:**
- ✅ Cross-group: lista todas las acciones pendientes del usuario.
- ✅ Swipe-to-resolve con repo call async.
- ✅ Realtime sync via `MultiDeviceChangeFeed`.
- ✅ "Marcar todas como resueltas".

**Gaps & fricción:**
- ❌ **No hay agrupación por prioridad.** Es una lista plana. Apple
  Mail usa "Urgentes / Esta semana / Después". Para multas a 24h vs.
  votos a 7 días, la prioridad importa.
- ❌ **`timeRemaining` no se computa.** El param existe en
  ActionCard pero nunca se setea. Para `appealVotePending` o
  `fineProposalReview` deberían mostrar "5h restantes".
- ❌ **El dispatcher de `handleInboxAction` es selectivo.** 5 tipos
  se enrutan (fine, appeal, rsvp, ruleChange, vote). Los demás son
  no-op silencioso. Si el backend emite `assetOverdue`,
  `slotSwapRequested`, `rightExpiringSoon` — el inbox los muestra
  pero el tap no hace nada.
- ❌ **No hay filtros.** Si el usuario está en 4 grupos con 30
  pendientes, no puede filtrar por tipo o por grupo desde la lista.
- ❌ **No hay "snooze".** Apple Mail/Linear lo tienen. En Ruul una
  apelación con 24h de plazo no debería poder snoozear (es un
  deadline real) — pero un recordatorio de evento sí podría.
- ❌ **"Resueltas" no muestra cuándo se resolvieron ni por quién
  (cross-device).** Útil saber "lo resolvió Jose desde otro dispositivo
  hace 10 min".

**Mejoras:**
- **P0** — Wire `timeRemaining` desde `expires_at` para los tipos
  con deadline. Es el dato más impactante para crear urgencia.
- **P0** — Auditar el dispatcher: para cada `actionType` en backend,
  o se enruta o no se emite. Hoy se emite y se ignora.
- **P1** — Agrupar por prioridad (Urgentes / Pendientes / Después)
  con headers tracked uppercase (DS pattern).
- **P1** — Filter chips arriba: "Todo / Grupo X / Multas / Votos".
- **P2** — Snooze para tipos no-deadline.
- **P2** — "Resueltas" con metadata cross-device.

---

## Journey 7 — Crear (tab interceptado)

**Trigger:** tap tab "Crear".

**Estado actual:**
- ✅ Si sin grupo activo: presenta `CreateGroupSheet`.
- ✅ Si con grupo: presenta `ResourceWizardSheet`.
- ✅ Wizard multi-paso: tipo → campos → opciones → reglas → review.
- ✅ Builders registrados: Event, Fund, Asset.
- ❌ Builders faltantes: Slot, Space, Right (muestran "Próximamente").

**Gaps & fricción:**
- ❌ **Build registry incompleto.** Vision.md congela 6 resource
  types (`event`, `fund`, `asset`, `space`, `slot`, `right`). El
  wizard solo soporta 3. Si el grupo activa el módulo
  `slot_assignment` o `common_fund`, no tiene cómo crear los
  recursos respectivos desde la UI.
- ❌ **El selector de tipo es genérico.** No se adapta a los
  módulos activos del grupo. Un grupo sin `basic_fines` no debería
  ver opciones que dependan de fines. Hoy las muestra todas.
- ❌ **"Reglas sugeridas" en step 4 son cuáles?** Si el usuario crea
  un evento, ¿qué reglas se sugieren? Las del template del grupo?
  Las del module activo? El código tiene un selector pero la lógica
  de qué se sugiere no es transparente para el usuario.
- ❌ **No hay creación rápida.** Para un grupo que crea 3 eventos
  por semana (cenas recurrentes), pasar por 5 pasos cada vez es
  demasiada fricción. Debería existir un "Repetir último evento"
  o un quick-create con defaults.
- ❌ **Review step no es accionable.** Solo "Crear" / "Atrás". Si
  el usuario nota un error en el step 2, tiene que tap "Atrás" 3
  veces — debería tap directo en la sección del review para editar
  esa sección.

**Mejoras:**
- **P0** — Stub los 3 builders faltantes (Slot, Space, Right) con
  el mínimo viable: tipo + nombre + fecha (si aplica). Backend ya
  tiene RPCs (`create_slot`, `create_space`, `create_right`).
- **P0** — Filtrar tipos de recurso según
  `activeGroup.effectiveActiveModules`. Sin `slot_assignment` →
  no mostrar slot.
- **P1** — Step 4 (reglas): mostrar qué template / módulo provee
  cada regla sugerida. "Esta regla viene del módulo Multas básicas."
- **P1** — Quick-create en Home: botón "Repetir último evento"
  cuando hay 1+ evento similar en los últimos 30 días.
- **P2** — Review step accionable (tap → edit section).
- **P2** — Recurrencia desde el wizard (hoy es post-creación).

---

## Journey 8 — Actividad (Historia del grupo)

**Trigger:** tap tab Actividad.

**Estado actual:**
- ✅ Paginated infinite scroll.
- ✅ Filter chips por tipo (Eventos / Multas / Reglas / Votos / Miembros).
- ✅ Pull-to-refresh.
- ✅ Resuelve actor names desde directory.

**Gaps & fricción:**
- ❌ **Filter UX inconsistente con el resto de la app.** Los filter
  chips no usan el patrón `FilterChip` del DS — son un toolbar
  button con sheet (UXAudit punto Historia).
- ❌ **No hay search.** En un grupo con 500 eventos en historia,
  buscar "el viaje a Vegas" requiere scroll.
- ❌ **Solo hay 5 tipos de filtro.** El backend emite ~30 tipos de
  SystemEvent. Eventos como `assetOverdue`, `fundThresholdReached`,
  `positionChanged` no tienen filter chip — caen en "Todos".
- ❌ **Tap en evento abre un `SystemEventDetailView` minimalista.**
  Para `eventCreated`, sería más útil abrir el evento mismo
  (`EventDetailView`). Para `fineOfficialized`, abrir la multa.
  Hoy te muestra un dump del payload JSON básicamente.
- ❌ **No hay export.** Compliance y memoria institucional son
  pilares de la Vision. Un admin debería poder exportar CSV/PDF
  del historial.
- ❌ **No se muestra actor avatar** — solo el nombre. Visualmente
  más pesado de escanear.

**Mejoras:**
- **P0** — Tap en event row debe abrir el recurso/multa/voto
  relacionado (deep link interno), no un detail genérico.
- **P0** — Add actor avatar (small circle leading).
- **P1** — Refactor filtros a `FilterChip` row arriba (pattern del DS).
- **P1** — Soporte para los 30+ tipos: agregar a chips o agrupar
  bajo "Más" expandible.
- **P2** — Search bar.
- **P2** — Export CSV/PDF (admin only).

---

## Journey 9 — Perfil (Yo)

**Trigger:** tap tab Perfil.

**Estado actual:**
- ✅ `MyProfileView` con avatar, nombre, email/phone, idioma,
  timezone, notif prefs, devices, "Mis multas" link, "Cerrar sesión".
- ✅ Cambio de phone con OTP flow.
- ✅ Cambio de email con verify flow.
- ✅ Picker de idioma + timezone.

**Gaps & fricción:**
- ❌ **No hay sección de "Mi historial cross-group".** Vision habla
  de memoria institucional. El usuario debería ver sus eventos
  asistidos, multas pagadas, votos emitidos — agregados across
  groups. `MyActivityRepository` existe en el backend.
- ❌ **No hay "Mis grupos" como sección de perfil.** Hoy el switcher
  está en el header del Home. Si un usuario tiene 8 grupos, el
  switcher se vuelve un pile horizontal — debería haber un "Ver
  todos" link al perfil.
- ❌ **Devices list no permite revocar individual.** El RPC existe
  pero la UI es read-only.
- ❌ **Notification preferences son lista plana sin grouping.** Para
  10+ tipos debería agruparse por dominio (Eventos / Multas / Votos /
  Miembros).
- ❌ **No hay "Eliminar mi cuenta".** Compliance: LFPDPPP (México)
  exige derecho ARCO; CCPA exige right to delete. La Vision lo
  marca como pendiente. Hoy NO existe en la UI.
- ❌ **No hay "Exportar mis datos".** Mismo paragraph LFPDPPP/CCPA.
- ⚠️ **"Cerrar sesión" botón rojo sin confirmation.** Apple HIG dice
  que destructive actions necesitan confirmación.

**Mejoras:**
- **P0** — Confirmation modal antes de cerrar sesión.
- **P0** — "Mis grupos" como sección con "Ver todos" link.
- **P1** — "Mi historia" sección cross-group (events + fines + votes
  del usuario).
- **P1** — Devices list: swipe-to-revoke per device.
- **P1** — Notification prefs agrupadas.
- **P0** (compliance) — "Eliminar mi cuenta" con flujo de
  confirmación. Backend debe soportar.
- **P1** (compliance) — "Exportar mis datos" → email con JSON/CSV.

---

# Parte 3 — Acciones sobre recursos

## Journey 10 — Detalle de evento + RSVP

**Trigger:** tap evento en Home / deep link / inbox action.

**Estado actual:**
- ✅ Full-screen cover.
- ✅ RSVP 4-state (Voy / Tal vez / No voy / Lista de espera).
- ✅ Attendees list grouped by status.
- ✅ Check-in button si live.
- ✅ Edit / Close para creator.
- ✅ EventLocationCard, EventRSVPStateView (UXAudit at-bar).

**Gaps & fricción:**
- ❌ **No hay calendario nativo.** `CalendarExportService` existe;
  no veo un botón "Agregar a Calendario" en EventDetail.
- ❌ **No hay Wallet pass.** `WalletPassGenerator` existe; no se usa
  en la UI.
- ❌ **No hay share.** Compartir evento por WhatsApp / mensaje sería
  el canal #1 de adopción.
- ❌ **No se muestra el "anfitrión" claramente.** Para grupos con
  rotación, saber quién hostea es central. Si el evento tiene
  `host_id`, debe estar destacado (avatar + "Anfitrión" badge).
- ❌ **Sin chat o thread.** Para coordinar antes del evento ("¿qué
  llevo?", "lluvia, posponemos?"), no hay canal. La Vision NO mete
  chat (no es competidor de Slack), pero un thread de comments por
  recurso sí encaja en `Documents` layer.
- ❌ **El estado "live" no es obvio.** Mientras pasa el evento, el
  detail debería tener un banner "EN VIVO" persistente arriba.
- ❌ **No se muestra "ya pasó" claramente.** Para eventos cerrados,
  el RSVP queda visible pero no hace nada — debería leerse "Asististe"
  / "No fuiste" con tono de cierre.

**Mejoras:**
- **P0** — Botones: "Agregar a Calendario" + "Wallet" + "Compartir"
  en toolbar / sheet de acciones.
- **P0** — Host badge prominente (avatar + "Anfitrión").
- **P1** — Estado live con banner sticky.
- **P1** — Estado past con cierre visual (RSVP → resultado).
- **P2** — Thread de comments por recurso (capability `documents`).

---

## Journey 11 — Check-in

**Trigger:** evento en vivo, usuario tappa "Check-in" o el host
escannea QR.

**Estado actual:**
- ✅ `CheckInScannerView` con QR scanner.
- ✅ `selfCheckIn`, `hostMarkCheckIn`, `qrScanCheckIn` en repo.

**Gaps & fricción:**
- ❌ **Sin UI claro para self-check-in (tap-to-arrive).** El RPC
  existe pero el botón en EventDetail no es obvio para el asistente
  regular — solo el host abre scanner.
- ❌ **QR del miembro no es discoverable.** `MemberQRSheet` existe
  pero no veo dónde se accede desde el perfil. El usuario debería
  tener su QR personal en su Perfil (igual a Apple Wallet).
- ❌ **No hay geofencing.** Backend tiene `Services/Location` y el
  evento tiene `location`. Hoy un usuario puede self-check-in desde
  su casa. Para un grupo con fines de no-show, eso es exploit.
- ❌ **No hay "I'm here" notificación al grupo.** Apple Find My-style:
  los demás ven en EventDetail que Jose llegó hace 5 min.

**Mejoras:**
- **P0** — Botón "Llegué" prominente en EventDetail cuando el
  evento está live. Self-check-in en un tap.
- **P0** — "Mi QR" en Perfil (sticker grande tipo Wallet).
- **P1** — Geofencing opcional: si el evento tiene location y el
  usuario está >500m, mostrar warning "Estás lejos del lugar.
  ¿Confirmar check-in?".
- **P2** — Live attendee list con timestamps (Find My-style).

---

## Journey 12 — Multas: ver, apelar, votar, pagar

**Trigger:** push notif "Te impusieron una multa" / inbox /
"Mis multas".

**Estado actual:**
- ✅ MyFinesView con pending / resolved sections.
- ✅ FineDetailView con status-aware actions.
- ✅ AppealFineSheet → crea Appeal row.
- ✅ VoteOnAppealSheet → cast ballot.
- ✅ AddManualFineSheet (admin) → propose fine.
- ✅ Pagar (mark as paid manualmente).

**Gaps & fricción:**
- ❌ **No hay diferenciación "todo al corriente" en hero.** UXAudit
  punto 8 sigue abierto: si `totalOutstanding == 0`, debe mostrar
  checkmark celebratorio.
- ❌ **Resolved usa mismo card que Pending.** UXAudit punto:
  resolved debería ser denser (row variant).
- ❌ **No hay filtros (este mes / todo / por grupo).** UXAudit punto.
- ❌ **No hay pago real.** El botón "Pagar" solo marca como
  paid — no integra Mercado Pago, CLABE, etc. Vision marca esto
  como deliberado (regulatorio), pero el UX debería ser claro:
  el botón debe decir "Marcar como pagada (fuera de Ruul)" en
  vez de "Pagar". Hoy es engañoso.
- ❌ **Appeal sheet no muestra cuántos miembros votarán ni el
  threshold.** "El grupo votará" es vago. Debería decir "Necesitan
  votar al menos 3 de 5 miembros. Anular requiere 60 %."
- ❌ **VoteOnAppealSheet no muestra el argumento de quien apela.**
  El usuario vota sobre la apelación sin ver el argumento. Hay
  que rescatarlo del payload.
- ❌ **No hay historial de apelaciones del grupo.** Como reference
  cultural ("la última vez se aprobó/se denegó").
- ❌ **No hay "ofrecer pagar por otro".** Caso común social: un
  miembro paga la multa de otro.
- ❌ **Officializar grace period (24h) no es visible.** El RPC
  `officialize_fine` corre por cron. El usuario que recibió una
  multa "propuesta" no sabe que tiene 24h para que el host la
  voide manualmente antes de que se vuelva oficial.

**Mejoras:**
- **P0** — Hero "todo al corriente" cuando outstanding == 0.
- **P0** — Renombrar botón "Pagar" → "Marcar como pagada" + tooltip
  "Ruul no procesa pagos por ahora. Coordina el pago por separado y
  márcalo aquí."
- **P0** — Mostrar argumento del apelante en VoteOnAppealSheet.
- **P0** — Mostrar grace period countdown en FineDetailView cuando
  status == proposed.
- **P1** — Hero, filtros, resolved-compact (UXAudit pending).
- **P1** — Mostrar threshold + count requerido en AppealSheet.
- **P2** — Pagar por otro (UX explícito).
- **P2** — Historial de apelaciones (drilldown).

---

## Journey 13 — Reglas: ver, editar, crear

**Trigger:** sección Reglas desde Group / push notif "Voto abierto"
/ inbox action.

**Estado actual:**
- ✅ RulesView read-only con stats header.
- ✅ EditRulesView (admin) con governance check.
- ✅ EditRuleSheet para modificar amount / toggle.
- ✅ RuleComposerView free-form (existe pero sin entry point claro).
- ✅ Vote auto-spawn si grupo policy requiere.

**Gaps & fricción:**
- ❌ **Tres flujos paralelos.** Ver / editar / crear son views
  separadas con UX divergente. Debería ser un solo flujo donde la
  capability se decide por permission.
- ❌ **El composer no tiene entry point obvio.** UXAudit no lo
  menciona — y yo tampoco lo encuentro en RulesView toolbar. Si
  el founder pagó construir un composer y nadie puede llegar a
  él, es deuda muerta.
- ❌ **Reglas read-only no muestran "WHEN/IF/THEN" en lenguaje
  natural.** Solo muestran nombre + descripción + amount. Para
  entender por qué se generó una multa, hay que conocer la regla
  internamente.
- ❌ **No hay "ver versions" history.** Backend tiene `rule_versions`
  (mig 00145). Útil saber "esta regla cambió de $100 a $200 el
  3 de marzo, aprobado por voto X".
- ❌ **Per-event rule scoping no expuesto.** Backend tiene
  `create_event_rule`. Caso de uso: "para ESTA cena en particular
  no aplica la multa de llegada tarde". No hay UI.
- ❌ **Rule shapes (canonicalized templates)** del backend (mig
  00229+) no se usan en el composer. El composer es free-form
  cuando podría ser guiado.
- ❌ **No hay botón "Aplicar a más recursos".** Si una regla se
  define para eventos, no hay UI para extenderla a slots o assets.
- ❌ **Validación de regla pre-publish no se ve.** `validate_condition_node`
  + `validate_consequence_target` existen; en UI el usuario no sabe
  si su regla es válida hasta que intenta publicar.

**Mejoras:**
- **P0** — Cada regla en `RulesView` muestra su WHEN/IF/THEN en
  lenguaje natural (`RuleSentenceFormatter` ya existe en
  Capabilities/).
- **P0** — Entry point al composer desde RulesView toolbar (si
  admin): "+" → "Nueva regla" → composer.
- **P1** — Rule history (versions) accesible desde rule detail.
- **P1** — Composer guiado por `list_rule_shapes` en vez de free-form.
- **P2** — Per-event rule override (botón "Excluir esta regla
  para este evento" en EventDetail).
- **P2** — Extender regla a múltiples resource types.

---

## Journey 14 — Votaciones

**Trigger:** push "Voto abierto" / inbox action / sección "Votos
abiertos" en Rules.

**Estado actual:**
- ✅ VoteDetailView con choices + counts + my vote.
- ✅ Cast ballot via VoteCastRepository.
- ✅ Auto-finalize cron (`finalize-votes` edge function).

**Gaps & fricción:**
- ❌ **Solo se usa `fine_appeal` vote type.** Backend soporta
  `rule_change`, `rule_repeal`, `member_removal`, `fund_withdrawal`,
  `role_assignment`, `general_proposal`, `slot_dispute`. Si un
  admin propone remover a un miembro o cambiar el fondo, no hay UI
  para iniciarlo.
- ❌ **Sin sheet de "Iniciar voto manualmente".** Vision habla de
  `general_proposal`. Necesita: título + descripción + opciones
  custom + duración + quorum + threshold.
- ❌ **Voto anónimo vs público no se diferencia.** Backend soporta
  `is_anonymous` flag. UI no lo expone.
- ❌ **No hay countdown.** Un voto cierra en 48h, debería verse
  "Cierra en 23h 14m".
- ❌ **Resultado no se animan.** Cuando un voto cierra, podría
  haber un mini-celebration ("Aprobado por 4 de 5 miembros")
  con haptics.
- ❌ **No hay link al objeto sobre el que se vota.** Si es
  `rule_change`, debería linkear a la regla. Si es `member_removal`,
  al perfil del miembro.

**Mejoras:**
- **P0** — UI para iniciar `general_proposal` desde Rules o
  Group Settings.
- **P0** — Countdown en VoteDetailView header.
- **P0** — Link al subject del voto (rule / member / fine / etc.).
- **P1** — Exponer voto anónimo toggle al iniciar.
- **P1** — Animación de resultado al cerrar.
- **P2** — UI para `member_removal`, `fund_withdrawal`, etc.

---

## Journey 15 — Miembros

**Trigger:** desde Group Settings → "Miembros".

**Estado actual:**
- ✅ MembersListView (read-only).
- ✅ MembersAdminView (admin only).
- ✅ MemberRolesPicker.
- ✅ Remove member con confirmation.
- ✅ Invite from group.

**Gaps & fricción:**
- ❌ **No hay perfil completo del miembro.** Tap en miembro debería
  abrir un sheet con: avatar grande, nombre, rol, % asistencia,
  multas pendientes/pagadas, votos emitidos, fecha de ingreso. Hoy
  abre un `MemberDetailView` minimalista.
- ❌ **Sin "expulsar"** distinto a "remover". Backend tiene
  `remove_member` con `reason`. Casos sociales: alguien dejó el
  grupo voluntariamente vs. fue expulsado por voto. Hoy el atom
  es el mismo (`memberLeft`).
- ❌ **No hay "promote/demote"** explícito. El rol founder es
  fijo; no se puede transferir. Para grupos donde el creador deja
  el grupo, el founder se quedaría como un usuario "fantasma".
- ❌ **Reorder de turn order** sería drag-to-reorder pero hoy
  solo `set_turn_order` RPC se llama tras edits. UI no clara.
- ❌ **No hay "compartir grupo" desde miembros tab.** Debería
  haber un FAB "Invitar más" siempre visible.

**Mejoras:**
- **P0** — MemberDetailView completo (stats + history).
- **P0** — FAB "Invitar" persistente.
- **P1** — Transferir founder via voto (member_removal vote type
  con special case).
- **P1** — Drag-to-reorder turn order (cuando rotating_host activo).
- **P2** — Diferencia "voluntario" vs "expulsado" en atoms.

---

## Journey 16 — Configuración de grupo

**Trigger:** tap gear en Home / desde switcher → "Ajustes".

**Estado actual:**
- ✅ `GroupHomeView` mezcla todo en un scroll: identity, modules,
  currency, timezone, custom roles, invite code, leave group.

**Gaps & fricción:**
- ❌ **Es un menú monolítico de 8+ secciones en un scroll.** No
  hay arquitectura. Apple Settings divide en secciones lógicas.
  Debería ser:
  - **Identidad** (nombre, descripción, cover, código)
  - **Personas** (miembros, roles, invitar)
  - **Reglas y módulos** (active modules, rule presets)
  - **Gobernanza** (voting thresholds, who-can-X)
  - **Ledger** (moneda, fondo)
  - **Zona** (timezone)
  - **Acciones peligrosas** (archivar, salir)
- ❌ **Archivar grupo no existe en UI.** Backend tiene
  `archive_group` + `unarchive_group`. Hoy un grupo abandonado
  queda visible siempre.
- ❌ **Regenerar invite code no expuesto.** RPC existe.
- ❌ **Custom roles UI es power-user.** `GroupRolesSheet` es
  exhaustivo (32 permissions) — pero la mayoría de los founders
  solo querrá "admin" / "member" / "treasurer". Necesita un modo
  "simple" (presets) + "avanzado" (granular).
- ❌ **Governance config (voting thresholds, quorum)** está
  enterrado en jsonb. No hay UI clara para editarlo.
- ❌ **Group avatar / cover no es claro qué se renderiza
  dónde.** Una sola imagen para todo es ambiguo.

**Mejoras:**
- **P0** — Refactor a secciones (~6) con List + NavigationLink
  (patrón Apple Settings).
- **P0** — Exponer Archivar grupo + Regenerar invite code.
- **P1** — Modo "Simple" para roles (presets de admin/treasurer/etc.)
  con expand a "Avanzado".
- **P1** — Governance UI dedicada con sliders (voting threshold,
  quorum) + previews.
- **P2** — Cover + avatar separados.

---

## Journey 17 — Cambiar de grupo

**Trigger:** tap chip de grupo en header de Home / Activity /
Inbox.

**Estado actual:**
- ✅ GroupSwitcherSheet con lista vertical.
- ✅ Active group marcado con checkmark.
- ✅ Cache per-group permite swap instantáneo (HomeCoordinator).

**Gaps & fricción:**
- ❌ **No muestra contadores de pendientes per grupo.** Si tengo 3
  grupos, ¿en cuál hay multa esperando? El switcher debería
  mostrar badges (igual a Slack/Discord).
- ❌ **Sin búsqueda.** Para alguien con 10+ grupos, scroll.
- ❌ **No hay "Pinned"** o reorder. Mi grupo principal vs. el de
  exalumnos.
- ❌ **"Crear nuevo grupo" no está en el switcher.** Debe ser una
  acción natural al estar viendo "mis grupos".

**Mejoras:**
- **P0** — Badge por grupo con count de pendientes.
- **P0** — Botón "Crear nuevo grupo" al final del switcher.
- **P1** — Reorder drag-and-drop + pinned grupo principal.
- **P2** — Search bar para 10+ grupos.

---

## Journey 18 — Salir / cerrar sesión / abandonar grupo

**Trigger:** acciones destructivas dispersas.

**Estado actual:**
- ✅ "Cerrar sesión" en Perfil (sin confirm).
- ✅ "Salir del grupo" en GroupHomeView (con confirm).
- ❌ No hay "Eliminar mi cuenta".

**Gaps & fricción:**
- ❌ Ya cubiertos arriba (Journey 9, 16).
- ❌ **Salir del grupo no explica qué pasa con tus multas pendientes
  ni con tu historia.** Spec: deberían quedar en el log
  (`memberLeft` atom) pero las multas pendientes... ¿se waivean?
  ¿siguen exigibles? El usuario no sabe.
- ❌ **No hay "transferir founder"** si soy el último.

**Mejoras:**
- **P0** — Confirmation modal explícito al salir del grupo:
  "Tienes 2 multas pendientes por $400. ¿Pagarlas antes de salir?"
  (link to MyFines filtered).
- **P0** — Si soy el último founder + único member: opción
  "Archivar grupo" (no leave); si hay otros members: forzar
  "Transferir founder a X antes de salir".

---

# Parte 4 — Cross-cutting

## Journey 19 — Recibir notificación push

**Trigger:** notif APNs llega.

**Estado actual:**
- ✅ `dispatch-notifications` edge function envía.
- ✅ Deep link parsing en `AppState.handleIncomingURL`.
- ✅ Algunos types se enrutan a la view correcta (event, fine, rule).

**Gaps & fricción:**
- ❌ **No todos los notification types están enrutados.** Si llega
  `assetOverdue` o `fundThresholdReached`, el deep link no tiene
  destino — la app abre en Home y deja al usuario perdido.
- ❌ **Notification preferences son por tipo, no por grupo.** Un
  founder podría querer "todo de Cena Miércoles" pero "solo multas
  de Roommates".
- ❌ **No hay sonido / criticality por tipo.** Una apelación con
  24h vs. un evento creado deberían usar canales distintos
  (`UNNotificationSound` custom).
- ❌ **No hay "Quiet Hours"** integration. iOS Focus respeta
  notifications, pero no veo lógica server-side para "no enviar entre
  11pm y 7am hora del usuario" — y el cron de
  `send-event-notification` no respeta timezones.

**Mejoras:**
- **P0** — Auditar coverage: para cada notification type emitido por
  backend, asegurar handler en `RootRouter`/`AppState`.
- **P1** — Notification prefs por grupo + por tipo (matriz).
- **P2** — Custom sounds por criticality.
- **P2** — Quiet hours respect.

---

## Journey 20 — Deep links (URL externa, share)

**Trigger:** alguien comparte URL `ruul://invite/CODE` o
`ruul://event/UUID`.

**Estado actual:**
- ✅ `EventDeepLink`, `RuleChangeDeepLink` resolver.
- ✅ `pendingInviteCode` en `AppState`.
- ✅ Universal Links (asumido por `app.handleIncomingURL`).

**Gaps & fricción:**
- ❌ **No veo `ResourceDeepLink` genérico.** Para slot, fund, asset,
  right — cómo se comparten?
- ❌ **Universal Links setup no auditable desde el doc.** Apple App
  Site Association (AASA) file en el dominio?
- ❌ **Web fallback ausente.** Si alguien tap link sin tener la app,
  debería caer en landing que diga "Instala Ruul" + invite preserved.

**Mejoras:**
- **P0** — `ResourceDeepLink` genérico que cubra los 6 tipos.
- **P1** — Landing web con preserve-invite (deferred deep link).
- **P2** — Auditoría AASA + universal links coverage.

---

# Parte 5 — Empty states & error states (cross-cutting)

**Estado actual:**
- ✅ `EmptyStateView`, `LoadingStateView`, `ErrorStateView` primitives.
- ✅ Home empty state es módulo-aware (4 variantes, gold standard).
- ⚠️ Resto de empty states inconsistentes.

**Gaps:**
- ❌ Inbox empty: "Sin pendientes" — OK, pero podría celebrar
  ("¡Al corriente! 🎉" estilo Luma).
- ❌ Activity empty: no recuerdo si existe. Si un grupo nuevo no
  tiene SystemEvents, qué se muestra?
- ❌ Profile empty (sin multas, sin grupos): no claro.
- ❌ Error states usan mensaje crudo del repo. Para network error,
  un usuario regular ve "URLError(.notConnectedToInternet)" en vez
  de "Sin conexión. Reintenta cuando estés online."

**Mejoras:**
- **P0** — Auditoría empty/error en cada tab + cada list. Aplicar
  primitives consistentemente. Friendly copy para network errors.

---

# Parte 6 — Accessibility (cross-cutting)

UXAudit ya identificó esto. Para que el journey "fluya perfecto" para
TODO usuario:

- ❌ **VoiceOver pass** pendiente en views custom (group switcher
  chips, action cards, rule sentences).
- ❌ **Dynamic Type pruebas a xxxLarge** pendientes.
- ❌ **Reduce Motion** parcial.
- ❌ **High Contrast** no auditado.
- ❌ **No hay localization más allá de es-MX.** Vision sugiere
  EN-US como segunda lengua para GTM USA.

**Mejoras:**
- **P0** — VoiceOver pass full app.
- **P0** — Dynamic Type pass full app.
- **P1** — EN-US localization base.
- **P1** — Reduce Motion audit completo.
- **P2** — High Contrast theme verify.

---

# Parte 7 — Backlog priorizado

## P0 — Bloqueadores de fluidez (ship antes de Beta amplia)

### Onboarding & Auth
- [ ] Splash de marca (1 s breathing logo) en `BootstrappingView`.
- [ ] Step 0 en Onboarding: "¿Crear o unirse?" para no forzar founder flow.
- [ ] Progress bar N/7 en onboarding del founder.
- [ ] "Reenviar código" con countdown 30 s en OTP step 2.
- [ ] Renombrar "Crear nueva" → "Empezar grupo nuevo" para evitar confusión.
- [ ] Auditar branching invitado-vs-fundador en `AuthGate`.

### Shell & Navegación
- [ ] Renombrar tabs: "Inbox" → "Pendientes", "Actividad" → "Historia".
- [ ] Resolver Home↔Inbox duplicación (decidir A o B).
- [ ] Tap en Activity row debe abrir el recurso, no `SystemEventDetailView` genérico.

### Crear (tab)
- [ ] Stub builders para Slot, Space, Right (mínimo viable).
- [ ] Filtrar tipos de resource según `activeGroup.effectiveActiveModules`.

### Home
- [ ] Restaurar hero EventCard para next event (UXAudit pendiente 13 días).
- [ ] Batch-load attendee counts + avatares en HomeCoordinator.

### Inbox
- [ ] Compute & display `timeRemaining` para `appealVotePending` /
  `fineProposalReview`.
- [ ] Audit dispatcher: cada `actionType` o se enruta o no se emite.

### Multas
- [ ] Hero "Todo al corriente" cuando outstanding == 0.
- [ ] Renombrar botón "Pagar" → "Marcar como pagada" + tooltip explicativo.
- [ ] Mostrar argumento del apelante en VoteOnAppealSheet.
- [ ] Countdown del grace period (24h) en FineDetailView status=proposed.

### Reglas
- [ ] Mostrar WHEN/IF/THEN en lenguaje natural en RulesView
  (`RuleSentenceFormatter` ya existe).
- [ ] Entry point al composer desde RulesView toolbar (si admin).

### Votos
- [ ] Countdown del cierre del voto.
- [ ] Link al subject (regla/miembro/multa) desde VoteDetail.
- [ ] UI para iniciar `general_proposal` (Group Settings → Iniciar voto).

### Miembros
- [ ] MemberDetailView completo (stats + history).
- [ ] FAB "Invitar" persistente.

### Group Settings
- [ ] Refactor de `GroupHomeView` a ~6 secciones (Apple Settings pattern).
- [ ] Exponer Archivar grupo + Regenerar invite code.

### Group Switcher
- [ ] Badge per grupo con count de pendientes.
- [ ] Botón "Crear nuevo grupo" al final del switcher.

### Perfil & Cuenta
- [ ] Confirmation modal antes de cerrar sesión.
- [ ] "Mis grupos" como sección en Perfil con "Ver todos".
- [ ] (Compliance) "Eliminar mi cuenta" — LFPDPPP/CCPA requirement.

### Salir del grupo
- [ ] Confirmation rico al salir: mostrar multas pendientes + forzar
  transferir founder si soy último.

### Deep Links & Push
- [ ] `ResourceDeepLink` genérico para 6 resource types.
- [ ] Auditar coverage de notification types → handlers.

### Empty/Error/Accessibility
- [ ] Auditoría empty/error en cada tab. Friendly copy.
- [ ] VoiceOver pass full app.
- [ ] Dynamic Type pass full app.

---

## P1 — Pulido importante (post-Beta 1)

### Auth
- [ ] Email OTP como tercera opción.
- [ ] Rate limit awareness en errores 429.

### Onboarding
- [ ] `GroupIdentityView` prefill moneda/timezone desde profile.
- [ ] `InviteMembersView` con `ContactsUI` + invite-by-link.
- [ ] `InviteWelcomeView` hidrata nombre del grupo + invitador antes de auth.

### Home
- [ ] "MEMORIA DEL GRUPO" tappeable (drilldown a Historia filtrada).
- [ ] Inline RSVP en hero card.

### Inbox
- [ ] Agrupar por prioridad (Urgentes / Pendientes / Después).
- [ ] Filter chips arriba.

### Crear
- [ ] Step 4 explica de dónde vienen las reglas sugeridas.
- [ ] Quick-create "Repetir último evento" en Home.

### Actividad
- [ ] Refactor filtros a `FilterChip` row (DS pattern).
- [ ] Soporte para 30+ system event types.
- [ ] Actor avatar leading.

### Perfil
- [ ] "Mi historia" cross-group section.
- [ ] Devices swipe-to-revoke per device.
- [ ] Notification prefs agrupadas + por grupo.
- [ ] (Compliance) "Exportar mis datos".

### Eventos
- [ ] Agregar a Calendario + Wallet + Compartir en EventDetail toolbar.
- [ ] Host badge prominente.
- [ ] Estado live con banner sticky.
- [ ] Estado past con RSVP→resultado.

### Check-in
- [ ] Self-check-in tap-to-arrive button en EventDetail live.
- [ ] "Mi QR" en Perfil.
- [ ] Geofencing opcional con warning.

### Multas
- [ ] Hero, filtros, resolved-compact (UXAudit pending).
- [ ] Threshold + count requerido visible en AppealSheet.

### Reglas
- [ ] Rule history (versions) accesible.
- [ ] Composer guiado por `list_rule_shapes`.

### Votos
- [ ] Exponer voto anónimo toggle.
- [ ] Animación de resultado al cerrar.

### Miembros
- [ ] Transferir founder via vote.
- [ ] Drag-to-reorder turn order (rotating_host).

### Group Settings
- [ ] Modo "Simple" para roles con presets + expand a "Avanzado".
- [ ] Governance UI dedicada con sliders.

### Group Switcher
- [ ] Reorder + pinned.

### Push
- [ ] Notification prefs por grupo + por tipo.

### Localization
- [ ] EN-US base.

### Reduce Motion
- [ ] Audit completo.

---

## P2 — Polish / nice-to-have

- [ ] 3 value-prop cards pre-sign-in (firstTime).
- [ ] Sign in with Google.
- [ ] Avatar del último usuario en `.returning` sign-in.
- [ ] `ConfirmationView` con preview del Home.
- [ ] Migrar "Crear" interceptado a FAB (en vez de tab).
- [ ] Group swap instantáneo sin skeleton.
- [ ] Snooze para inbox items no-deadline.
- [ ] Resolved metadata cross-device en Inbox.
- [ ] Review step accionable en Wizard.
- [ ] Recurrencia desde el wizard.
- [ ] Search en Activity.
- [ ] Export CSV/PDF de Activity (admin).
- [ ] Thread de comments por recurso.
- [ ] Live attendee timestamps (Find My).
- [ ] Pagar multa por otro.
- [ ] Historial de apelaciones.
- [ ] Per-event rule override.
- [ ] Custom notification sounds.
- [ ] Quiet hours respect.
- [ ] Landing web con deferred deep link.
- [ ] Cover + avatar separados en grupo.
- [ ] High Contrast theme.

---

## Parte 8 — Capacidades del backend NO expuestas en UI

(Resumen del agente de backend mapping. Si está aquí es que el RPC
existe y nada en iOS lo invoca o lo expone.)

### Resources (Phase 2+)
- `create_slot`, `assign_slot`, `book_slot`, `request_slot_swap`
- `create_space`
- `create_asset`, `assign_custody`, `release_custody`,
  `check_out_asset`, `check_in_asset`, `transfer_asset`,
  `report_damage`, `record_valuation`, `complete_maintenance`,
  `record_asset_usage`
- `create_right`, `transfer_right`, `delegate_right`, `exercise_right`,
  `revoke_right`, `suspend_right`, `restore_right`,
  `update_right_metadata`

### Fund / Ledger
- `create_fund` (parcial: básico existe), `fund_contribute`,
  `fund_record_expense`, `fund_lock`, `fund_unlock`
- `record_settlement`
- `ledger_review_apply_resolution`

### Governance / Roles
- `upsert_group_role`, `delete_group_role` (existe pero UI compleja)
- `has_permission` (granularidad 32 perms, UI solo expone ~3)
- `archive_group`, `unarchive_group`
- `regenerate_invite_code`
- `remove_member` (parcial)

### Votes (tipos extra)
- `start_vote` con `rule_change`, `rule_repeal`, `member_removal`,
  `fund_withdrawal`, `role_assignment`, `general_proposal`,
  `slot_dispute`
- Voto anónimo (`is_anonymous` flag)

### Rules
- `publish_rule_composition` (composer existe pero entry oculto)
- `create_event_rule` (per-event scoping)
- `list_rule_templates`, `list_rule_shapes`
- `rule_versions` history

### Notifications
- `set_notification_preference` (parcial)
- Per-group preferences

### Compliance
- LFPDPPP/CCPA: "Eliminar mi cuenta", "Exportar mis datos" — ambos
  pending.

---

## Cierre

La app tiene una base técnica excepcional y un DS al bar en views
individuales. El problema no es de calidad — es de **continuidad**.
El usuario que entra a Ruul no recorre un río; recorre un río
con cataratas inesperadas cada 3 pantallas.

**Si solo se hacen los P0 listados arriba (~30 items, ~3 sprints),
la app pasa de "demo funcional" a "producto que fluye".** Los P1 y
P2 son lo que la convierte en gold-standard Apple-quality, pero los
P0 son lo que evita que el usuario abandone en la cena #2.

**Recomendación de orden:**
1. **Sprint 1 (Shell & Onboarding)** — splash, progress bar, step 0
   "crear o unirse", rename tabs, salir-del-grupo confirmation rico.
2. **Sprint 2 (Crear & Recursos)** — stub Slot/Space/Right builders,
   filter por modules, resource deep link genérico.
3. **Sprint 3 (Multas & Votos)** — grace countdown, todo-al-corriente
   hero, vote countdown + subject link, general_proposal UI.
4. **Sprint 4 (Group Settings & Compliance)** — refactor settings a
   secciones, archive/regenerate code UI, eliminar cuenta, exportar
   datos.
5. **Sprint 5 (Polish & A11y)** — VoiceOver, Dynamic Type, empty/error
   audit, EN-US base.

Después: P1 y P2 en backlog rolling.
