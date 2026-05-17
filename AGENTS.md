# Tandas / Ruul — Project Context (iOS native)

App nativa iOS para administrar grupos de amigos. SwiftUI + Supabase.
Liquid Glass real (no fallback CSS) gracias a iOS 26+.

This file is the **canonical, agent-neutral source of truth**. Tool-specific
overlays (CLAUDE.md, .cursorrules, etc.) `@`-import it.

## Pivotación 2026-04-30

Antes: Next.js 16 PWA (4 phases shipped, 24 routes, 9 migrations).
Ahora: SwiftUI nativo, mismo Supabase backend.

Razón: Liquid Glass real requiere Metal shaders (no disponibles en
navegador web). El usuario quería específicamente el material auténtico
de iOS, no aproximaciones CSS.

## Stack

- **SwiftUI** (iOS 26+ deployment target — `.glassEffect()` y materiales nuevos)
- **Swift 6** + concurrency strict
- **supabase-swift** SDK
- **Xcode 16+** required
- **Backend**: Supabase project `fpfvlrwcskhgsjuhrjpz`

## Arquitectura objetivo

```
Template → Group → Resource → Rule → Vote → Fine → History
```

- **Group** = comunidad persistente (no se subdivide por verticales).
- **Template** = preset inicial — solo arranca el grupo, no es cárcel.
- **Modules** = capacidades activables (`basic_fines`, `rotating_host`,
  `rsvp`, `check_in`, `appeal_voting`; futuros `slot_assignment`,
  `common_fund`, etc.). Server-side `public.modules` (mig 00060) es la
  fuente canónica; `V1Modules.swift` queda solo como fallback offline.
- **Resources** = objetos gobernables polimórficos vía
  `resources.resource_type`. Tipos vivos hoy: `event`, `slot`, `asset`,
  `space`, `fund`, `right` (6 tipos creables desde la wizard).
- **Rules** = WHEN/IF/THEN data en jsonb. Engine server-only
  (`supabase/functions/_shared/ruleEngine.ts`).
- **Votes / Fines / History** = polimórficos por `reference_id` /
  `resource_id` / `event_type`.
- **Atoms vs Projections** = marker protocol explícito en código
  (`AtomProjection.swift`). Atoms son append-only (`system_events`,
  `vote_ballots`, `ledger_entries`, `rsvp_actions`); projections son
  estado derivado (`event_lifecycle_view`, `fund_balance_view`,
  `my_activity_v1`, etc.).

Un mismo grupo puede combinar varios módulos y tipos de resource al mismo tiempo.

## Estructura del repo

