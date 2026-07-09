# Ruul — Auditoría y Optimización para Lanzamiento "Grupos de Amigos"

**Fecha:** 2026-06-21 · **Estado:** plan vivo · **Owner:** founder
**Doctrina:** Ruul como app de amigos arriba; infraestructura social abajo.
**Meta:** un grupo nuevo crea grupo + invita + agenda + gasto en **< 5 min**.

## Estado 2026-07-08 (verificado contra código)

**Los 8 P0 del §3 están shipped**, más el noveno acordado con la contra-auditoría:

| Slice | Commit | Contenido |
|---|---|---|
| Slice 0 + P0 #5/#6/#7 | `aeb8ba4` | Terminology sweep (50+ leaks) · switcher multi-grupo · game variants picker · quick contribute swipe · QuickStart → RulePresetLibrarySheet |
| Slice A (P0 #2) | `06b3ece` | Seed rules automáticas al crear grupos de amigos (mig `r14_seed_friend_group_rules`) |
| Slice A (P0 #3+#4) | `db419ea` | Home aggregates: chip de botes + actividad reciente cross-grupos (mig `r14_b`) |
| Slice B (P0 #1) | `44ed89c` | Reputación consolidada en backend: `list_context_members_with_reputation` 1 RPC (mig `r14_c`) |
| P1 #2 + #6 | `fccc7ee` | Filtro de eventos técnicos en Activity + "Liquidar ahora" directo desde obligación |
| **R.14.D** (Hall of Shame → P0 acordado) | `cf9978f` | **Reputación opt-out por grupo**: toggle "Mostrar reputación" en Ajustes → Miembros (gate `context.manage`), slot `members_config.show_reputation` en `update_context`/`context_settings_summary`, y la RPC de reputación devuelve `[]` con el flag apagado — iOS oculta leaderboards/badges/detalle sin lógica extra (mig `r14_d`) |
| **R.14.E** (CI honesto) | este commit | **edge-tests verde otra vez** — llevaba rojo desde 2026-06-16. 3 causas raíz: (1) r12_f dejó un overload ambiguo de `update_calendar_event` (8 vs 9 params) → DROP del legacy; (2) las seed rules R.14 contaminan smokes que assertan multas/conteos exactos → opt-out explícito `r14_skip_seed_rules` en 10 smokes (los que fijan su propio mundo de reglas); (3) R.RES.POLICY (granularity=day, min 1 día en casas) invalidó reservas de prueba de 2-12 horas → ventanas de 1 día. Suite completa 75/75 verificada localmente con replay de la cadena entera (mig `r14_e`) |

**Pendiente para lanzar:** Slice D — founder smoke iPhone JJ (10 flows §10; requiere
device, incluye ahora "apagar reputación desde Ajustes → desaparecen rankings").
**Post-launch (§11):** trip↔pool · host inicial · guest split · external payout ·
AI parser · cron observability — sin cambios de prioridad.

## R.15 — App viva (2026-07-08, founder: "Home no conectado + sheets muertas")

Auditoría de conectividad en 4 frentes (Home, botes en eventos, sheets
informativas, tabs). Shipped en este slice:

| Fix | Detalle |
|---|---|
| Aportar a bote POR OTRO miembro | mig `r14_f`: `contribute_to_pool(p_contributor_actor_id)` gate `money.settle` + membership + no-asset. iOS: `ContributorPickerSection` ("A nombre de") en `ContributePoolSheet` y `QuickContributeSheet`. Validado funcional (3 asserts) + 75/75 smokes |
| Home: tap muerto en cold-launch | `HomeView.task` carga `contextStore` (antes `resolveContext` era nil y el tap de grupo no hacía nada) |
| Home: QuickStart directo | "Invitar amigos" → `InviteMembersView` del grupo (antes: tab Ajustes) · "Crear reunión" → `CreateEventView` scopeada · "Registrar gasto" → `RecordExpenseView` scopeada (antes: CreateIntentSheet genérico) |
| Home: chips accionables | chip pendientes → lista de atención · chip 💰 botes → Dinero del grupo (`jumpToContextMoney` nuevo) · swipe "Dinero" en filas de grupo |
| Crear evento → detalle | `EventsListView` pasa `onCreated` y empuja `EventDetailView` (consistente con el "+" global) |
| ActivityDetail deja de ser dead-end | sección "Ver relacionado" navega a gasto/evento/votación/recurso (patrón `subjectDestination` de MyActivityFeed) |

## R.16 — Post-launch P1 completo (2026-07-08, founder: "has todas tus recomendaciones")

| Feature | Detalle |
|---|---|
| **Pago externo** (P1 #8) | mig `r16_a`: `mark_obligation_paid_external(channel, note, client_id)` — solo el acreedor atestigua; settled + transaction `payment` + splits (ledger R.9.D) + compat con neteo R.2N (cierra el settlement_item 1:1 vivo); idempotente; acción `mark_paid_external` en `obligation_available_actions` (F.2X). iOS: sheet canal (Efectivo/Transferencia/Venmo/Otro) + nota en ObligationDetail vía availableActions. Validado: 3 asserts (deudor rechazado / settled+ledger / idempotencia) + 75/75 smokes |
| **Viaje ↔ bote** (P1 #4) | mig `r16_b`: `list_context_pools` expone `metadata`. iOS: `CreatePoolInput.metadata`, ficha de viaje muestra "Bote del viaje" ligado (metadata.source_event_id) o CTA crear pre-llenado; badge "De este evento" en la sección de botes del evento |
| **Invitados en split** (P1 #6) | Backend R.9.C ya ponderaba guests (deuda al anfitrión) — el gap era presentacional: el editor de reparto muestra +1s e invitados por nombre bajo su anfitrión, con copy honesta |
| **Host inicial** (P1 #5) | Backend ya soportaba `p_host_actor_id` — picker "¿Quién organiza?" en CreateEventView (default Tú, incluye placeholders) |
| **AI parser NL→evento** (P1 #7) | `EventDraftParserService` + `@Generable EventDraft` (calca EventSuggestionService); input de una línea en CreateEventView que pre-llena título/fecha/lugar/virtual; degradación limpia sin modelo on-device |
| Diferido | Cron observability (P1 #9): requiere edge function + alertas Sentry — infra fuera del repo; sigue sprint 4 |

**R.15.B (2026-07-08, mismo día)** — el backlog de abajo se ejecutó COMPLETO
en 6 slices paralelos (commits R.15.B 1-6/6), con 3 excepciones honestas:
(a) "Ver lo generado" en WhyDecisionResult requiere backend — `why_decision_result`
no expone IDs tipados de lo ejecutado (falta algo como `executed_targets[]`);
(b) Aprobar/Confirmar en MyReservationsView — la vista filtra por `isMine` y el
modelo no expone al aprobador: gatearlo en cliente violaría F.2X;
(c) preseleccionar fecha al crear evento desde el calendario — el init de
CreateEventView no acepta fecha (mejora menor futura).

**Backlog ejecutado en R.15.B** (file:line verificados 2026-07-08):

- P1 · Reserva ligada a evento sin Aprobar/Confirmar inline (`EventDetailLinkedReservationsSection.swift:13`; RPCs ya existen)
- P1 · `MyReservationsView` sin CTA aprobar/cancelar (`MyReservationsView.swift:42-48`)
- P1 · Heros "N eventos"/"N miembros" con glass interactivo pero sin tap (`EventsListView.swift:114-147`, `MembersListView.swift:140-169`)
- P1 · MoneyHome sección "Detalles" inerte; "Deudas abiertas (N)" no navega (`MoneyHomeView.swift:619-657`)
- P2 · `EventDetailNextSessionSection` "Organiza X" sin cambiar anfitrión inline (`:9`; `NextHostPickerSheet` ya existe en toolbar)
- P2 · `EventDetailTripSection` sin "Registrar gasto del viaje" (`:4`)
- P2 · `WhyObligationSheet`/`WhyDecisionResult` nombran la fuente sin navegar a ella (`ObligationDetailView.swift:514`, `DecisionDetailView.swift:1130`; puede requerir sourceId en RPC)
- P2 · Empty state de eventos en grupo hace hop extra (`ContextDetailV2OverviewBlocks.swift:26-32`) · "Día libre" sin CTA (`MyCalendarView.swift:183-195`) · fila de reservación no tappable (`MyCalendarView.swift:239-248`)
- P2 · AttentionDispatcher: scopes `reservation`/`settlement_item`/`pool` de rule_attention_items caen a "Próximamente" (`AttentionDispatcher.swift:104-126`); ramas `.decision/.obligation/...` sin fallback de contexto (`:234-249`)
- P2 · Hero de Dinero contradice tesorería para admins sin deuda propia (`MoneyHomeView.swift:202-211` vs `:331-345`)

---

## 0 · Resumen Ejecutivo

### Lo que YA shipped y aguanta lanzamiento (no tocar)

- **Navegación 5 tabs** Inicio · Eventos · Dinero · Miembros · Ajustes
  (MainTabShell.swift:32-130). Cero "Crear" tab — sheet centralizada desde "+".
- **Terminología despejada**: 0 hits de "Context"/"Pool"/"Governance"/"Capability"
  user-facing. `Bote` (post `da030db6`), `Liquidaciones`, `Recursos`, `Espacios`.
- **Onboarding low-friction**: CreateContext 2 pasos · InviteMembers 3 vías (1-tap
  share link + contactos picker + buscar en Ruul) · JoinByCode pega+entra.
  `NoContextsView.swift:38` copy correcto.
- **QuickStart checklist** en Home (HomeView.swift:204-255): 4 pasos auto-trackeados.
- **MoneyHome** Hero "¿debo / me deben?" PROMINENTE arriba con color semántico
  (MoneyHomeView.swift:191-326). Botón "Ver cómo liquidar" directo.
- **Split modes** equal/shares/custom en RecordExpense (RecordExpenseView.swift:79-84,
  325-363). Default "Yo pagué por todos" en 1 tap.
- **Settlement handshake 2 vías** con reject/appeal flow + razón obligatoria
  (SettlementView.swift:105-136).
- **Pools/Botes R.8 completo**: schema + RPCs + resolution (winner_takes_all +
  equity_target). CreatePool 3 policies. PoolDetail preview shipped.
- **Eventos**: recurrence weekly/monthly · host rotation drag-reorder
  (HostRotationOrderSheet.swift) · check-in con geofence soft 200m
  (EventDetailPrimaryActionSection.swift:113-140) · auto-close cron R.6.C 30min.
- **Reglas**: 4 presets `relaxedDinner`/`organizedDinner`/`competitiveGroup`/`travelers`
  (RulesListView.swift:345-487) + 5 wizard templates (CreateRuleWizard.swift:40-68).
- **Reputación cliente-side**: MemberReputationBuilder computa 9 métricas +
  leaderboards Hall of Fame/Shame (MembersListView.swift:248-264).
- **IA**: RuulAIHeroView genérico en 7 features de creación, FoundationModels
  on-device, ActivitySummaryService en MeView.
- **Backend**: R.6 motor de reglas + R.7 governance + R.8 botes shipped. Auto-multas
  vía R.6.B trigger AFTER INSERT activity_events. Auto-cierre eventos vía
  pg_cron R.6.C cada 30min.

### Top 6 gaps P0 para lanzamiento

0. **Terminology sweep** (corregido post contra-audit) — 50+ leaks de
   "Espacio/Gobierno/Derechos/Trust" en surfaces user-facing. Ver §1.2 lista
   exhaustiva. Sweep de strings + activity catalog labels.
1. **Reputation backend ZERO** — todo cliente-side; no escala a "miles de grupos
   activos". MemberReputationBuilder hace 3-4 RPC calls concurrentes por miembro
   (MemberReputation.swift:98-101). 8 miembros × 4 RPC = 32 calls al abrir Members.
2. **Seed rules de fábrica faltan** — cada grupo nuevo arranca con 0 reglas. Los 4
   presets requieren tap manual. Friction: nuevo founder no sabe que existen.
3. **Home no muestra dinero en botes ni actividad reciente cross-context** —
   responde 5/10 casos canónicos. Faltan "¿cuánto hay en mis botes?" + "qué pasó".
4. **Game variants hardcoded a `game_debt`** (RecordGameResultView.swift:113) — sin
   quiniela/mundial/fantasy/poker. Cualquier juego no-trivial sale del flow.
5. **Quick contribute a bote desde lista no existe** (PoolsListView.swift:76-82) —
   forzar push al detalle rompe el "1-tap aporto $100".

### Decisión clave para founder

Tres rutas (ver §11 Roadmap):

- **A · Ship ahora, gaps en sprint 1 post-launch** (recomendado). El producto está
  90% listo; los gaps no rompen la promesa "< 5 min organizar cena con multas".
- **B · 1 sprint pre-launch** cubre P0 1-5. ~2 semanas.
- **C · Refactor reputación a backend antes de lanzar**. ~3-4 semanas. Sobre-ingeniería.

---

## 1 · Auditoría UX (frontend iOS)

### 1.1 Navegación — ✅ READY

- 5 tabs: Inicio · Eventos · Dinero · Miembros · Ajustes (MainTabShell.swift:32-130).
- Sin tab "Crear" — "+" sheet contextual (CreateIntentSheet).
- ContextDetailV2 colapsa avanzadas (Gobierno · Subespacios · Documentos · Invitaciones
  activas) en DisclosureGroup "Más" al final (ContextDetailV2Tabs.swift:283-291).
- MeView con 5 filas primarias + DisclosureGroup "Más" (memoria UX.SIMPLIFY.2).

**Mapeo contra los 10 casos canónicos de amigos:**

| Caso | Surfaced en | Estado |
|---|---|---|
| Próximo evento | Home cards + ContextHome | ✅ |
| RSVP | Implícito en "pendientes" del card | 🟡 indirecto |
| ¿Cuánto debo? | Home card "deuda" si < 0 + MoneyHome Hero | ✅ |
| ¿Cuánto me deben? | Home card "saldo a favor" + MoneyHome Hero | ✅ |
| Dinero en botes | Sólo en MoneyHome tab interno del grupo | ⚠️ **no en Home global** |
| Liquidar saldos | MoneyHome Hero → SettlementView | ✅ |
| Aportar a bote | PoolDetailView (requiere 2 taps desde lista) | 🟡 |
| Organizar viaje | Evento type `.trip` + EventDetailTripSection | ✅ (sin pool linkage) |
| Votaciones | DecisionsListView (escondido en "Más") | ✅ |
| Reglas | RulesListView (escondido en "Más") | ✅ |
| Actividad reciente | Sólo MyActivityFeedView (tab Actividad fue absorbido) | ⚠️ **no en Home** |

### 1.2 Terminología — ⚠️ LEAKS REALES (corregido post contra-auditoría 2026-06-21)

**Mi primer agente hizo un grep superficial.** La contra-auditoría tenía razón:
"Espacio · Gobierno · Derechos · Trust · Recurso · Decisión" siguen visibles en
50+ surfaces. "Pool"/"Context"/"Capability"/"Ownership" sí están limpios.

**Hits user-facing por concepto:**

`"Espacio[s]"` — debe ser **"Grupo"**:
- MeView.swift:420 — sección "Espacios"
- MySubscriptionsView.swift:86 — chip tipo `.context: return "Espacio"`
- PersonalSettingsView.swift:396,398 — section "Espacio" / "Espacio inicial"
- ContextDetailV2Toolbar.swift:113 — "Espacios hijos"
- ContextDetailV2OverviewBlocks.swift:225-227 — "Espacio creado/actualizado/archivado"
- ContextDetailV2OverviewBlocks.swift:263 — chip subject "Espacio"
- ContextDetailV2Header.swift:97 — fallback "Espacio"

`"Gobierno"` — debe ser **"Administración"** o **"Reglas"** según contexto:
- ContextSettingsView.swift:283 — section
- ContextDetailV2Toolbar.swift:108 — toolbar label
- ContextDetailV2OverviewBlocks.swift:267 — kind label

`"Derechos"` — debe ser **"Permisos"** o **"Quién puede usarlo"**:
- ResourceSettingsView.swift:211 — section
- ResourceDetailV2Actions.swift:82 — bucket "rights"

`"Trust"` — debe ser **"Fideicomiso"** o esconder hasta que se necesite:
- CreateContextView.swift:37 — label
- ContextTreeView.swift:144 — label
- ContextsListView.swift:505 — label
- CreateChildContextSheet.swift:40 — label

`"Recurso[s]"` — debate: el contra-audit pide **"Cosas"**. Mi recomendación es
**"Recurso"** sigue siendo aceptable para amigos cuando se refiere a casa/lancha/
boletos. Pero validar con founder. ≥18 hits:
- ResourcesListView.swift:43,428 — titles
- ResourceDetailViewV2.swift:95,421 — title/preview
- Documents/Reservations/Profile fallback "Recurso" como string default
- ContextDetailV2OverviewBlocks.swift:192-194,251 — activity descriptions
- ContextDetailV2Tabs.swift:189 — section header

`"Decisión[es]"` — el contra-audit lo flagea como jerga; recomienda **"Votación"**.
Mi recomendación: mantener "Votación" como sustantivo de UI, pero "Decisión"
en activity log es histórico. ≥6 hits:
- DecisionsListView.swift:277 — preview
- ResourceDetailV2Linked.swift:197 — "Decisiones relacionadas"
- MySubscriptionsView.swift:82 — chip
- ContextDetailV2OverviewBlocks.swift:174-177,253 — activity events
- ContextDetailViewV2.swift:298 — Label "Decisiones"

**Pool · Context · Governance · Capability · Ownership · Right: 0 hits**
user-facing (estos sí migrados).

**Veredicto corregido:** sweep de terminología es **P0**, no opcional.

### 1.3 Onboarding — ✅ ~3 minutos demostrables

1. **Crear grupo** — CreateContextView 2 pasos (nombre + template).
2. **Invitar** — 3 vías:
   - Share link 1-tap (InviteMembersView.swift:139-173) ✅
   - Contactos picker auto-add (líneas 376-388) ✅
   - Buscar en Ruul (líneas 290-315) ✅
3. **Crear evento** — CreateEventView con AI Hero (líneas 549-617).
4. **Reglas** — RulePresetLibrarySheet (RulesListView.swift:275-343) 1-tap aplica.
5. **Primer gasto** — RecordExpenseView default "Yo pagué" + equal split.

**Gap**: la presencia de los presets de reglas NO es discoverable desde QuickStart
(HomeView:204-255). El paso 3 "Elegir reglas" lleva a RulesListView vacío y el
usuario debe saber que existe el botón "Biblioteca". CTA explícito faltante.

### 1.4 Discoverabilidad — ✅ Avanzadas escondidas

ContextDetailV2: secciones primarias (Eventos · Personas · Recursos · Dinero ·
Actividad) siempre visibles. Avanzadas (Gobierno · Subespacios · Documentos)
detrás de DisclosureGroup. Doctrina respetada.

### 1.5 IA — ✅ Robusta, sin parser natural

7 features con AI Hero (Decision · Event · Obligation · Reservation · Resource ·
Rule). FoundationModels on-device con graceful degradation. NO existe parser
"Cena viernes 8pm" → evento estructurado. Hoy el flow es: AI sugiere campos
pre-poblados, el usuario edita inline. Suficiente para MVP.

### 1.6 Hallazgos menores P2 (visuales)

- ObligationDetailView.swift:275 — "Ir a Dinero para liquidar" muestra hint en
  lugar de botón directo. Friction de 1 tap extra.
- ActivityFeedView.swift sin filtro de ruido system-events (verbose para "qué
  pasó esta semana").

---

## 2 · Auditoría Backend

### 2.1 Lo que aguanta

- **R.8 Pools completo**: schema + 4 RPCs core + resolution (winner_takes_all +
  equity_target) + governance gate (`pool.resolve` policy override).
- **R.7 Governance completo**: catalog 12 acciones, request/execute, policy PULL,
  PUSH supported via execution_rpc. 4 RPCs canónicas (membership/transfer/archive_rule/
  forgive_obligation).
- **R.6 Rule Engine completo**: trigger AFTER INSERT activity_events auto-dispatcha
  evaluación, sin tocar cada RPC. Idempotency sha1 + sink `emit_attention`. Cron-tick
  detectors para obligation.overdue · document.expiring · reservation.starting_soon ·
  right.expiring (R.6.C). Auto-cierre eventos vencidos 30min cron (R.6.C).
- **Eventos**: recurrence DAILY/WEEKLY/MONTHLY/YEARLY, host_rotation_order uuid[],
  event_guests para no-miembros, participant.status full lifecycle.
- **Auto-multas pipeline**: `_emit_activity` → trigger → rule eval → `obligations`
  insert con `obligation_type='fine'`. Funciona end-to-end.

### 2.2 Gaps reales

**P0 — Reputación 0% backend.**
- Sin tablas, sin RPCs, sin views. iOS computa client-side (MemberReputation.swift:235-248).
- Implicaciones a escala: 8 miembros × 4 RPC calls al abrir Members = 32 round-trips.
  Multiplicar por "miles de grupos activos diario" = no escala.
- Doctrina founder-signed dice "backend = autoridad" → reputación violando doctrina.

**P0 — Seed rules para grupos nuevos.**
- Migration `r6_f_seed_two_demo_rules.sql` sólo seed para Palco/Familia Mizrahi.
- Cada grupo nuevo arranca con 0 reglas. Los 4 presets en iOS son plantillas
  client-side, NO se aplican automático al crear contexto.
- Para "grupos de amigos" la promesa "multas automáticas" requiere que el grupo
  tenga reglas. Sin seed por defecto, founder debe elegir preset manualmente.

**P1 — Game variants.**
- `record_game_result` hardcoded a `game_debt`. No catalog de tipos
  (poker/quiniela/mundial/fantasy/dominó).
- Workaround actual: `record_expense` o `record_fine` manual. Pierde semántica.

**P1 — Trip ↔ Pool linkage.**
- `calendar_events.metadata.trip` existe (jsonb), pero no hay FK ni helper
  `pool_for_trip(event_id)`. Founder debe linkearlos manualmente.

**P1 — Reservation policies y external payouts.**
- `mark_settlement_paid` requiere counterpart Ruul user. Sin path "le pagué a
  Pedro por Venmo y él no está en Ruul" — sólo via `forgive_obligation`.

**P2 — Cron monitoring.**
- pg_cron jobs (R.6.C close events + obligation_overdue + 3 detectores) sin
  observabilidad si fallan. Vendor risk Supabase.

### 2.3 Lo que NO está roto (no tocar)

- Índices verificados: activity_events(context,event_type,created_at) ·
  obligations(context,status) · pool_accounts(parent,status) ·
  pool_basis(pool_account_id,created_at desc) · memberships(context,status).
- Terminología técnica en backend ↔ humana en cliente: separación clara,
  activity_event_catalog tiene descripciones humanizadas para display.

---

## 3 · Gaps críticos P0

| # | Gap | Surface | Solución mínima |
|---|---|---|---|
| 0 | Terminology sweep | 50+ file:line en §1.2 | Diccionario de reemplazo + sweep. Espacio→Grupo · Gobierno→Administración · Derechos→Permisos · Trust→Fideicomiso (o esconder) · validar Recurso/Decisión con founder. Incluir activity_event_catalog labels. |
| 1 | Reputation backend | MemberReputation.swift:98 → 4 RPCs | View `v_member_reputation` server-side con 9 métricas materialized. Reduce a 1 RPC `list_context_members_with_reputation(ctx)`. |
| 2 | Seed rules nuevos grupos | `create_context` RPC | Al crear contexto template `friend_group`, seed 2 reglas: `late_15min → fine $30` + `same_day_cancel → fine $50`. Opt-out toggle. |
| 3 | Home "dinero en botes" | HomeView.swift:318-341 | Card "Tus grupos" suma `pool_accounts.balance` por contexto + mostrar chip "💰 $X en botes". |
| 4 | Home actividad reciente | HomeView | Agregar `recentSection` con últimos 5 activity_events cross-context. Backend ya tiene `attention_inbox`; ampliar con `list_recent_activity(limit:5)`. |
| 5 | Game variants | RecordGameResultView.swift:6 | Picker game_type: poker · quiniela · mundial · fantasy · domino · billar · otro. Backend `record_game_result(p_game_type)`. |
| 6 | Quick contribute desde lista | PoolsListView.swift:76 | Swipe action o stepper inline "Aportar $X" sin push. |
| 7 | RuleLibrary CTA en QuickStart | HomeView.swift:204-255 | Paso 3 "Elegir reglas" abre directo `RulePresetLibrarySheet`, no `RulesListView` vacío. |

---

## 4 · Mejoras recomendadas P1

| Área | Mejora | Esfuerzo |
|---|---|---|
| Reputation privacy | Opt-out por grupo + opt-out personal (memoria visible solo al miembro) | iOS small |
| Activity feed filter | Toggle "ocultar técnicas" (rule.evaluated, system.*) | iOS small |
| Trip ↔ Pool | `create_pool_for_event(event_id, policy)` RPC + UI linker en TripSection | backend + iOS med |
| Host inicial al crear | Field opcional en CreateEventView "Esta vez organiza X" | iOS small |
| Guest split | RecordExpense incluir `event_guests` en split eligible | backend + iOS med |
| Obligation "Pagar" directo | Reemplazar hint por button con sheet de modos pago | iOS small |
| AI parser natural language | "Cena viernes 8pm casa Pedro" → evento estructurado | iOS large (FoundationModels schema gen) |
| External payout marker | `mark_obligation_paid_external(obligation_id, channel)` (Venmo/cash/transferencia) | backend + iOS med |
| Cron observability | Edge function `cron_heartbeat` + Sentry alert si gap > 2h | infra med |

---

## 5 · Features a ocultar (no eliminar)

Para lanzamiento amigos, esconder hasta que el grupo lo pida:

| Feature | Ubicación actual | Acción |
|---|---|---|
| Trust Edges / Red de confianza | MeView "Más" | ✅ ya escondido |
| ResourceRights / Capabilities | ContextSettings | ✅ ya en DisclosureGroup |
| Governance/Decisions tab | ContextDetailV2Tabs (visible en "Más") | ✅ ya escondido en "Más" |
| Documentos | ContextDetailV2Tabs ("Más") | ✅ ya escondido |
| Subespacios | ContextDetailV2Tabs ("Más") | ✅ ya escondido |
| Decisions complejas (governance_mode) | CreateDecision DisclosureGroup "Avanzado" | ✅ UX.SIMPLIFY.8 |
| Reservation policies override | ResourceSettingsView | ✅ ya en submenu |
| Decision Templates avanzados | DecisionDetailView "Más" | ✅ UX.SIMPLIFY.4 |
| Member capabilities chips | CreateContext (removed) | ✅ removido |

**Conclusión:** la disciplina de esconder ya está aplicada en 8 de 9 superficies.
No hay sweep adicional necesario.

---

## 6 · Nuevo mapa de navegación

**Ya implementado. No requiere cambios.**

```
TAB BAR (root)
├─ Inicio (HomeView)           ← Quick wins cross-grupos
├─ Eventos (MyCalendarView)    ← Mi calendario personal
├─ Dinero (MoneyHomeView)      ← Mi balance + liquidar
├─ Miembros (no shipping)      ← N/A: dentro de cada grupo
└─ Yo (MeView)                 ← Profile + ajustes

GRUPO (push desde ContextsListView)
└─ ContextDetailV2
   ├─ Tabs: Resumen · Eventos · Personas · Recursos · Dinero · Actividad
   └─ "Más": Gobierno · Subespacios · Documentos · Reglas · Invitaciones · Ajustes
```

**Único ajuste recomendado en §3 P0 #3-#4:** Home debe mostrar dinero en botes
+ actividad reciente cross-grupos.

---

## 7 · Onboarding < 5 minutos

**Spec actual (medido):**

| Paso | Surface | Tiempo |
|---|---|---|
| 0 | SignedOutView → phone OTP | 30s |
| 1 | EnsurePersonActor (auto) | 1s |
| 2 | NoContextsView CTA "Crear mi primer grupo" | 2s |
| 3 | CreateContextView (nombre + template "Grupo de amigos") | 30s |
| 4 | QuickStart paso 1 "Invitar" → ShareLink | 30s |
| 5 | QuickStart paso 2 "Crear próxima reunión" → AI Hero | 60s |
| 6 | QuickStart paso 3 "Elegir reglas" → RulePresetLibrary (relaxed/organized) | 30s |
| 7 | QuickStart paso 4 "Primer gasto" → RecordExpense | 60s |
| **Total** | | **~4 min** |

**Mejoras para bajar a 3 min:**

- Seed reglas auto al crear (P0 #2) → ahorra paso 6 (~30s).
- AI parser natural en evento → si "cena vie 8 casa pedro" se acepta directo,
  evento en ~20s en lugar de 60s.

---

## 8 · Sistema de Reputación

### Estado actual (cliente-side)

Métricas computadas en MemberReputation.swift:213-248:

- Asistencia % = `attendedEvents / (attended + cancelled + missed)`
- Eventos organizados
- Compromisos completados
- Obligaciones abiertas/liquidadas (money)
- Multas abiertas
- Tardanzas, faltas
- Actividad reciente
- **Score 0-100** ponderado · **ShamePoints** ponderado

### Spec backend recomendada (P0 #1)

**Tablas:**

```sql
-- Materialized view refreshed nightly + on critical writes
CREATE MATERIALIZED VIEW v_member_reputation AS
SELECT
  m.context_actor_id,
  m.actor_id,
  -- 9 métricas pre-computadas
  COUNT(ep.id) FILTER (WHERE ep.status='attended') AS attended_events,
  COUNT(ep.id) FILTER (WHERE ep.status='no_show')  AS missed_events,
  COUNT(ep.id) FILTER (WHERE ep.status='late')     AS late_events,
  COUNT(ep.id) FILTER (WHERE ep.role='host')       AS hosted_events,
  COUNT(o.id)  FILTER (WHERE o.status='open' AND o.obligation_type='fine') AS open_fines,
  COUNT(o.id)  FILTER (WHERE o.status='open' AND o.metadata->>'money_kind' IS NOT NULL) AS open_money,
  COUNT(o.id)  FILTER (WHERE o.status='settled') AS settled_money,
  COUNT(ae.id) FILTER (WHERE ae.created_at > now() - interval '14 days') AS recent_activity,
  -- Score derivado en SQL para ser estable cross-cliente
  ruul.compute_reputation_score(...) AS score,
  now() AS computed_at
FROM actor_memberships m
LEFT JOIN event_participants ep ON ep.actor_id = m.actor_id ...
GROUP BY m.context_actor_id, m.actor_id;

CREATE INDEX ON v_member_reputation (context_actor_id, score DESC);

-- RPC consolidada
CREATE FUNCTION list_context_members_with_reputation(p_context_id uuid)
RETURNS TABLE (...) ...
```

**Refresh strategy:** `REFRESH MATERIALIZED VIEW CONCURRENTLY` desde cron 1x/hora +
trigger on `_emit_activity` para event_participants/obligations changes (debounced).

**Privacy:**

- `actor_memberships.reputation_visibility ENUM('group','self','hidden')` default `group`.
- Si `hidden`, hideout en `list_context_members_with_reputation` (excepto al propio
  actor).
- Toggle en MemberDetailView y CreateContext.

**Leaderboards:** mismo materialized view ordenado por score DESC (Hall of Fame)
y por shame_points DESC (Hall of Shame). Top 3 cada uno. Opt-out per grupo en
ContextSettings.

---

## 9 · Biblioteca de Reglas

**Actual (4 presets en iOS, sin seed backend):**

- `relaxedDinner` — solo norm "Llegar a tiempo"
- `organizedDinner` — late_15min fine + same_day_cancel fine + norm
- `competitiveGroup` — late_10min + cancel_tarde_150 + norm con puntos
- `travelers` — cancel_reserva_<48h + 2 norms (fondo, gastos)

**Spec ampliada (P0 #2 — seed automático al crear contexto):**

```
Template "Grupo de amigos" → seed 2 reglas opt-out al crear:
  1. late_15min_30mxn (organizedDinner DNA)
  2. same_day_cancel_50mxn (organizedDinner DNA)

Template "Familia" → seed 0 reglas (relaxedDinner DNA).

Template "Viaje" → seed 1 regla:
  1. cancel_reservation_<48h_100mxn
```

**Library UI mejorada:**

- Renombrar "Elegir reglas" en QuickStart a "Cómo funciona nuestro grupo".
- En RulePresetLibrarySheet añadir nota "Las reglas se aplican automáticamente al
  cerrar eventos. Puedes editarlas o quitarlas cuando quieras."
- Templates futuros (post-launch): `Apostadores` · `Compañeros de casa` ·
  `Grupo de gym` · `Equipo deportivo`.

---

## 10 · Roadmap de lanzamiento

### Slice 0 — Terminology sweep (2 días, P0 #0)

Sweep mecánico de los 50+ leaks (§1.2). Diccionario:

| Antes | Después | Excepción |
|---|---|---|
| Espacio / Espacios | Grupo / Grupos | activity events legacy ok |
| Espacio inicial | Grupo inicial | |
| Espacios hijos | Subgrupos | |
| Gobierno | Administración | |
| Derechos | Permisos | |
| Trust | Fideicomiso | esconder si subtype=trust no surface |
| Recurso / Recursos | (founder decide) | candidato "Cosas" o mantener |
| Decisión / Decisiones | Votación / Votaciones | activity log legacy ok |

Archivos a editar (lista canónica): MeView.swift · MySubscriptionsView.swift ·
PersonalSettingsView.swift · ContextDetailV2Toolbar.swift · V2OverviewBlocks.swift
· V2Header.swift · ContextSettingsView.swift · ResourceSettingsView.swift ·
ResourceDetailV2Actions.swift · CreateContextView.swift · ContextTreeView.swift ·
ContextsListView.swift · CreateChildContextSheet.swift · DecisionsListView.swift
· ResourceDetailV2Linked.swift · ContextDetailViewV2.swift.

Smoke: search post-cambio que ningún Picker/Section/Label legacy sobreviva.

### Slice A — Seed rules + nav polish (3 días, P0 #2 + #3 + #4 + #7)

- Migration `r14_seed_rules_friend_groups.sql`: trigger AFTER INSERT en
  `actor_contexts` cuando `template_key='friend_group'` seed 2 reglas + opt-out
  metadata flag.
- HomeView: agregar `recentSection` cross-context (limit 5) + chip "💰 botes" en
  card de grupo.
- QuickStart paso 3 abre `RulePresetLibrarySheet` directo si no hay reglas.

### Slice B — Reputation backend MVP (5 días, P0 #1)

- Migration `r14_member_reputation_view.sql`: materialized view + RPC consolidada.
- iOS: MemberReputationBuilder cambia a 1 RPC en lugar de 4. Mantener formula
  client-side como fallback si RPC <iOS 26 deployment.
- Privacy toggle (P1) deferred sprint 2.

### Slice C — Game variants + quick contribute (2 días, P0 #5 + #6)

- Backend `record_game_result(p_game_type text DEFAULT 'game_debt')`. Catalog:
  poker · quiniela · mundial · fantasy · domino · billar · otro.
- PoolsListView swipe-action "Aportar $X" → inline ContributeStepper sheet.

### Slice D — Founder smoke iPhone JJ (1 día)

10 flows founder-signed:
1. Crear "Cena Semanal Jueves" → seed rules aparecen ✅
2. Invitar 3 amigos via ShareLink ✅
3. Crear evento "Cena vie 8pm casa Pedro" ✅
4. RSVP + check-in geofence ✅
5. Registrar gasto $1200 split equal ✅
6. Settlement → "Pedro me debe $400" → confirmar pago ✅
7. Crear bote "Viaje Vallarta" equity_target $5000 ✅
8. Aportar $500 desde lista (swipe) ✅
9. Registrar partida poker → Mizrahi gana $200 a Sasson ✅
10. Cerrar evento → R.6.B genera fine no-show $30 a Pedro ✅

**Total: ~13 días al lanzamiento (2 sweep + 3 nav + 5 reputation + 2 game/contribute + 1 smoke).**

---

## 11 · Roadmap post-lanzamiento

| Sprint | Foco | Slices |
|---|---|---|
| 1 (sem 1-2) | Reputation privacy + activity filter + obligation pay direct | P1 #1-3 |
| 2 (sem 3-4) | Trip ↔ Pool linkage + host inicial + guest split | P1 #4-6 |
| 3 (sem 5-6) | External payout marker + AI parser natural language v1 | P1 #7-8 |
| 4 (sem 7-8) | Cron observability + index hardening + scale tests | P1 #9 + infra |
| 5+ | Pool policies adicionales (proportional/equal_share/rotational) + member capabilities surface | R.8.G+ |

---

## 12 · Casos de uso extremos

- **Grupo de 50 miembros (familia extendida)** — MembersListView con 50 cards +
  reputación client-side = 50×4 RPC = 200 calls. Slice B mitiga.
- **100 eventos en 1 año** — ActivityFeedView sin paginación, OOM riesgo. Verificar
  paginación en ActivityStore (`list_activity(limit:50)` existe pero no infinite-scroll).
- **Bote con 30 contribuidores** — `pool_account_detail` retorna todas las basis
  entries. OK con índice `idx_pool_basis_pool` pero UI rendering puede ser lento.
  Considerar limit + "Ver todas".
- **Pago a Pedro vía Venmo** — sin path nativo. Hoy founder usa `forgive_obligation`.
  Slice 3 sprint 3 cierra.

---

## 13 · Casos borde

- **Miembro sale después de aportar a bote** — `actor_memberships.removed_at` set;
  `pool_basis_entries` permanecen. Al `resolve_pool`, ¿incluir o excluir? Backend
  hoy NO filtra. Verificar comportamiento esperado.
- **Evento cancelado con RSVP confirmados** — `cancel_event` RPC existe; ¿genera
  fine de no-show? Hoy NO (status pasa a `cancelled`, no `no_show`). Correcto.
- **Reset de seed rules** — si founder borra las 2 seed rules y crea otro grupo,
  no se re-seedean. Decisión: ¿persistir flag `seeded_at` por contexto? Sí.
- **Host rotation con miembro removido** — `host_rotation_order uuid[]` queda
  con UUID stale. NextHostPickerSheet debe filtrar. Verificar.
- **Bote winner_takes_all sin contribuciones** — resolve con 0 basis: ¿error o
  no-op? Backend devuelve `errcode='22023'` ("no pool basis to resolve"). UI debe
  manejar.

---

## 14 · Riesgos técnicos

| Riesgo | Severidad | Mitigación |
|---|---|---|
| Reputation client-side no escala | Alta | Slice B pre-launch |
| pg_cron sin monitoring | Media | Sprint 4 P1 #9 |
| Materialized view refresh lag | Media | Trigger on critical writes + debounce 30s |
| FoundationModels indisponible iOS 26 device viejo | Baja | Graceful degradation ya implementado |
| Apple rejection por geofence sin justificación | Baja | LocationProximityService es foreground-only, opt-in tap |
| Activity_events index bloat (1M+ rows) | Media long-term | Partitioning by created_at month post 6 meses |

## 15 · Riesgos de producto

| Riesgo | Severidad | Mitigación |
|---|---|---|
| Founder de grupo no aplica reglas → no hay multas → percepción "no hace nada" | Alta | Slice A seed rules opt-out |
| Hall of Shame ofende → grupos abandonan | Media | Opt-out per grupo P1 #1 |
| Splitwise replacement → users esperan paridad feature (currencies, foreign FX, OCR receipt) | Media | Roadmap públicamente diferenciar: Ruul ≠ Splitwise, Ruul = organización completa |
| Confusion "espacio" vs "grupo" | Baja | Memoria UX.SIMPLIFY unificación shipped |
| Geofence falso positivo (check-in remoto) | Baja | Threshold 200m + tap manual obligatorio |

---

## 16 · Recomendaciones WWDC26 / SwiftUI / IA / escalabilidad

### SwiftUI moderno

- **Migración pendiente a iOS 26 Liquid Glass real** — toolbar pinned glass · sheet
  con .presentationBackground · ContextDetailV2Header con BlurEffect dinámico. Hoy
  `glass`/`bar`/`thin` ya en uso, validar consistencia.
- **`.navigationTransition(.zoom)`** para Resource/Event/Pool detail push (iOS 26)
  para sentido de profundidad nativo.
- **`@Observable` ya adoptado** en stores. Auditar que no haya `@StateObject` legacy.
- **`Tag()` macros** para tab bar en lugar de manual int rawValues si MainTabShell
  tiene legacy.

### IA — siguientes pasos

- **AI parser natural language → evento** (sprint 3): definir `@Generable struct EventDraft`
  con title/startsAt/locationText/recurrence/hostHint. Single FoundationModels call.
- **Auto-categorize gasto** desde descripción ("Uber" → categoria transporte).
- **Sugerir regla** cuando R.6.B detecta patrón "Pedro siempre llega tarde" — sink
  futuro de `_emit_attention` kind `rule_suggestion`.

### Escalabilidad backend

- Particionar `activity_events` por mes pasado los 6 meses (alta cardinalidad).
- Considerar Supabase Realtime para Home cards en lugar de polling (memoria reportes
  no menciona realtime — vale auditar).
- Edge function `nightly_reputation_refresh` para materialized view sin pg_cron.
- Sentry breadcrumbs ya integrado (`Sentry` en deps) — validar que RPCErrorMapper
  emita ctx útil.

### Observabilidad

- KPIs de lanzamiento: D1 retention, % grupos con > 1 evento creado en 24h,
  % grupos con > 1 gasto en 7d, % settlement handshake completados.
- Tablero Supabase + edge function `kpi_snapshot_daily`.

---

## Anexo · Glosario backend ↔ usuario

| Backend | UI |
|---|---|
| context_actor | grupo / espacio |
| pool_account | bote |
| obligation (money) | gasto / deuda |
| obligation (fine) | multa |
| obligation (commitment) | compromiso |
| settlement_batch | liquidación |
| calendar_event | evento / reunión |
| event_participant | asistente |
| rule | regla |
| decision | votación |
| resource | cosa / recurso |
| capability | qué se puede hacer |
| actor_membership | miembro |

Sin leakage actual (verificado en §1.2).

---

## Cierre

El producto está **~85% listo** (revisado a la baja post contra-auditoría).
La navegación nueva (Inicio · Eventos · Dinero · Miembros · Ajustes) y el
diccionario "Bote/Liquidaciones" ya están shipped (commit `a5df9ec7`), pero el
sweep de terminología quedó incompleto: 50+ leaks de Espacio/Gobierno/Derechos/
Trust siguen visibles.

**Alineación con contra-auditoría 2026-06-21:**

| Punto | Mi primera audit | Contra-audit | Verificado |
|---|---|---|---|
| Nav 5 tabs nueva | ✅ shipped | ❌ "todavía Home/Espacios/Crear/Actividad/Yo" | ✅ ya shipped (MainTabShell.swift:33-84) |
| Terminology limpia | ✅ "0 hits" | ❌ "Espacio/Gobierno/Derechos/Trust siguen visibles" | ✅ contra-audit RIGHT — 50+ leaks |
| CreateContext 4 templates | OK | "todavía ofrece Familia/Viaje/Comunidad/Proyecto/Negocio/Trust" | parcial — enum tiene 7, UI expone 4 con default friendGroup |
| Reputation backend zero | ✅ flagged P0 | ✅ flagged P0 | ✅ agree |
| Auto-multas verificadas | ✅ R.6.B trigger shipped | ⚠️ "falta verificar idempotencia" | ✅ idempotency sha1 verificada en R.6.A |
| Trip experience completa | 🟡 sección existe | ❌ "no es experiencia completa" | ✅ agree — falta pool linkage |
| Reputation server-materialized | ⚠️ recomendado | ✅ recomendado | ✅ agree |
| Hall of Shame opt-in | ✅ P1 #1 | ✅ "riesgo social real" | ✅ agree, subir a P0 |

**Las dos auditorías convergen en el roadmap.** Diferencia: la contra-auditoría
pide rediseñar la shell pero esa parte ya está en main. El gap real es el
terminology sweep y los gaps funcionales (reputación, seed rules, home agregados,
game variants, viajes integrados).

**Decisión founder pedida**:
- **Ruta A** · Ship ahora — el sweep de terminología puede ser hotfix post-launch.
  Riesgo: founder de grupo nuevo ve "Gobierno" en toolbar y le da raro.
- **Ruta B** · Slice 0+A+B+C pre-launch (~13 días). Recomendada. La doctrina
  founder-signed "lenguaje humano arriba, sistema abajo" no se cumple sin el sweep.

Si B, próximo paso: Slice 0 · grep+edit mecánico de los 16 archivos del §1.2.
