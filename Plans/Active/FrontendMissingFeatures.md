# Frontend Missing Features — Ruul iOS (priorizado)

**Fecha:** 2026-06-11 (revisión 2026-06-14 — sección "Deltas" agregada)
**Fuente:** `FrontendFlowAudit.md` (auditoría completa con file:line).
**Criterio:** P0 = rompe un flujo obligatorio hoy · P1 = core avanzado incompleto ·
P2 = escalabilidad/pulido. "Backend ✅" = el RPC/tabla ya existe en migrations.

## Deltas detectados en re-audit 2026-06-14 (post R.7/R.8)

Auditoría paralela fresca cruzada contra este backlog. Cinco gaps reales que el doc
original no captura (R.8.A se firmó el 2026-06-10, un día antes del doc; R.7.x cerró
2026-06-09 dejando expuestos huecos en NotificationCenter y Settlement admin loop).

| # | Flow | Pantalla | Estado actual | Backend | RPC | Qué falta | Prioridad | Riesgo | Archivo Swift | Recomendación |
|---|---|---|---|---|---|---|---|---|---|---|
| D1 | Money | MoneyHomeView | `pendientesSection` muestra TODAS las obligaciones; `fondosSection` es solo `NavigationLink → PoolsListView`. Cero uso de `paired_obligation_id` en iOS (`grep` en Packages = 0 hits) | ✅ R.8.A mig `20260610230000` agregó la columna | PostgREST `obligations` filtrado | Doctrina **Option C firmada 2026-06-10**: separar `tesoreriaSection` (filter `paired_obligation_id IS NULL`) ≠ `fondosSection` (lista pools R.8) | **P0** | Doctrina firmada por el founder NO implementada; el tab Dinero da señales semánticamente incorrectas (gastos vs aportes a botes se mezclan) | `Features/Money/MoneyHomeView.swift:312-323, 426-438` | Renombrar `pendientesSection` → `tesoreriaSection` aplicando el filtro; expandir `fondosSection` a lista inline de pools con balances |
| D2 | Notificaciones | NotificationCenterView | Comentario L4-6 dice "Tap → marca leída y navega al objeto vía AttentionDispatcher (scope-based)" pero L76-79 sólo llama `store.markRead(notification)`. Render usa `RuulNotification` (R.4D), bifurcado de `AttentionItem` | ✅ AttentionDispatcher existe y routea 10 kinds | mismos | Cablear `AttentionDispatcher` en el tap (resolver `scope_kind`/`scope_id` → destino), igual que HomeView/Context | **P1** | Usuario tap notificación, queda en el centro sin navegar al objeto; el comentario inline miente sobre el comportamiento | `Features/Notifications/NotificationCenterView.swift:74-110` | Inyectar `AttentionDispatcher`; mapear `RuulNotification` → `AttentionDestination` por `scope_kind`/`scope_id`; mantener `markRead` como side-effect |
| D3 | Auth | PersonalSettingsView + MeView | Botón "Cerrar sesión" llama `container.signOut()` directo sin `confirmationDialog` | ✅ | — | Confirmation destructive antes de signOut (consistente con resto del flujo: leave_context, archive_resource, etc.) | **P1** | Tap accidental cierra sesión y vacía stores; `FrontendFlowAudit.md` §1 afirma "confirmaciones destructivas en todos los flujos sensibles" — drift documental | `Features/Profile/PersonalSettingsView.swift:84`, `Features/Profile/MeView.swift:635` | `confirmationDialog("Cerrar sesión?", role: .destructive)` con copy "Tu sesión se cerrará en este dispositivo." |
| D4 | Settlement | SettlementView | Handshake 2 vías cubre debtor→creditor→appeal, pero **no hay UI admin** para resolver items en estado `disputed`/`appealed`. L496 menciona el caso sin handler | ⚠️ por confirmar si el contrato expone RPC admin (`resolve_settlement_dispute`) o si admin usa los mismos `confirm/reject` | mismos `mark/confirm/reject/appeal_settlement_paid` | Sección admin (gated por `money.settle`) con disputed/appealed items + acción "Resolver disputa" | **P1** | Disputas quedan en limbo; admin invisible al ciclo final del handshake | `Features/Settlement/SettlementView.swift:496` | Si backend usa mismos RPCs: section admin con `if me.canSettle && item.status in (disputed, appealed)`. Si no: solicitar RPC nuevo |
| D5 | Atención | DecisionDetail / RuleDetail / ObligationDetail | Attention items no se auto-dismissean cuando el objeto subyacente se resuelve (decisión ejecutada/regla archivada/obligación pagada). Sólo `NotificationCenterView` permite dismiss manual | ✅ `dismiss_attention_item` existe | `dismiss_attention_item` | Llamar dismiss en `onAppear` de detail cuando `attention.kind` matches y `subject.status == resolved` (o desde backend al cierre del objeto) | **P2** | Inbox de atención muestra items zombie ("vota esta decisión" tras haber votado); pulido UX, no rompe flujo | `Features/Decisions/DecisionDetailView.swift`, `Features/Rules/RuleDetailView.swift`, `Features/Money/ObligationDetailView.swift` | Mejor en backend: trigger `AFTER UPDATE` que dismissee attention items del subject. Si no: matching en `onAppear` con kind+subject |