```
ios/
├── Tandas.xcodeproj/                # xcodegen-driven
├── Tandas/                          # @main entry, Shell, AppState wiring
│   ├── TandasApp.swift              # Live vs Mock factory por env var
│   ├── Shell/                       # AuthGate
│   ├── DesignSystem/  Platform/  Resources/
├── TandasTests/                     # Tests viven aquí (no en SPM packages)
└── Packages/
    ├── RuulCore/                    # Modelos + Repositories + Servicios + Templates
    │   └── Sources/RuulCore/
    │       ├── AppState.swift       # Glue principal (~35 repos + servicios)
    │       ├── Group.swift          # base_template, active_modules, governance jsonb
    │       ├── PlatformModels/      # 50+ tipos (Resource, Fine, Vote, Rule, Template, GroupModule…)
    │       │   ├── AtomProjection.swift   # marker protocol Atom / Projection
    │       │   └── Generated/             # Codegen Swift↔TS (Codable extensions)
    │       ├── PlatformModules/     # ModuleRegistry, LiveModuleRegistry, V1Modules (fallback)
    │       ├── PlatformServices/    # GovernanceService, SystemEventEmitter
    │       ├── Capabilities/        # ResourceBuilders + CapabilityResolver
    │       ├── Templates/           # TemplateRegistry, DinnerRecurringTemplate
    │       ├── Repositories/        # Mock + Live de 36 repos
    │       └── Supabase/            # SupabaseClient, AuthService
    ├── RuulUI/                      # DesignSystem v3 (tokens, primitives, patterns, templates)
    └── RuulFeatures/                # Feature views + coordinators (per-domain)
        └── Sources/RuulFeatures/Features/
            ├── Auth/  Onboarding/  Groups/  Group/  Members/
            ├── Home/  Inbox/  Activity/  Profile/  Create/  Feed/
            ├── Resources/  Rules/  Fines/  Votes/  Shell/

supabase/
├── migrations/                      # 232 forward migrations (00001 → 00232)
└── functions/                       # 17 edge functions + _shared/ + _tests/
    ├── _shared/ruleEngine.ts        # determinístico, server-only, phase_target mapping + scope hierarchy
    ├── process-system-events/       # cron 1/min — orquestador del rule engine
    ├── dispatch-notifications/      # cron 1/min — APNs outbox
    ├── auto-close-events/  auto-generate-events/
    ├── emit-deadline-events/  emit-event-reminder-events/  emit-event-started-atoms/
    ├── emit-slot-system-events/  emit-asset-overdue-events/
    ├── finalize-votes/  finalize-fine-reviews/
    ├── send-event-notification/  send-fine-reminders/
    ├── send-otp/  verify-otp/  send-whatsapp-invite/
    └── generate-wallet-pass/
```

## Reglas

- iOS 26+ deployment target (Liquid Glass real, sin fallback)
- SwiftUI exclusively — UIKit solo para deeplinks/push handlers
- Async/await everywhere
- `@Observable` para viewmodels
- Strict concurrency mode on
- Mock + Live de cada repositorio para previews + tests
- Codegen Swift↔TS enforced via Lefthook (`scripts/codegen/`)
- Cambios al schema: revisar SQL primero, luego aplicar vía
  `mcp__supabase__apply_migration` (jamás escribir en producción sin
  review previo). Convención de numeración monotónica `NNNNN_*.sql`
  sin colisiones (auditar si dos PRs paralelos eligen el mismo número).

## Backend (referencia)

232 forward migrations en `supabase/migrations/` son la fuente única.
La iOS app consume:

| Recurso | Cómo |
|---|---|
| Auth (phone/email OTP) | `supabase.auth.signInWithOtp` + `verifyOtp`; anon→phone upgrade es automático en Supabase (verifyOtp promueve un `is_anonymous` user al teléfono verificado y dispara el trigger `on_auth_user_phone_sync` para mirror a `profiles.phone`) |
| Groups CRUD | `from('groups')` + `rpc('create_group_with_admin')` (lee `templates.config`) |
| Members | `from('group_members')` + `rpc('join_group_by_code')` + `rpc('set_turn_order')` + `rpc('remove_member')` |
| Events | `rpc('create_event_v2')` + `rpc('set_rsvp_v2')` + `rpc('check_in_attendee')` + `rpc('close_event')` (trigger 00039 dual-write a `resources`; v2 post-bigbang mig 00080) |
| Resources | `LiveResourceRepository` lee `from('resources')` polimórficamente; writes vía `rpc('build_resource_from_draft')` (mig 00101) que enruta a `create_event/asset/slot/fund/right/space` |
| Rules | `rpc('create_initial_rule')` (platform-only post-mig 00058) + `rpc('seed_template_rules')` (generic, post-mig 00062) + `from('rules').update(...)` para toggle is_active |
| Votes | `rpc('start_vote')` + `rpc('cast_vote')` + `rpc('finalize_vote')` + `rpc('cancel_vote')` (mig 00222); polimórfico via `vote_type` + `reference_id` |
| Fines | `rpc('issue_manual_fine')` + `rpc('pay_fine')` + `rpc('void_fine')` + `rpc('start_appeal')`; columnas legacy (`status`, `paid_at`, etc.) eliminadas mig 00151, estado deriva de atoms |
| Notifications | `notifications_outbox` table + cron `dispatch-notifications-every-minute` (APNs real); preferencias per-user per-type via `notification_preferences` (mig 00232) |
| System events | `system_events` table append-only + `record_system_event` SECURITY DEFINER |
| Templates | `from('templates')` + `rpc('seed_template_rules')` (lee `templates.config.defaultRules`) |
| Modules | `from('modules')` + `rpc('list_modules')` + `rpc('set_group_module')` (cascade dynamic post-mig 00061) |
| Roles + Permissions | `from('groups').roles` jsonb (mig 00063) + `group_members.roles` jsonb array (multi-role, mig 00228) + `rpc('has_permission')` (UNION across roles) + `rpc('assign_role'/'unassign_role'/'upsert_group_role'/'delete_group_role')` |
| Governance | `from('groups').update({governance})` gated by `groups_update_governance` RLS |
| Ledger | `record_ledger_entry` RPC + `fund_balance_view` projection + `record_settlement` RPC (mig 00220) |
| Activity | `my_activity_v1` projection view (mig 00224) — feed cross-group de actividad del usuario |

