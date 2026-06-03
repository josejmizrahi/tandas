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
| F.5 Membership | Create/Join/Invite/MembersList/MemberDetail | ✅ | ⬜ |
| F.6 Resources | ResourcesList/Create/Detail (con "por qué lo ves") + GrantRightSheet | ✅ | ⬜ |
| F.7 Events | EventsList/Create/Detail (RSVP + check-in + cancel + close + host rotation) | ✅ | ⬜ |
| F.8 Rules | RulesList + CreateRuleWizard (late fee / same-day / norma) + RuleDetail | ✅ | ⬜ |
| F.9 Reservations | ReservationsList + Request + ConflictView (resolver / escalar a votación) | ✅ | ⬜ |
| F.10 Decisions | DecisionsList/Create/Detail (votos, cerrar, ejecutar) | ✅ | ⬜ |
| F.11 Money | MoneyHome (balances + obligations) + RecordExpense (SplitEditor) + GameResult + Fine | ✅ | ⬜ |
| F.12 Settlement | SettlementView (generar + items + marcar pagado) | ✅ | ⬜ |
| F.13 Activity | ActivityFeed (paginado, agrupado por día) + ActivityDetail | ✅ | ⬜ |
| F.14 Full App Flow | Smokes manuales end-to-end | — | ⬜ **pendiente founder** |

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
        └── Features/                 # Auth, ContextShell, ContextHome, Membership,
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

## Pendientes conocidos (post-rebuild)

- `update_my_profile` no tiene pantalla (el nombre viene de `ensure_person_actor`);
  agregar EditProfile cuando el founder lo pida.
- Reservations usa lista, no calendario visual (`ReservationsCalendarView` del plan
  quedó como lista por fechas — más simple y igual de operable).
- `execute_decision` no aplica efectos automáticos sobre reservaciones (el backend
  tampoco — `effects` es informativo); el admin resuelve el conflicto desde el recurso.
- Sin push notifications (el backend MVP2 no las tiene; pull vía Activity).