**Plan de cierre de deltas:** ver `FrontendImplementationPlan.md` §Fase 6.

## Gaps device-detected (founder report 2026-06-14, post Fase 7)

Tras usar la app en device, founder detectó 4 issues funcionales / UX que las
auditorías automatizadas no encontraron:

| # | Issue | Root cause | Estado | Plan |
|---|---|---|---|---|
| F1 | Contexto padre no muestra miembros de subespacios | `descriptor.membersPreview` solo trae directos; iOS no agregaba childContextsPreview en PeopleTab | ✅ shipped Fase 8.2 | Sección "Subespacios (N)" con NavigationLink a ContextDetailV2 del hijo |
| F2 | Pool no permite registrar aporte por otro (admin record) | RPC backend `contribute_to_pool` no acepta `p_contributor_actor_id`; el contributor se infiere del caller | **❌ BLOQUEADO BACKEND** | Agregar `p_contributor_actor_id` al RPC + permission `pool.contribute_on_behalf` o reusar `money.settle`. Documentar como R.8.D |
| F3 | Tabs de ContextHome se encimaban | 7 tabs en `Picker.segmented` no caben en iPhone | ✅ shipped Fase 8.1 | Cambio a ScrollView horizontal con tabChip estilo Stocks/Music/Calendar |
| F4 | DecisionDetail demasiado scroll | 10 sections consecutivas, las accionables enterradas | ✅ parcial shipped Fase 8.3 | Activity preview 5 → 3 items (~120px menos scroll). Resto founder-locked en su orden original |

---

---

## P0 — debe funcionar ya

| # | Flow | Pantalla | Estado actual | Backend | RPC | Qué falta | Riesgo | Archivo Swift | Recomendación |
|---|---|---|---|---|---|---|---|---|---|
| P0.1 | C Invitación | PendingInvitationsView | Solo botón "Aceptar"; no hay rechazar | ❌ (sin RPC `decline_invitation` en contrato) | — | RPC backend + swipe/botón "Rechazar" | Invitaciones zombie acumulándose; el invitado no puede limpiar su inbox | `Features/Membership/PendingInvitationsView.swift:100-132` | Crear RPC `decline_invitation(p_context_actor_id)` (o reusar `set_membership_state`) + UI con confirmación |
| P0.2 | C Invitación | InviteMembersView / ContextSettings | `revokeInvite()` existe en cliente y backend pero sin superficie de UI | ✅ | `revoke_invite` | Lista de códigos activos + acción revocar | Un código filtrado no se puede invalidar → cualquiera entra al contexto | `RuulCore/Stores/MembersStore.swift:55-57`, `Features/Membership/InviteMembersView.swift` | Sección "Códigos activos" en InviteMembersView con revoke + confirmación |
| ~~P0.3~~ ✅ shipped | A Auth | RuulAppShell bootstrap | **Resuelto** — `SessionStore.verifyRestoredSessionIfNeeded()` se llama en `RuulAppShell.swift:55` al transicionar a `.signedIn`; si `checkSessionValidity()` devuelve `.invalid` → `signOut()` limpio. Fallo de red NO desloguea. | ✅ | `auth.user()` via `checkSessionValidity` | — | — | `RuulCore/Stores/SessionStore.swift:55-61`, `RuulApp/App/RuulAppShell.swift:53-55` | Falso positivo del audit original (re-audit 2026-06-14). |
| P0.4 | E Money | ObligationDetailView | `pay`/`dispute`/`cancel` anunciadas por el descriptor backend; iOS las filtra a "Próximamente" | ⚠️ descriptor las anuncia pero no hay RPC `pay_obligation` dedicada | — | Decidir: o el backend deja de anunciarlas, o se crean las RPCs y se cablean | Botón visible que no hace nada (viola la regla final del MVP); usuarios esperan pagar desde la obligación | `Features/Money/ObligationDetailView.swift:37-45,103-117` | Corto plazo: que el descriptor no emita acciones sin RPC. Mediano: RPC `pay_obligation` que dispare el flujo settlement |
| P0.5 | Permisos | Superficies con acciones disabled | `AvailableAction.reason` no se muestra consistentemente | ✅ (reason viene en el payload) | descriptors | Render uniforme del `reason` cuando una acción está deshabilitada | Usuario no entiende por qué no puede hacer algo (pedido explícito del founder) | `Components/`, vistas de detalle | Componente común `DisabledActionRow(reason:)` aplicado en toolbars/menus |
| P0.6 | F.14 | Todos | Smoke manual end-to-end en iPhone nunca ejecutado (founder) | ✅ | — | Ejecutar los 5 escenarios de F.14 y registrar resultados | Sin validación real en device, cualquier gap de integración pasa desapercibido | `Plans/Active/Frontend_MVP2_Rebuild.md:61-78` | Ejecutar F.14 ANTES de construir más features; archivar resultados en R5Z |