### Crones activos (pg_cron)

- `dispatch-notifications` — 1/min — outbox → APNs
- `process-system-events` — 1/min — motor de reglas
- `emit-event-reminder-events` — 5/min — rule-driven (lee `hoursBeforeEvent`)
- `emit-event-started-atoms` — 5/min — lifecycle atom (mig 00214)
- `emit-deadline-events` — 5/min — rsvpDeadlinePassed (mig 00129)
- `emit-slot-system-events` — 5/min — slotExpired + status update
- `emit-asset-overdue-events` — 5/min — checkout/maintenance overdue
- `finalize-votes` — 5/min — cierre + voteResolved
- `auto-close-events` — 1/h — backstop legacy
- `auto-generate-events` — 1/2h — series → create_event_v2
- `expire-due-rights` — 1/h — mig 00199
- `notify-rights-expiring-soon` — 1/día — mig 00206
- `resolve-stale-fine-voided` — 1/día — mig 00142
- `reset-stale-outbox` — 5/min — janitor (mig 00160)
- `fail-stale-data-rights` — 5/min — janitor (mig 00172)

## Estado al 2026-05-17

- **Beta 1 Consolidation** en curso (ver `Plans/Active/Beta1Consolidation.md`):
  no feature work, solo polish/reliability/copy. Vertical oficial:
  cenas recurrentes con rotación. Phase 2 diferida hasta decisión
  founder post-journal cenas.
- **Vision + Constitution** canónicas (`Plans/Active/Vision.md` 2026-05-14
  y `Plans/Active/Constitution.md` 2026-05-13). Tesis: 2 primitivas
  (Group + Resource polimórfico), acto > estado, obligaciones derivadas.
- **Roles v2** vivo (mig 00228-00230): `has_permission()` lee jsonb
  array, multi-rol UNION. `group_members.role` text marcado deprecado
  (mig 00106) pero aún consultado como fallback.
- **6 resource types creables** desde la wizard: event, slot, asset,
  space, fund, right. Cada uno con `ResourceBuilder` propio.
- **RootShell + 5 tabs** (Home, Inbox, Create, Activity, Profile)
  reemplazó a la `MainTabView` legacy (struct ya eliminada; quedan
  comentarios stale por limpiar).
- **L1 primitives todas verdes** FE+BE post-Gaps 1-4: Identity, Membership,
  Group, Template, ModuleRegistry, CapabilityResolver, Resource, Rule,
  SystemEvent, RoleStack (foundation slice).

## DoD por commit

- Compila en Xcode 16+ sin warnings
- `xcodebuild test` pasa (Swift Testing en `ios/TandasTests/`)
- Codegen sin diff (lefthook lo enforces; CI también)
- Functional smoke en simulador iOS 26 (o device si toca push)
- Migrations aplicadas vía MCP `mcp__supabase__apply_migration` (con review SQL antes)
