# Frontend MVP 2.0 — Rebuild (F.0–F.14)

**Fecha:** 2026-06-03
**Branch:** `claude/ruul-frontend-mvp2-rebuild-HvmJE`
**Principio:** Backend = autoridad · Frontend = operación clara por contexto.

## Estado por fase

| Fase | Contenido | Código | Smoke manual iPhone |
|---|---|---|---|
| F.0 Audit | `Frontend_MVP2_Audit.md` + `MVP2_iOS_Contract.md` + borrado del legacy | ✅ | n/a |
| F.1 API Contract | `RuulCore/API` (protocolo ~45 métodos, live, mock) + Domain + errores + tests de decoding | ✅ | n/a |
| F.2 Auth + Session | SessionStore + CurrentActorStore (`ensure_person_actor`) + SignedOutView OTP | ✅ | ⬜ |
| F.3 ContextShell | ContextStore (`context_candidates` + persistencia) + ContextShell + Switcher + NoContextsView | ✅ | ⬜ |
| F.4 ContextHome | ContextHomeStore (`context_summary` + `my_world`) + ContextHomeView | ✅ | ⬜ |
| F.5 Membership | Create/Join/Invite/MembersList/MemberDetail + universal links (ruul.mx/invite) | ✅ | ⬜ |
| F.6 Resources | ResourcesList/Create/Detail (con "por qué lo ves") + GrantRightSheet | ✅ | ⬜ |
| F.7 Events | EventsList/Create/Detail (RSVP + check-in + cancel + close + host rotation) | ✅ | ⬜ |
| F.8 Rules | RulesList + CreateRuleWizard (late fee / same-day / norma) + RuleDetail | ✅ | ⬜ |
| F.9 Reservations | ReservationsList + Calendario mensual + Request + ConflictView (resolver / escalar a votación) | ✅ | ⬜ |
| F.10 Decisions | DecisionsList/Create/Detail (votos, cerrar, ejecutar) | ✅ | ⬜ |
| F.11 Money | MoneyHome (balances + obligations) + RecordExpense (SplitEditor) + GameResult + Fine | ✅ | ⬜ |
| F.12 Settlement | SettlementView (generar + items + marcar pagado) | ✅ | ⬜ |
| F.13 Activity | ActivityFeed (paginado, agrupado por día) + ActivityDetail | ✅ | ⬜ |
| F.14 Full App Flow | Smokes manuales end-to-end | — | ✅ founder 2026-06-12 |

## Arquitectura final

```
ios/
├── Tandas/TandasApp.swift            # @main → RuulAppShell (Sentry, sin APNs)
└── Packages/
    ├── RuulCore/                     # Sin UI. Swift 6 strict concurrency.
    │   ├── JSONCoding.swift          # PostgresTimestamp + JSONValue
    │   ├── Supabase/                 # SupabaseClient env + AuthService (OTP/Apple/anon)
    │   ├── Errors/                   # RuulError + BackendError + RPCErrorMapper + UserFacingError
    │   ├── Domain/                   # Modelos 1:1 con el wire MVP2
    │   ├── API/                      # RuulRPCClient (protocolo) + Supabase (live) + Mock (demo world)
    │   └── Stores/                   # @MainActor @Observable por feature
    └── RuulApp/                      # UI. SwiftUI puro, iOS 26.
        ├── App/                      # DependencyContainer (slim) + RuulAppShell (3 gates)
        ├── Components/               # StateViews, ActionRunner, InfoRow, badges
        └── Features/                 # Auth, Profile, ContextShell, ContextHome, Membership,
                                      # Resources, Events, Rules, Reservations,
                                      # Decisions, Money, Settlement, Activity
```

Decisiones clave:

1. **Stores por pantalla** (`@State` en la vista, no en el container). Cambio de
   contexto = rebuild completo (`.id(context.id)`) → nunca hay datos de otro contexto.
2. **Sin capa de repositories.** Store → RPCClient → backend.
3. **Mock en Sources** (`MockRuulRPCClient.demo()`): cada vista tiene preview funcional
   con el escenario del founder (José/David/Isaac/Moisés/Daniel, Cena Semanal,
   Familia, Casa Valle).
4. **Permisos**: la UI gatea botones con `context_summary().my_permissions`; el backend
   siempre re-valida.
