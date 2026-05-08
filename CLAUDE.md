@AGENTS.md

# Tandas / Ruul — Project Context (iOS native)

App nativa iOS para administrar grupos de amigos. SwiftUI + Supabase.
Liquid Glass real (no fallback CSS) gracias a iOS 26+.

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
  `common_fund`, etc.).
- **Resources** = objetos gobernables (`event` hoy; `slot`, `fund`,
  `position`, `asset` en fases siguientes). Polimórficos via
  `resources.resource_type`.
- **Rules** = WHEN/IF/THEN data en jsonb. Engine server-only.
- **Votes / Fines / History** = polimórficos por `reference_id` /
  `resource_id` / `event_type`.

Un mismo grupo puede combinar varios módulos y tipos de resource al mismo tiempo.

## Estructura del repo

```
ios/
├── Tandas.xcodeproj/                # xcodegen-driven
└── Packages/
    ├── RuulCore/                    # Modelos + Repositories + Servicios + Templates
    │   └── Sources/RuulCore/
    │       ├── Group.swift          # base_template, active_modules, governance jsonb
    │       ├── PlatformModels/      # Resource, Fine, Vote, Rule, Template, GroupModule
    │       ├── PlatformModules/     # ModuleRegistry, V1Modules
    │       ├── Templates/           # TemplateRegistry, DinnerRecurringTemplate
    │       ├── Repositories/        # Mock + Live (Groups, Events, Resources, Fines, …)
    │       └── Supabase/            # SupabaseClient, AuthService, RPC bindings
    ├── RuulUI/                      # DesignSystem v3 (tokens, primitives, patterns)
    └── RuulFeatures/                # Feature views + coordinators (per-domain)
        └── Sources/RuulFeatures/Features/
            ├── Auth/  Onboarding/  Groups/  Events/  Rules/
            ├── Fines/ Votes/  Resources/  Inbox/  History/  Settings/
└── Tandas/                          # @main entry, Shell, AppState wiring

supabase/
├── migrations/                      # 43 forward migrations (00001-00042)
└── functions/                       # Edge functions
    ├── _shared/ruleEngine.ts        # determinístico, server-only, phase_target mapping
    ├── process-system-events/       # cron orquestador del rule engine
    ├── evaluate-event-rules/        # legacy V1 pipeline (event-anchored)
    ├── dispatch-notifications/      # APNs outbox (cron 1/min)
    └── send-event-notification/, finalize-votes/, finalize-fine-reviews/, …
```

## Reglas

- iOS 26+ deployment target (Liquid Glass real, sin fallback)
- SwiftUI exclusively — UIKit solo para deeplinks/push handlers
- Async/await everywhere
- `@Observable` para viewmodels
- Strict concurrency mode on
- Mock + Live de cada repositorio para previews + tests
- Codegen Swift↔TS enforced via Lefthook (`scripts/codegen/`)

## Backend (referencia)

43 migrations forward (`supabase/migrations/`) son la fuente única.
La iOS app consume:

| Recurso | Cómo |
|---|---|
| Auth (phone/email OTP) | `supabase.auth.signInWithOtp` + `verifyOtp`; anon→phone upgrade vía `link_anon_user` |
| Groups CRUD | `from('groups')` + `rpc('create_group_with_admin')` (lee `templates.config`) |
| Members | `from('group_members')` + `rpc('join_group_by_code')` + `rpc('set_turn_order')` + `rpc('remove_member')` |
| Events | `rpc('create_event')` + `rpc('set_rsvp')` + `rpc('check_in_attendee')` + `rpc('close_event')` (trigger 00039 dual-write a `resources`) |
| Resources | `LiveResourceRepository` lee `from('resources')` polimórficamente |
| Rules | `rpc('propose_rule')` + `rpc('seed_dinner_template_rules')` + `from('rules').update(...)` para archive/exceptions |
| Votes | `rpc('start_vote')` + `rpc('cast_vote')` + `rpc('finalize_vote')` (polimórfico via `vote_type` + `reference_id`) |
| Fines | `rpc('issue_manual_fine')` + `rpc('pay_fine')` + `rpc('void_fine')` + `rpc('start_appeal')` |
| Notifications | `notifications_outbox` table + cron `dispatch-notifications-every-minute` (APNs real) |
| System events | `system_events` table append-only + `record_system_event` SECURITY DEFINER |
| Templates | `from('templates')` + seed migrations 00021/00034/00037/00038 |
| Governance | `from('groups').update({governance})` gated by `groups_update_admin` RLS |

## Estado al 2026-05-08

- F0 (Fundación) cerrado al 100% — ver `Plans/Active/Audit-2026-05-06.md`.
- Beta 1 freeze activo — ver `Plans/Active/Beta1.md`. Architectural changes
  off-limits salvo bug fixes críticos.
- Pre-Phase 2 sprint en curso (cleanup + close-out + capability layer).
- Phase 2 primitive (Slot/Rotation/Fund/Asset) decidida por journal de cenas.

## DoD por commit

- Compila en Xcode 16+ sin warnings
- `xcodebuild test` pasa (Swift Testing en RuulCore + RuulFeatures)
- Codegen sin diff (lefthook lo enforces; CI también)
- Functional smoke en simulador iOS 26 (o device si toca push)
- Migrations aplicadas vía MCP `mcp__supabase__apply_migration` (con review SQL antes)