## V — Faltantes derivados de la visión (Plans/Archive/Vision.md)

Auditados contra los pilares de la visión canónica (memoria institucional verificable,
acto > estado, compliance desde el diseño, AI propone-no-ejecuta, doctrina UX R.5V).

| # | Pilar | Pantalla | Estado actual | Backend | RPC | Qué falta | Prioridad | Riesgo | Archivo Swift | Recomendación |
|---|---|---|---|---|---|---|---|---|---|---|
| ~~V.1~~ ✅ shipped | Compliance ARCO + App Store | PersonalSettingsView | **Resuelto** — sección "Eliminar cuenta" gated por `confirmationDialog` "¿Eliminar tu cuenta de forma permanente?" con copy ARCO + RPC `deleteMyAccount()`. Pseudonimización backend. | ✅ | `delete_my_account` | — | — | `Features/Profile/PersonalSettingsView.swift:91-113, 117-123` | Falso positivo del audit original (verificado re-audit 2026-06-14). |
| V.2 | Compliance | SignedOutView | Sin links a aviso de privacidad ni términos | ✅ (ruul.mx es estático; basta publicar `/legal/*`) | — | Footer con links "Aviso de privacidad" y "Términos" en login + entrada en ajustes | **P0** | App Store exige privacy policy URL; LFPDPPP exige aviso no decorativo | `Features/Auth/SignedOutView.swift`, `web/public/` | Páginas estáticas en ruul.mx + `Link` en SignedOutView y PersonalSettings |
| V.3 | Memoria institucional exportable | ActivityFeedView / ContextSettings | Sin export de actividad, ledger, decisiones ni reglas vigentes | ⚠️ (los datos existen; falta RPC/format de export) | `list_activity`, settlement/obligations reads | "Exportar historial" (CSV/PDF) por contexto: actividad + balances + decisiones con quién votó + reglas vigentes a una fecha | **P1** | La promesa central del producto ("memoria verificable", "export simple" en plan gratis) no es demostrable hoy | `Features/ContextShell/ContextSettingsView.swift` | Empezar con CSV de activity + balances vía ShareLink; PDF después |
| V.4 | Doctrina UX R.5V §1 | RuleDetailView | Incumple el patrón universal: sin widgets (trigger count / last fired), sin attention (violations recientes), sin activity (`rule.fired`) | ✅ (activity ya registra; KPIs derivables) | `list_activity` filtrada | Completar las 3 secciones que exige la tabla §1 de la doctrina congelada | **P1** (absorbe P1.6) | Drift contra doctrina FROZEN firmada por founder | `Features/Rules/RuleDetailView.swift` | Mismo slice que P1.6: historial + consecuencias emitidas + KPIs |
| V.5 | Pricing por grupo + módulos | (no existe) | Cero superficie de monetización (planes, módulos activables) | ❌ | — | Paywall por grupo, catálogo de módulos (Funds+, Governance+, Documents, AI) | **P2** | Ninguno hoy; decisión de negocio post-validación de wedges | nuevo | No construir hasta validar GTM; la visión la define por grupo, NUNCA por seat |
| V.6 | Seguridad baseline | PersonalSettingsView | Sin MFA promovido para admins | ✅ (Supabase Auth soporta MFA) | Supabase Auth | Sección "Seguridad" con enrolamiento MFA opcional | **P2** | Bajo en MVP; sube al custodiar más valor | `Features/Profile/PersonalSettingsView.swift` | Promoverlo a admins de contextos con fondos |
| V.7 | Posicionamiento | Onboarding / empty states | Los empty states son funcionales pero no comunican la tesis ("vivir, decidir y recordar como institución") | n/a | — | Pasada de copy en NoContextsView, CreateContextView y empty states clave | **P2** | Percepción de "otra app de gastos" en vez de categoría nueva | varios | Alinear copy con el mensaje público de la visión |

