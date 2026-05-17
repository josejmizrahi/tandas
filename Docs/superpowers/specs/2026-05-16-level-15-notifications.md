# Nivel 15 — Notifications: devices + preferences + deeplink parity

**Fecha:** 2026-05-16
**Estado:** Brainstorming → spec
**Decisor:** founder (jose.mizrahi@quimibond.com)
**Jerarquía:** `HierarchyReference.md` §1 (Layer 15 — Notification/Delivery)
**Migraciones base:** `00012` (notification_tokens), `00022` (notifications_outbox), `00030` (dispatch cron), `00031` (claim/mark RPCs)

## Problema

Nivel 15 (Notifications) tiene **infra de delivery sólida en BE**:
- `notification_tokens` per-user per-device (mig 00012)
- `notifications_outbox` con dispatch_status, payload, deep_link (mig 00022)
- `dispatch-notifications` cron (1/min, mig 00030) — APNs HTTP/2 con ES256 JWT, collapse-IDs, retry, token cleanup
- `claim_pending_outbox` / `mark_outbox_sent|failed|skipped` RPCs (mig 00031)
- 3-5 notification_type emitted (`voteOpened`, `voteResolved`, `expenseReversed`, `eventCreated`, etc.)

**FE expone solo lo mínimo**:
- Token register on app launch + RSVP permission
- Token revoke on signOut
- Local event reminders (24h/2h/start)
- **Solo `EventDeepLink` routing** funciona — push tap → EventDetailView
- Foreground banner display

**Gaps mayores:**

1. **No hay UI de preferencias por tipo de notificación.** Usuario recibe todas o nada (toggleable solo via iOS Settings global). `notification_preferences` tabla NO existe en BE. Casos: "no quiero notificaciones de votos pero sí de multas".

2. **No hay lista de dispositivos.** `notification_tokens` tiene rows multi-device, pero el FE no las muestra. Usuario no puede revocar token de un iPhone perdido sin contactar soporte.

3. **Deeplink routing solo soporta eventos.** `VoteOpened` / `FineOfficialized` / `RuleChangeApplyPending` van al outbox con deep_link `ruul://vote/{id}` etc., pero el FE solo sabe parse `ruul://event/{id}`. Push tap → app abre en Home en lugar del detalle relevante.

4. **No hay "NOTIFICACIONES" section en MyProfileView.** Sin entry point para preferences/devices/test.

5. **`notification_type` catalog informal** — strings literales en BE. iOS necesita conocer todos los tipos para routing. Sin enum compartido.

6. **Sin visibilidad de fallos** — `dispatch_status='failed'` invisible al usuario. "¿Por qué no llegó el push?" sin respuesta.

7. **Sin quiet hours / DnD scheduled** — Apple Focus modes ayudan pero no respetan el contexto del grupo (e.g., "no me notifiques de este grupo durante el día").

## Objetivo

Cerrar 3 gaps user-facing:

