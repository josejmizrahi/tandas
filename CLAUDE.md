# Tandas / Ruul — Project Context (iOS native, MVP 2.0)

App nativa iOS para administrar contextos compartidos (grupos de amigos, familias,
viajes, negocios, trusts): miembros, recursos, eventos, reglas, decisiones, dinero y
actividad. SwiftUI + Supabase. Liquid Glass real gracias a iOS 26+.

## Doctrina MVP 2.0 (2026-06-02, founder-signed)

```
Actor        = quién existe (person / collective / legal_entity / system)
Contexto     = el actor desde el cual operas (UX = context-first)
Resource     = qué cosa existe
Right        = qué derecho tiene un actor sobre un recurso (OWN/USE/MANAGE/VIEW/…)
Membership   = quién participa en un contexto
Event        = qué ocurre en el tiempo (calendar_events + participants)
Rule         = qué pasa automáticamente (condition_tree → consequences)
Decision     = cómo se aprueba algo (votos, mayoría simple)
Obligation   = qué debe quién (multas, partes de gasto, deudas de juego)
Money        = transacciones + splits + settlement (neteo min-cashflow)
Activity     = qué pasó (append-only, por contexto)
```

**No hay tablas group-céntricas.** El "grupo" es solo un actor `collective`.
Backend = autoridad; frontend = operación clara por contexto, sin lógica duplicada.

## Stack

- **SwiftUI** (iOS 26+ deployment target, Liquid Glass real)
- **Swift 6** + strict concurrency
- **supabase-swift** SDK (RPCs + lecturas PostgREST read-only)
- **Xcode 16+** / CI en macos-15
- **Backend**: Supabase project `wyvkqveienzixinonhum` — schema MVP2
  (migrations `supabase/migrations/2026*`)

## Estructura del repo

```
ios/
├── Tandas/                          # @main (TandasApp → RuulAppShell), recursos
├── Tandas.xcodeproj/                # generado con xcodegen (ios/project.yml)
└── Packages/
    ├── RuulCore/                    # Sin UI
    │   └── Sources/RuulCore/
    │       ├── JSONCoding.swift     # PostgresTimestamp (fechas con microsegundos) + JSONValue
    │       ├── Supabase/            # SupabaseClient env + AuthService (phone/email OTP, Apple)
    │       ├── Errors/              # RuulError / BackendError / RPCErrorMapper / UserFacingError
    │       ├── Domain/              # Modelos 1:1 con el wire (ContextSummary, Resource, …)
    │       ├── API/                 # RuulRPCClient (protocolo) + SupabaseRuulRPCClient (live)
    │       │                        #   + MockRuulRPCClient (demo world para previews/tests)
    │       └── Stores/              # @MainActor @Observable (Session, CurrentActor, Context,
    │                                #   ContextHome, Members, Resources, Events, Rules,
    │                                #   Reservations, Decisions, Money, Settlement, Activity)
    └── RuulApp/                     # UI
        └── Sources/RuulApp/
            ├── App/                 # DependencyContainer (slim) + RuulAppShell (3 gates)
            ├── Components/          # StateViews, ActionRunner, InfoRow, StatusBadge
            └── Features/            # Auth, Profile, ContextShell, ContextHome, Membership,
                                     #   Resources, Events, Rules, Reservations, Decisions,
                                     #   Money, Settlement, Activity

web/public/                          # Estático en Cloudflare Pages (ruul.mx): landing + AASA
                                     #   (universal links) + página de invitación. No toca el backend.
supabase/migrations/                 # Cadena MVP2 (mvp2_000 … r2k) — fuente única del backend
Plans/Active/MVP2_iOS_Contract.md    # Contrato completo backend ↔ iOS (RPCs + shapes)
Plans/Active/Frontend_MVP2_Rebuild.md# Estado del rebuild F.0–F.14
```

## Arquitectura iOS

1. **3 gates en RuulAppShell**: sesión (`SessionStore`) → person actor
   (`CurrentActorStore` / `ensure_person_actor()`) → contexto (`ContextShell`).
   Usuarios anónimos no entran.
2. **Context-first**: `ContextStore` carga `context_candidates()`, persiste la selección;
   `ContextShell` hace rebuild completo al cambiar de contexto (`.id(context.id)`).
   Sin tabs globales — `ContextHomeView` es la raíz y navega a cada feature.
3. **Stores por pantalla**: cada vista de feature crea su store con `@State` y el `rpc`
   compartido del `DependencyContainer`. Sin capa de repositories.
4. **Lecturas**: RPC cuando existe (`context_summary`, `list_context_resources`,
   `resource_detail`, `my_world`, `list_activity`); PostgREST directo (RLS read-only)
   para `calendar_events`, `event_participants`, `rules`, `decisions`, `decision_votes`,
   `obligations`, `resource_reservations`, `reservation_conflicts`, `settlement_*`.
5. **Escrituras**: SOLO vía RPCs SECURITY DEFINER (el backend valida permisos; la UI
   gatea botones con `my_permissions` de `context_summary`).
6. **Errores**: `RPCErrorMapper` → `UserFacingError` con copy en español. Nunca mostrar
   mensajes crudos del backend.
7. **Previews**: toda vista tiene preview contra `MockRuulRPCClient.demo()` (mundo del
   founder: Cena Semanal, Familia Mizrahi, Casa Valle).

## Backend (referencia rápida)

Contrato completo en `Plans/Active/MVP2_iOS_Contract.md`. Resumen:

| Dominio | RPCs |
|---|---|
| Identity | `ensure_person_actor` · `current_actor_id` · `update_my_profile` |
| Contexts | `create_context` · `context_candidates` · `context_summary` · `my_world` |
| Membership | `create_invite` · `revoke_invite` · `join_by_invite_code` · `invite_member` · `accept_invitation` · `remove_member` · `leave_context` · `assign_role` |
| Resources | `create_resource` · `list_context_resources` · `resource_detail` · `grant_right` · `revoke_right` · `update_resource` · `archive_resource` · `resource_type_catalog` · `resource_capabilities` · `resource_can` |
| Events | `create_calendar_event` · `rsvp_event` · `check_in_participant` · `cancel_participation` · `close_event` |
| Rules | `create_rule` · `evaluate_rules_for_event` (lo invocan check-in/cancel) |
| Reservations | `request_resource_reservation` · `approve/confirm/cancel_reservation` · `detect_reservation_conflicts` · `resolve_reservation_conflict` |
| Decisions | `create_decision` · `vote_decision` · `close_decision` · `execute_decision` |
| Money | `record_expense` · `record_fine` · `record_game_result` |
| Settlement | `generate_settlement_batch` · `mark_settlement_paid` |
| Activity | `list_activity` |

## Reglas

- iOS 26+ deployment target, SwiftUI exclusivamente
- Async/await everywhere, `@Observable` para stores, strict concurrency on
- Mock + preview por cada vista
- Strings de UI en español (founder locale); errores siempre vía `UserFacingError`
- Migrations del backend SOLO vía MCP `apply_migration` con review SQL antes
- Las migrations en `supabase/migrations/` son la fuente única del backend

## DoD por commit

- Compila en Xcode 16+ sin warnings
- `xcodebuild test` pasa (RuulCore package tests + TandasTests en CI)
- Functional smoke en simulador iOS 26 (o device si aplica)

## CI

- `.github/workflows/ios-ci.yml`: xcodegen + RuulCore package tests + app build/test
  (macos-15, iPhone 16 Pro simulator)
- `.github/workflows/edge-tests.yml`: replay de la cadena de migrations MVP2 + smokes
  `_smoke_mvp2_*` en Supabase local