Verificado y **conforme a la visión** (sin acción): AI heroes solo proponen y citan el
contexto considerado (cero write-paths de AI); settlement corrige con asientos nuevos
(acto > estado); decisiones cross-context visibles vía attention_inbox (cumple el
espíritu del tab Decisions de la visión, derogado por F.NAV); documents inmutables con
versiones por `supersedes`.

## P1 — core avanzado

| # | Flow | Pantalla | Estado actual | Backend | RPC | Qué falta | Riesgo | Archivo Swift | Recomendación |
|---|---|---|---|---|---|---|---|---|---|
| P1.1 | Notificaciones | (no existe) | Solo attention_inbox (pull); R.4D sin consumir | ✅ R.4D | `mark_notification_read/archived`, `mark_all_notifications_read` | Centro de notificaciones con leído/no-leído + badge real | Usuarios pierden eventos que no son "atención accionable" | nuevo `Features/Notifications/` | NotificationCenterView + store; integrar con tab Actividad |
| P1.2 | Perfil | EditProfileView | `avatarUrl: nil` hardcoded; solo initials | ✅ (`update_my_profile(p_avatar_url)` + Storage) | `update_my_profile` | PhotosPicker + upload a Storage + URL | Identidad visual pobre en grupos grandes | `Features/Profile/EditProfileView.swift:47,119` | Bucket `avatars` + PhotosPicker + resize client-side |
| P1.3 | Perfil | PersonalSettingsView | Sin UI para cambiar teléfono/email | ✅ | `startPhoneChange`/`confirmPhoneChange` (AuthService:321-335) | Pantalla de cambio con OTP de verificación | Usuario que cambia de número queda bloqueado | `Features/Profile/PersonalSettingsView.swift` | Sheet "Cambiar teléfono/correo" con flujo OTP |
| ~~P1.4~~ ✅ shipped (Fase 4c) | Grupos | ContextSettingsView | **Resuelto** — `archiveSection()` + `requestArchiveContext()` vía governance (`context.archive`), confirmation dialog, sheet de DecisionDetailView con la propuesta. | ✅ | `request_governance_action(context.archive)` | — | — | `Features/ContextShell/ContextSettingsView.swift:148-190` | Falso positivo del audit original (commit `0218dc8e`). |
| P1.5 | Membresías | MemberDetailView | Suspender solo vía governance; `set_membership_state` directo sin UI | ✅ | `set_membership_state` | Acción directa para admins donde la policy no exige decisión | Admin no puede pausar a un miembro problemático rápido | `Features/Membership/MemberDetailView.swift:163-168` | Cablear cuando `member_available_actions` lo emita con mode=execute |
| P1.6 | Reglas | RuleDetailView | Sin historial de versiones ni consecuencias emitidas | ⚠️ parcial (activity registra; sin RPC de versiones) | `list_activity` filtrada | Sección "Historial" + "Consecuencias emitidas" (obligations creadas por la regla) | No se puede auditar qué hizo una regla → desconfianza en el motor R.6 | `Features/Rules/RuleDetailView.swift:112-123` | Filtrar activity por rule_id + linkear obligations generadas |
| P1.7 | Decisiones | DecisionDetailView | Quorum/threshold no visible antes de votar; sin countdown | ✅ (decision_detail trae result/votes) | `decision_detail` | Mostrar regla de aprobación ("mayoría simple, N/M votos") + countdown a closesAt | Votantes no saben cuánto falta para que pase | `Features/Decisions/DecisionDetailView.swift:330-337` | Chip "Se aprueba con X de Y" + TimelineView para el cierre |
| ~~P1.8~~ ✅ shipped | Governance | ContextSettingsView | **Resuelto** — `governanceCatalogSection()` carga catálogo via `listGovernanceActionCatalog()`, filtra por `defaultRequiresDecision`, muestra cada acción con badge "Votación" + dangerous shield. | ✅ | `governance_action_catalog` | — | — | `Features/ContextShell/ContextSettingsView.swift:23, 116, 120, 195-223` | Falso positivo del audit original (verificado re-audit 2026-06-14). |
| P1.9 | Money | (admin) | `void_transaction` (AUDIT.1) sin UI | ✅ | `void_transaction` | Acción admin "Anular transacción" con razón | Errores de captura quedan permanentes en la contabilidad | nuevo en `Features/Money/` | Gated a admin + confirmación + razón obligatoria |
| P1.10 | Pools | PoolDetailView / CreatePoolSheet | Solo 2 políticas (winner_takes_all, equity_target) | ⚠️ por confirmar qué políticas adicionales soporta `resolve_pool` | `create_pool`, `resolve_pool` | Políticas restantes de R.8 si el backend ya las acepta | Pools de viaje (proporcional) no modelables | `Features/Pools/CreatePoolSheet.swift` | Confirmar contra R8_PoolPrimitive.md y extender el picker |
| P1.11 | Recursos | ResourceActionFormView | Campos actor_ref/resource_ref caen a TextField de UUID | ✅ | `execute_resource_action` | Pickers nativos poblados de MembersStore/ResourcesStore | Forms server-driven inutilizables para humanos | `Features/Resources/ResourceActionFormView.swift:228,299` | Resolver `format: actor_ref` → Picker de miembros |
| P1.12 | Navegación | ContextDetailV2 | BreadcrumbView y ContextTreeView definidas, nunca renderizadas | ✅ (`context_ancestors`/`context_tree`) | hierarchy RPCs | Cablear breadcrumb en subcontextos + árbol en tab More, o borrarlas | Código muerto; subcontextos difíciles de navegar hacia arriba | `Features/ContextShell/BreadcrumbView.swift`, `ContextTreeView.swift` | Cablear breadcrumb (ya hay environment `navigateToContext`) |
| P1.13 | Perfil | MainTabShell | "Contexto inicial" se persiste pero no se aplica | ✅ (metadata) | `personal_settings_summary` | Abrir ese contexto al arrancar si está configurado | Setting que no hace nada (viola regla final) | `Features/Shell/MainTabShell.swift` | Leerlo en bootstrap del tab Contextos |
| ~~P1.14~~ ✅ shipped (Fase 3) | Reservas | RequestReservationView | **Resuelto** — `whySection` con `why.reasons` (Label + key icon), fallback honesto, `LabeledContent` para capability requerida cuando se deniega. | ✅ | `why_can_reserve` | — | — | `Features/Reservations/RequestReservationView.swift:145-185` | Falso positivo del audit original (verificado re-audit 2026-06-14). |
| P1.15 | Decisiones | MyDecisionsView | No distingue "ya voté" vs "necesito votar" | ✅ | `decision_votes` | Filtro/badge de pendientes de mi voto | Cubierto parcialmente por attention_inbox | `Features/Profile/MyDecisionsView.swift:7-11` | Cruzar con listDecisionVotes en el fan-out |
| P1.16 | Grupos | ContextSettingsView | Roles personalizados placeholder | ❌ (no hay RPCs de role CRUD) | — | Definición backend primero | Bajo — roles canónicos bastan en MVP | `ContextSettingsView.swift:342-353` | Mantener placeholder; diseñar post-MVP |
| P1.17 | Decisiones | CreateDecisionView | Templates R.4B sin UI dedicada | ✅ (execute_decision con templates) | `create_decision` | Picker de plantillas de decisión | Decisiones ejecutables se crean "a mano" | `Features/Decisions/CreateDecisionView.swift` | Exponer templates del catálogo R.4B |
| ~~P1.18~~ ✅ shipped (Fase 3) | Activity | ActivityFeedView | **Resuelto** — `payloadKeyLabel` cubre rule_id/source_rule_id/outcome/triggered_by_event_type/consequences_applied/evaluation_id/via/settlement_batch_id/etc. `payloadValueLabel` traduce matched/fired/skipped/no_match. | ✅ | `list_activity` | — | — | `Features/Activity/ActivityFeedView.swift:282-330` | Falso positivo del audit original (verificado re-audit 2026-06-14). |