- **Devices list** con revoke per-token (gap #2).
- **Deeplink parity** para vote / fine / rule (gap #3) + `NotificationDeepLink` catalog enum compartido.
- **Notification preferences** per-tipo (gap #1) — BE mig + UI.

Pass 3+ (out of scope): quiet hours, failed notification visibility, group-level mute, notification preview/test, Apple Wallet integration.

## Approach — 3 pasadas, Pass 1+2 en este plan

### Pass 1 · Devices + deeplink parity (4 tasks)

| Archivo | Acción |
|---|---|
| `RuulCore/Repositories/NotificationTokenRepository.swift` | **Modify**. Agregar `listMyDevices() async throws -> [NotificationDevice]` + `revoke(deviceId: UUID) async throws`. Live query `from("notification_tokens").select().eq("user_id", userId)`. |
| `RuulCore/PlatformModels/NotificationDevice.swift` | **NEW** (~50 L). Struct con `id`, `tokenMasked` (first 8 + last 4), `platform`, `createdAt`, `updatedAt`, `isCurrentDevice: Bool`. |
| `RuulCore/Services/Notifications/NotificationDeepLink.swift` | **NEW** (~100 L). Enum unificado: `case event(UUID), vote(UUID), fine(UUID), ruleChange(UUID, proposedAmount: Int?)`. Static `init?(url:)` parses URL scheme. Static `init?(userInfo:)` from push payload. |
| `Features/Profile/Subscreens/DevicesView.swift` + wire | **NEW** (~180 L). Lista dispositivos con "Este iPhone" badge + "Revocar sesión" button per-row destructive. Wire from `MyProfileView` new "NOTIFICACIONES" section navrow. Update `AppState.handleIncomingURL` / `handleIncomingNotification` to use `NotificationDeepLink` catalog. |

### Pass 2 · Notification preferences (3 tasks)

| Archivo | Acción |
|---|---|
| `supabase/migrations/00XXX_notification_preferences.sql` | **NEW**. Tabla `notification_preferences(user_id, notification_type, enabled, updated_at)` con PK composite + RLS self-only. Helper RPC `set_notification_preference(p_type, p_enabled)` que upserts. Helper view `effective_notification_preferences` que retorna defaults para tipos no opt-out'd. |
| `RuulCore/Repositories/NotificationPreferenceRepository.swift` | **NEW** (~120 L). `loadMyPreferences() async throws -> [NotificationPreference]` + `set(type:, enabled:) async throws`. |
| `Features/Profile/Subscreens/NotificationPreferencesView.swift` + wire | **NEW** (~200 L). Lista los ~5 tipos de notificación con toggle per-row. Defaults ON salvo opt-out. Wire from `MyProfileView` NOTIFICACIONES section. |

### Pass 3 (deferred): quiet hours, failed visibility, group-level mute, Apple Wallet

## Wireframe `MyProfileView` con NOTIFICACIONES section

```
├─ NOTIFICACIONES ────────────────────────┤  ← NEW
│  🔔 Preferencias                      →  │  → NotificationPreferencesView
│  📱 Dispositivos                  3   →  │  → DevicesView
├─────────────────────────────────────────┤
```

## Wireframe `DevicesView`

```
┌─────────────────────────────────────────┐
│  ⟵     Dispositivos                     │
│  ─────────────────────────────────────  │
│  ESTA SESIÓN                             │
│  📱 iPhone (este)                        │
│      Registrado hace 12 días             │
│                                          │
│  OTRAS SESIONES                          │
│  📱 iPhone 14                            │
│      Último uso hace 5 días              │
│      [Revocar sesión]                    │
│  📱 iPad                                 │
│      Último uso hace 1 mes               │
│      [Revocar sesión]                    │
└─────────────────────────────────────────┘
```

## Wireframe `NotificationPreferencesView`

```
┌─────────────────────────────────────────┐
│  ⟵     Notificaciones                   │
│  ─────────────────────────────────────  │
│  Activa o desactiva tipos de aviso.      │
│                                          │
│  🗳️  Votaciones                  ⬤───  │
│  💸  Multas                       ⬤───  │
│  📅  Eventos nuevos               ⬤───  │
│  ⏰  Recordatorios de RSVP        ⬤───  │
│  ✅  Resultados de voto           ⬤───  │
└─────────────────────────────────────────┘
```

## Decisiones explícitas

1. **`NotificationDeepLink` enum como catalog compartido.** Acaba con strings literales dispersos. Server emite `deep_link` con scheme `ruul://[kind]/[id]`; iOS parsea via enum init.

2. **Devices list muestra masked token (first 8 + last 4).** No revelar token entero — security.

3. **"Este iPhone" detection**: comparar token actual cached en UserDefaults (después de register) vs cada row del repo.

4. **Notification preferences default = ON.** Opt-out model (no opt-in). Tipo nuevo agregado → users lo reciben por default; pueden disable.

5. **Sin per-group preferences en V1.** "Mute todo este grupo" es Pass 3+. V1 es global per-user.

6. **Sin quiet hours en V1.** Apple Focus modes cubren el caso V1. Pass 3 podría agregar in-app schedule.

7. **`dispatch-notifications` cron debe respetar preferences** — agregar JOIN con `notification_preferences` en el claim query (parte de Pass 2 mig).

## Riesgos

| Riesgo | Mitigación |
|---|---|
| `NotificationDeepLink` parse falla para URLs malformadas del push | Retornar nil + log; app abre Home como fallback |
| Token cleanup post-revoke deja inconsistencia entre token cache local y DB | DevicesView siempre re-fetcha; UserDefaults cache solo para "this device" check |
| Preferences default ON puede causar push spam para tipos nuevos | Aceptable — better que silent opt-in |
| Mig `notification_preferences` requiere coordinación con dispatch cron | Ambos changes en mismo PR; cron query agrega LEFT JOIN |
| Revoke other device's token mientras está en uso → ese device sigue recibiendo hasta refresh | APNs returns 410 Gone post-revoke (mig 00031 limpia); 5-10 min de lag aceptable |

## Tests

| Pass | Tests críticos |
|---|---|
| 1 | `NotificationTokenRepository.listMyDevices`: returns ≥1. `NotificationDeepLink`: parses 4 schemes (event/vote/fine/rule). `DevicesView`: "este iPhone" highlight + revoke destructive |
| 2 | `notification_preferences` mig deployable. `NotificationPreferenceRepository.set`: upsert idempotente. `NotificationPreferencesView`: toggle ON/OFF persiste |

## Out of scope (futuros specs)

- Pass 3 — quiet hours / DnD per-group / failed notification visibility / Apple Wallet
- Notification test ("send me a test push")
- Notification history (resolved/dismissed log)
- Smart notification grouping (collapse 5 similar en uno)
- Server-side filtering by user timezone (envíar a 8am local time)
- WebPush / Android tokens (V1 iOS-only)
- Multi-channel (email, SMS) fallback

## Done When

- 7 tasks committed (4 Pass 1 + 3 Pass 2).
- "NOTIFICACIONES" section visible en MyProfileView.
- DevicesView lista tokens del usuario + revoke funciona.
- 4 deeplink schemes routean correctamente.
- Notification preferences UI permite toggle per-tipo + persiste en BE.
- `dispatch-notifications` cron respeta preferences (no envía si user opted-out).
- Build clean.
- Two tags: `level15-pass1-complete`, `level15-pass2-complete`.

## Cobertura del plan inicial

**Pass 1 + Pass 2 en el primer commit** (~7 tasks, 1 migración pequeña).
