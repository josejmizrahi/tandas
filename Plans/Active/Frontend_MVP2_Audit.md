# F.0 — Frontend MVP 2.0 Audit / Cleanup

**Fecha:** 2026-06-03
**Contexto:** El backend MVP 2.0 (reset 2026-06-02, migrations `mvp2_000`…`r2k`) eliminó
el 100% del schema viejo. El frontend iOS actual (RuulCore + RuulApp) está escrito contra
~113 RPCs que **ya no existen**. Este documento clasifica qué se conserva, qué se
reescribe y qué se elimina antes de construir el frontend nuevo (F.1–F.14).

**Principio rector del rebuild:**

```
Backend = autoridad
Frontend = operación clara por contexto
```

---

## 1. Veredicto global

| Capa | Archivos | Veredicto |
|---|---|---|
| `RuulCore/API` (RPC client viejo) | 6 | **REWRITE** — 160+ métodos contra RPCs muertos |
| `RuulCore/Domain` (modelos group-céntricos) | 58 | **DELETE** — el concepto "Group" ya no existe en backend |
| `RuulCore/Repositories` | 30 | **DELETE** — capa de indirección innecesaria; los stores nuevos llaman el RPC client directo |
| `RuulCore/Stores` | 36 | **REWRITE** — solo sobreviven `SessionStore` y `StorePhase` |
| `RuulCore/Supabase` (client + auth) | 2 | **KEEP** — backend-agnóstico |
| `RuulCore/Auth` (AuthState) | 1 | **KEEP** |
| `RuulCore/Errors` | 4 | **KEEP parcial** — `RuulError` se queda; el parser de mensajes se reescribe para los raises MVP2 |
| `RuulCore/Localization/L10n.swift` | 1 | **DELETE** — strings del dominio viejo; el rebuild usa strings inline en español |
| `RuulCore/Realtime` | 1 | **DELETE** — MVP2 no usa realtime (pull-based activity) |
| `RuulCore/JSONCoding.swift` | 1 | **REWRITE** — el `.iso8601` estricto no decodifica timestamps de Postgres con microsegundos |
| `RuulCore/Tests` | 68 | **REWRITE** — todos prueban el contrato viejo |
| `RuulApp/Features` (111 vistas) | 111 | **DELETE** — UI group-céntrica (GroupTabsHost, PersonalHomeView, R.0/R.1 views) |
| `RuulApp/App` (Shell, DI, AppDelegate, DeepLink) | 6 | **REWRITE** — shell nuevo context-first; sin APNs (MVP2 no tiene push) |
| `ios/Tandas` (app target) | 1 + recursos | **KEEP** — `TandasApp.swift` se simplifica (sin AppDelegate APNs) |
| `ios/project.yml` / Makefile / CI | 3 | **KEEP** — ajuste menor al scheme para correr tests del package |

**El archive es git.** No se crean carpetas `_archive` en el árbol de iOS: la historia
completa queda accesible en los commits previos a este rebuild (tag de referencia:
commit `c2ed377`, último estado pre-rebuild).

---

## 2. Componentes auditados (los que pide el plan)

| Componente | Archivo | Clasificación | Razón |
|---|---|---|---|
| `RuulRPCClient` | `RuulCore/API/RuulRPCClient.swift` | REWRITE | 160+ métodos contra RPCs inexistentes (`create_group`, `list_my_groups`, `group_summary`, `my_world_summary`, …). El protocolo nuevo tiene ~45 métodos 1:1 con el contrato MVP2. |
| `SupabaseRuulRPCClient` | `RuulCore/API/SupabaseRuulRPCClient.swift` | REWRITE | Mismo motivo. El patrón (`client.rpc(...).execute().value` + `RPCErrorMapper`) se conserva. |
| `MockRuulRPCClient` | `RuulCore/Tests/.../MockRuulRPCClient.swift` | REWRITE | Se mueve a `Sources` (el plan exige preview/mock por vista) y simula el mundo MVP2. |
| `DependencyContainer` | `RuulApp/App/DependencyContainer.swift` | REWRITE | El patrón DI se conserva; el contenido (30 repos + 33 stores muertos) no. |
| `AuthService` | `RuulCore/Supabase/AuthService.swift` | **KEEP** | Solo habla con Supabase Auth (OTP phone/email, Apple, anon). El backend MVP2 no cambió auth; el trigger `_handle_new_auth_user` crea el person actor automáticamente. |
| `SessionStore` | `RuulCore/Stores/SessionStore.swift` | **KEEP** | Backend-agnóstico (subscribe a `AuthService.sessionStream`). |
| `GroupTabsHost` | `RuulApp/Features/Shell/GroupTabsHost.swift` | **DELETE** | Regla explícita del plan: "No revivir GroupTabsHost como raíz". |
| `PersonalHomeView` | `RuulApp/Features/PersonalHome/` | DELETE | Construida sobre `my_world_summary()` (RPC muerto). El concepto sobrevive como `ContextHomeView` + `my_world()`. |
| `MyWorldStore` | `RuulCore/Stores/MyWorldStore.swift` | DELETE | Ídem. |
| `CurrentContextStore` / `AppContext` | `RuulCore/Stores/CurrentContextStore.swift`, `Domain/AppContext.swift` | REWRITE | El diseño (selección + persistencia UserDefaults + fallback persona) se conserva como `ContextStore`; la fuente pasa de `my_world_summary()` a `context_candidates()`. |
| R.0/R.1 views | `RuulApp/Features/*` | DELETE | Todas group-céntricas. |