## P2 — escalabilidad / pulido

| # | Tema | Qué falta | Archivo / área | Nota |
|---|---|---|---|---|
| P2.1 | Search | `.searchable` en Events/Decisions/Members(ya)/Obligations; búsqueda global | listas de features | Solo Contextos/Recursos/Reglas hoy |
| P2.2 | Skeletons | Placeholders `redacted(reason: .placeholder)` en vez de spinner | listas principales | Pulido visual |
| P2.3 | Infinite scroll | Paginación automática en activity (hoy botón "Cargar más") | `ActivityFeedView.swift:84-96` | + paginación en feed personal (hoy 1 página de 50) |
| P2.4 | Integraciones | Google/Apple Calendar, Wise, WhatsApp | `PersonalSettingsView.swift:348-372` | Hoy "Próximamente" |
| P2.5 | Documentos | Sign / Approve / Versions (FQ-2/FQ-4) | `DocumentDetailView.swift:225-226` | Requiere backend |
| P2.6 | Offline/cache | Sin capa de cache; todo refetch | RuulCore | Evaluar solo si duele en device |
| P2.7 | Widgets / Live Activities | No existen | nuevo target | Post-MVP |
| P2.8 | Audit log completo | "Cambios críticos e historial completo llegan después" | `ContextSettingsView.swift:656-660` | Activity ya cubre lo básico |
| P2.9 | Relaciones de recursos (R.0D) | `set/remove/list_resource_relation` sin UI de edición | descriptor ya muestra relaciones read-only | Backend listo |
| P2.10 | Accesibilidad profunda | VoiceOver audit completo, Dynamic Type en heros custom | global | Labels básicos ya existen |
| P2.11 | Push notifications | APNs + emit_notification | — | Fuera de doctrina MVP2 (pull-based) |

