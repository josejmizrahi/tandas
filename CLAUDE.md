@AGENTS.md

# Tandas — Project Context (iOS native)

App nativa iOS para administrar grupos de amigos. SwiftUI + Supabase. Apple Liquid Glass via iOS 26+.

## Pivotación 2026-04-30

Antes: Next.js 16 PWA (4 phases shipped, 24 routes, 9 migrations).
Ahora: SwiftUI nativo, mismo Supabase backend.

Razón: Liquid Glass real requiere Metal shaders (no disponibles en navegador web). El usuario quería específicamente el material auténtico de iOS, no aproximaciones CSS.

## Stack

- **SwiftUI** (iOS 26+ deployment target — para `.glassEffect()` y demás materiales nuevos)
- **Swift 6** + concurrency strict
- **supabase-swift** SDK
- **Xcode 16+** required
- **Backend**: Supabase project `fpfvlrwcskhgsjuhrjpz` (no cambia)

## Estructura

```
ios/
├── Tandas.xcodeproj/
└── Tandas/
    ├── TandasApp.swift              # @main app entry
    ├── Supabase/                    # Client + AuthService + RPCs typed
    ├── Models/                      # Group, Member, Event, Rule, Vote, Fine
    ├── Features/                    # Per-domain views + viewmodels
    │   ├── Auth/
    │   ├── Groups/
    │   ├── Events/
    │   ├── Rules/
    │   └── Fines/
    ├── Shell/                       # AppShell, BottomNav, GroupHeader
    ├── Components/                  # Reusable UI (Field, OTPInput, etc)
    └── Resources/                   # Assets, Info.plist, entitlements
```

## Reglas

- iOS 26+ deployment target (queremos Liquid Glass real, no caemos a fallback)
- SwiftUI exclusively — nada de UIKit salvo lo que SwiftUI no expone (deeplinks, push handlers)
- Async/await everywhere (no completion handlers)
- @Observable para viewmodels (no ObservableObject)
- Strict concurrency mode on
- Mock Supabase client para previews + tests

## Backend (referencia)

Las 9 migrations en `supabase/migrations/` son la fuente única. La iOS app consume:

| Recurso | Cómo |
|---|---|
| Auth (phone/email OTP) | `supabase.auth.signInWithOtp` + `verifyOtp` |
| Groups CRUD | `from('groups')` + `rpc('create_group_with_admin')` |
| Members | `from('group_members')` + `rpc('join_group_by_code')` |
| Events | `rpc('create_event')` + `rpc('set_rsvp')` + `rpc('check_in_attendee')` + `rpc('close_event')` |
| Rules | `rpc('propose_rule')` + `from('rules').update(...)` para archive/exceptions |
| Votes | `rpc('cast_ballot')` + `rpc('close_vote')` + `rpc('create_vote')` para amnesty |
| Fines | `rpc('pay_fine')` + `rpc('issue_manual_fine')` |

## DoD por commit
- Compila en Xcode 16+ sin warnings
- `xcodebuild test` pasa
- SwiftLint clean (cuando se configure)
- Functional smoke en simulador iOS 26