5. **Errores**: todos los raises MVP2 pasan por `RPCErrorMapper` → `UserFacingError`
   (copy en español). Nunca se muestra un mensaje crudo del backend.

## F.14 — Smokes manuales pendientes (requieren iPhone + backend live)

Estos son los escenarios del plan que NO se pueden verificar desde CI y quedan
para el founder en device:

1. **Cena semanal completa**: crear contexto → invitar (David se une con código) →
   crear cena recurrente → RSVP de todos → regla late fee → check-in tarde de Moisés
   (multa automática) → Daniel cancela same-day (multa) → cerrar evento (host rota).
2. **Casa Valle reservable**: crear Casa Valle en Familia → grant USE a José/David/Isaac,
   VIEW a Moisés → David pide el fin → Isaac pide el mismo fin → conflicto → admin
   resuelve a favor de Isaac → David rechazado.
3. **Viaje Japón con gastos**: crear contexto trip → gasto $1,300 de David con Daniel
   excluido → José/Isaac/Moisés deben $325 → settlement → pagos.
4. **Negocio Valle con decisión**: contexto legal_entity → decisión → votos → ejecutar.
5. **Trust básico visible**: contexto trust visible en el switcher con recursos.

Criterio final del plan: todo corre desde iPhone, sin SQL manual, sin mocks, sin
pantallas legacy.

## Estado post-auditoría FE (2026-06-12)

Las Fases 1–3 de `FrontendImplementationPlan.md` están completas y en main
(PRs #169–#174 + Fase 3): invitaciones bidireccionales (decline/revoke),
evict de sesiones huérfanas, legal + eliminación de cuenta (App Store
5.1.1(v)/ARCO), descriptor de obligaciones honesto, centro de notificaciones
R.4D con primer emisor real, foto de perfil, cambio de teléfono/correo,
countdown/participación en decisiones, historial real de reglas, export CSV
de la memoria, pausa directa de miembros y catálogo de governance visible.
F.14 (smoke manual en iPhone) sigue pendiente del founder e incluye ahora
los flujos nuevos.

## Pendientes conocidos (post-rebuild)

- ~~`update_my_profile` no tiene pantalla~~ → **hecho**: `EditProfileView`
  (entrada en el ContextSwitcherMenu → "Tu perfil").
- ~~Reservations usa lista, no calendario visual~~ → **hecho**:
  `ReservationsCalendarView` (picker Lista/Calendario en ReservationsListView).
- ~~Invitaciones solo por código de texto~~ → **hecho**: ShareLink comparte
  `https://ruul.mx/invite/CODE`; `DeepLinkRouter` abre `JoinByCodeView` con el
  código prellenado al tocar el link (universal links + scheme `ruul://`).
- ~~"Alguien" en vez del nombre real~~ → **hecho**: la resolución de nombres en
  todos los stores ahora cae a "Tú" cuando el actor es el usuario (contexto
  personal o actores fuera de members).
- ~~Reservar desde el contexto personal creaba la reservación en el contexto
  equivocado~~ → **hecho**: las solicitudes usan el contexto con right GOVERN
  sobre el recurso, no el contexto desde el que se navega.
- ~~El settlement era un corte manual y los pagos parciales no bajaban el balance~~ →
  **hecho (R.2N, backend + iOS)**: neteo vivo por novación — se recalcula solo al
  registrar deudas nuevas y cada pago cierra su saldo al instante.
- `execute_decision` no aplica efectos automáticos sobre reservaciones (el backend
  tampoco — `effects` es informativo); el admin resuelve el conflicto desde el recurso.
- Sin push notifications (el backend MVP2 no las tiene; pull vía Activity).
- `revoke_invite` y `list_context_reservations` existen en el contrato pero aún
  no tienen UI.
- El backend acepta reservaciones con contextos sin relación al recurso
  (hueco de validación — el frontend ya manda el contexto correcto).

## Infraestructura web (`web/`)

`web/public` es un sitio estático en Cloudflare Pages (`ruul-web` → ruul.mx):
landing + AASA para universal links + página de invitación. **No habla con el
backend** — solo hace que `ruul.mx/invite/CODE` abra la app (o muestre el código
a quien no la tiene). Se conserva como parte del flujo de invitaciones.