---

## Resumen ejecutivo

### Estado post Fase 6.x (2026-06-14)

Tras cerrar Fases 6/6.2/6.3, el re-audit detectó **8 falsos positivos** del doc
original: items marcados como pendientes que en realidad ya estaban shipped en
Fases 2/3/4/5/5a-d. Estado real:

**P0 reales pendientes (3):**
- **P0.1** Rechazar invitación — requiere RPC backend `decline_invitation`.
- **P0.4** Obligation pay/dispute/cancel — requiere decisión backend (drift catálogo).
- **P0.6** Smoke F.14 — manual en device, sin código.

**P0 falsos positivos (resueltos):** D1, D3, P0.2 (Fase 6.x); P0.3, P0.5 parcial (Fase
5d); V.1, V.2 (auditor antiguo no vio el shipping reciente).

**P1 reales pendientes (≤4):**
- **P1.5** Suspensión directa (bloqueada hasta que backend emita con `mode=execute`).
- **P1.10** Pools políticas adicionales (proportional shipped; resto requiere R.8 backend).
- **P1.11** Pickers nativos en ResourceActionFormView (verificar — Fase 2 cierre dice falso positivo).
- **P1.16** Roles personalizados (placeholder; requiere backend).

**P1 falsos positivos (resueltos):** D2, D4 (Fase 6); P1.1, P1.2, P1.3, P1.6/V.4, P1.7,
P1.8, P1.13, V.3 (Fase 2 explícita); P1.4 (Fase 4c); P1.14, P1.18 (Fase 3); P1.17
(Fase 5b).

**P2** es cola de pulido sin riesgo (V.5 monetización, V.6 MFA, V.7 copy, **D5 attention
auto-dismiss shipped Fase 6.2**).

**Conclusión:** el frontend tiene ≤7 items P0/P1 abiertos, de los cuales **3 requieren
backend nuevo o validación en device**. El backlog de "hacer UI con backend listo"
quedó esencialmente vacío.