---

## 3. RPCs viejos rotos (muestra de los 113)

Todos los RPCs que el cliente actual llama desaparecieron en el reset MVP2. Los más
importantes y su reemplazo:

| RPC viejo (muerto) | Reemplazo MVP2 |
|---|---|
| `list_my_groups` | `context_candidates()` |
| `create_group` / `create_group_with_admin` | `create_context(...)` |
| `group_summary` / `group_home_summary` | `context_summary(p_context_actor_id)` |
| `my_world_summary` | `my_world()` |
| `my_profile` / `update_my_profile` | `ensure_person_actor()` / `update_my_profile(...)` (firma nueva) |
| `invite_member` (email/phone) | `create_invite(...)` + `join_by_invite_code(...)` / `invite_member(actor)` |
| `accept_invite` | `join_by_invite_code(p_code)` |
| `leave_group` / `remove_member` | `leave_context(...)` / `remove_member(...)` |
| `group_members` | `context_summary(...).members` |
| `create_*_resource` (6 variantes) | `create_resource(...)` |
| `group_resources_active` / `group_resource_detail` | `list_context_resources(...)` / `resource_detail(...)` |
| `grant_right` (firma vieja) | `grant_right(...)` (firma nueva) |
| `create_event` / `set_rsvp` / `check_in_attendee` / `close_event` | `create_calendar_event` / `rsvp_event` / `check_in_participant` / `close_event` |
| `create_text_rule` / `create_engine_rule` | `create_rule(...)` |
| `start_vote` / `cast_vote` / `finalize_vote` | `create_decision` / `vote_decision` / `close_decision` / `execute_decision` |
| `record_expense` (group-céntrico) | `record_expense(...)` (actor-céntrico, splits equal/custom) |
| `issue_manual_fine` / `issue_sanction` | `record_fine(...)` |
| `record_settlement` / `group_settlement_plan_for_member` | `generate_settlement_batch(...)` + `mark_settlement_paid(...)` |
| `book_resource` / `cancel_booking` | `request_resource_reservation` / `approve/confirm/cancel_reservation` + `resolve_reservation_conflict` |
| `group_events_recent` / `group_events_for_member` | `list_activity(...)` |
| `list_my_inbox` / push outbox | — (sin push en MVP2; pull de `list_activity`) |
| `global_search` | — (fuera de scope MVP2) |
| Disputes / Mandates / Cultural norms / Rituals / Reputation / Dissolution / Boundary / Foundation status (≈40 RPCs) | — (primitivas que no existen en MVP2) |

## 4. Componentes reutilizables (KEEP literal)

1. `Supabase/SupabaseClient.swift` — bootstrap de `SupabaseClient` desde Info.plist.
2. `Supabase/AuthService.swift` — `AuthService` protocol + `MockAuthService` + `LiveAuthService` (OTP phone/email, Apple, anon, session stream).
3. `Auth/AuthState.swift` — enum de ciclo de vida de sesión.
4. `Stores/SessionStore.swift` — store de sesión.
5. `Stores/StorePhase.swift` — tri-estado idle/loading/loaded/failed.
6. `Errors/RuulError.swift` — error raíz.
7. `App/AppearancePreference.swift` — preferencia de apariencia.
8. `ios/Tandas/Resources/*` — assets, Info.plist, entitlements.
9. `TandasTests/MockAuthServiceTests.swift` — único test que sobrevive tal cual.
10. Patrones (no archivos): `@MainActor @Observable` stores, `.glassProminent`/`.glass` buttons,
    `UserFacingError` con copy en español, params Encodable con CodingKeys snake_case.

## 5. Decisiones de arquitectura del rebuild

1. **Sin capa de Repositories.** El RPC client devuelve modelos de dominio directamente.
   Backend manda la verdad; mapear DTO→Domain en una capa intermedia duplicaba lógica.
2. **Mock en Sources, no en Tests.** `MockRuulRPCClient` vive en `RuulCore/API` para que
   cada vista tenga preview funcional (regla del plan).
3. **Lecturas:** RPCs de lectura cuando existen (`context_summary`, `list_context_resources`,
   `resource_detail`, `list_activity`, `my_world`); lecturas PostgREST directas (RLS read-only)
   para tablas sin RPC de lista (`calendar_events`, `event_participants`, `rules`, `decisions`,
   `decision_votes`, `obligations`, `resource_reservations`, `reservation_conflicts`,
   `settlement_batches`, `settlement_items`).
4. **Sin tabs globales.** `ContextShell` = NavigationStack con `ContextHomeView` como raíz
   y navegación a secciones. Tabs se evalúan post-F.14.
5. **Sin push/APNs/realtime/deep links** en este rebuild (el backend MVP2 no los soporta).
   `TandasApp` pierde el `@UIApplicationDelegateAdaptor`.
6. **Fechas:** decoder tolerante (ISO8601 con y sin fracciones de segundo) — el `.iso8601`
   estricto de Foundation no parsea los timestamps con microsegundos que emite Postgres.

## 6. Estado por fase

| Fase | Estado |
|---|---|
| F.0 Audit | ✅ este documento |
| F.1 API Contract | Ver `MVP2_iOS_Contract.md` + `RuulCore/API/` |
| F.2–F.13 | Slices de UI (un commit por slice) |
| F.14 Full App Flow | Requiere smoke manual en iPhone (founder) — fuera del alcance de CI |
