# Tandas iOS — Phase 1 Design

**Date:** 2026-04-30
**Status:** Pending review (post-brainstorming).
**Supersedes:** Las decisiones del spec hermano `2026-04-30-tandas-ios-swiftui-liquid-glass-design.md` que entran en conflicto con éste — específicamente: scope MVP, deployment target, repo layout y métodos de auth. El sistema visual y los riesgos del spec hermano siguen vigentes.
**Repo:** `josejmizrahi/tandas`, branch `ios-rewrite`.

---

## 1. Overview

Phase 1 de la app nativa iOS de Tandas. Cubre **el flujo end-to-end de onboarding y vida cero** de un usuario: autenticarse, configurar su perfil, y entrar a su primer grupo (ya sea creándolo o uniéndose con código). Cierra cuando el usuario ve su lista de grupos y puede abrir el resumen del grupo recién creado/unido para compartir el invite code.

Las phases siguientes (eventos/RSVP, reglas/votos, multas/SPEI, anti-tirania) construyen encima sin cambiar el armazón establecido aquí.

La web Next.js existente (`web-deprecated/`) **se elimina** del repo como parte de Phase 1 — no es referencia operativa, ya quedó en git history.

## 2. Decisions Log

| # | Pregunta | Decisión | Razón |
|---|---|---|---|
| 1 | Scope Phase 1 | Auth + onboarding + crear grupo + joinear + welcome + lista de grupos + group summary placeholder. **Full parity con la web**, no read-only. | "Todo desde cero para Liquid Glass" — el usuario rehace la experiencia entera en iOS. |
| 2 | Deployment target | iOS 26.0 firme, sin fallback `.ultraThinMaterial`. | Liquid Glass real es la razón del pivot; cualquier branching `if #available(iOS 26, *)` se elimina. |
| 3 | Auth methods | Sign in with Apple primario + Phone OTP + Email OTP. | SiwA cumple Apple HIG y es la fricción más baja; OTPs reusan cuentas existentes y son fallback obligado. |
| 4 | Account linking SiwA ↔ phone preexistente | **Diferido** a phase posterior. | Pocos usuarios reales hoy; RPC merge es ~1 semana de trabajo y bloquea Phase 1 sin justificación. |
| 5 | Repo layout | `tandas/ios/Tandas/...` (no monorepo `apps/ios/`). | El `CLAUDE.md` actualizado lo declara y reduce indirection. |
| 6 | Scaffold de Xcode | `xcodegen` con `project.yml` declarativo. `Tandas.xcodeproj` queda en `.gitignore`. | Estándar de facto en iOS open source serio; me permite agregar `.swift` con `Write` y que el target los recoja sin Xcode UI. |
| 7 | Apple Developer team | Cuenta personal del usuario (no Quimibond). Bundle id tentativo `com.josejmizrahi.tandas`. | Decisión del usuario. Team ID exacto se confirma al configurar signing en xcodegen. |
| 8 | Estado UI tap en grupo | Phase 1 cierra abriendo `GroupSummaryView` minimal (nombre + miembros + invite code copiable + salir). | Demoable end-to-end (crear grupo → compartir code → otro entra). Phase 2 enchufa timeline aquí. |
| 9 | `web-deprecated/` | Eliminar del repo como parte de Phase 1. | Pivot ya cerrado, queda en git history; el directorio pesa y confunde. |
| 10 | Migration nueva | `00010_add_group_type_to_create_rpc.sql` actualiza `create_group_with_admin` para aceptar `p_group_type`. | El RPC de migration `00003` no toma `group_type`, pero `00009` agregó la columna. Cerrar el gap. |
| 11 | Identidad visual | Heredada del spec hermano: dark only, MeshGradient, GlassCard, SF Pro Rounded para montos. | Ya validada y suficientemente detallada; sólo se simplifica el modifier `adaptiveGlass` quitando el branch de fallback. |
| 12 | Idioma | es-MX único | Mismo mercado que la web. |

## 3. Architecture

### Stack

| Capa | Tecnología |
|---|---|
| UI | SwiftUI 6, iOS 26.0 deployment |
| State | `@Observable` macro + `@Environment` para DI |
| Concurrency | Swift 6 strict concurrency on |
| Data | `supabase-swift` (Auth + PostgrestClient + Realtime — Realtime no se usa en Phase 1) |
| Persistencia local | Sólo Keychain (vía Supabase SDK) |
| Auth | `AuthenticationServices` para SiwA + Supabase Auth (`signInWithIdToken(.apple, …)`, `signInWithOTP(phone:)`, `signInWithOTP(email:)`) |
| Tests | Swift Testing (`@Test`), swift-snapshot-testing, XCUITest |
| Build | xcodegen → Xcode 16+ → `xcodebuild` |
| CI | GitHub Actions macos-15 + iPhone 15 Pro simulator |
| Distribución | TestFlight build #1 al cerrar Phase 1; sin App Store submission todavía |

### Repo layout

```
tandas/
├── ios/
│   ├── project.yml                      ← xcodegen
│   ├── Tandas.xcodeproj                 ← .gitignore (regenerable)
│   ├── Makefile                         ← `make project` → xcodegen
│   ├── Tandas/
│   │   ├── TandasApp.swift              ← @main, RootScreen, AuthGate
│   │   ├── Supabase/
│   │   │   ├── SupabaseClient.swift
│   │   │   ├── AuthService.swift        ← protocol + LiveAuthService + MockAuthService
│   │   │   └── Repos/
│   │   │       ├── ProfileRepository.swift
│   │   │       └── GroupsRepository.swift
│   │   ├── Models/
│   │   │   ├── Profile.swift
│   │   │   ├── Group.swift
│   │   │   ├── Member.swift
│   │   │   └── (Event/Rule/Vote/Fine — stubs Codable, no hace falta full schema)
│   │   ├── Features/
│   │   │   ├── Auth/
│   │   │   │   ├── LoginView.swift
│   │   │   │   ├── OTPInputView.swift
│   │   │   │   ├── OnboardingView.swift
│   │   │   │   └── AuthViewModel.swift
│   │   │   ├── Groups/
│   │   │   │   ├── EmptyGroupsView.swift
│   │   │   │   ├── GroupsListView.swift
│   │   │   │   ├── JoinByCodeView.swift
│   │   │   │   ├── NewGroupWizard.swift
│   │   │   │   ├── WelcomeView.swift
│   │   │   │   ├── GroupSummaryView.swift
│   │   │   │   └── GroupsViewModel.swift
│   │   │   ├── Events/, Rules/, Fines/  ← stubs vacíos para phases siguientes
│   │   │   └── Profile/                 ← (Phase 1 sólo display_name, sin pantalla dedicada)
│   │   ├── Shell/
│   │   │   └── AppShell.swift           ← root TabView stub (Phase 1 single tab)
│   │   ├── DesignSystem/
│   │   │   ├── Tokens.swift
│   │   │   ├── Typography.swift
│   │   │   ├── AdaptiveGlass.swift
│   │   │   ├── MeshBackground.swift
│   │   │   └── Components/
│   │   │       ├── GlassCard.swift
│   │   │       ├── GlassCapsuleButton.swift
│   │   │       ├── OTPInput.swift
│   │   │       ├── Field.swift
│   │   │       ├── TypologyCard.swift
│   │   │       ├── WalletGroupCard.swift
│   │   │       └── WelcomeStepCard.swift
│   │   └── Resources/
│   │       ├── Assets.xcassets
│   │       ├── Info.plist
│   │       └── Tandas.entitlements
│   ├── TandasTests/                     ← unit + snapshot
│   └── TandasUITests/                   ← XCUITest
├── supabase/
│   └── migrations/
│       └── 00010_add_group_type_to_create_rpc.sql ← NUEVO
├── docs/superpowers/specs/              ← este archivo + el spec hermano
└── (web-deprecated/ ← eliminado en Phase 1)
```

### Boundaries

- `Features/A` no importa de `Features/B`. Compartido sube a `DesignSystem/` o `Supabase/`.
- `DesignSystem/` y `Supabase/` no importan de `Features/`.
- Repos en `Supabase/Repos/` son `actor` con protocol equivalente para mocking.
- ViewModels (`@Observable`) son `internal` a su feature.

### Data flow

```
SwiftUI View
    │ lee state
    ▼
@Observable ViewModel  (state: ViewState<T>)
    │ llama
    ▼
Repository (actor, protocol)
    │ usa
    ▼
SupabaseClient (singleton @Environment)
    │ HTTP REST + JWT
    ▼
Supabase Postgres + RLS + RPCs (security definer)
```

**Cero lógica de negocio en el cliente Swift** — todas las mutaciones llaman RPCs ya existentes (`create_group_with_admin`, `join_group_by_code`) o RPCs nuevos en Phase 1 (ninguno por ahora; la migration `00010` sólo amplía firma del existente).

### Auth flow

```
TandasApp
  └─ AuthGate observa AuthService.sessionStream
       ├─ session == nil
       │     └─ LoginView
       │          ├─ "Continuar con Apple" → ASAuthorizationController
       │          │                            → identityToken JWT
       │          │                            → client.auth.signInWithIdToken(.apple, …)
       │          │                            → session
       │          ├─ tab "Phone" → input phone (+52 default) → sendPhoneOTP → OTPInputView
       │          │                                                         → verifyPhoneOTP
       │          │                                                         → session
       │          └─ tab "Email" → input email             → sendEmailOTP → OTPInputView
       │                                                                  → verifyEmailOTP
       │                                                                  → session
       └─ session != nil
             ├─ profile.display_name == ''  → OnboardingView (input display_name)
             └─ profile.display_name != ''
                  ├─ my_groups.empty       → EmptyGroupsView (CTA crear o joinear)
                  └─ my_groups.any         → GroupsListView
```

Sesión persiste en Keychain via Supabase SDK. `AuthService` escucha `client.auth.authStateChanges` y publica `Session?` por `AsyncStream`.

### Errors

| Caso | Tratamiento |
|---|---|
| Red offline | Empty state con retry button + ícono SF Symbol `wifi.slash` |
| 401 (token expired) | `signOut()` automático + toast "Tu sesión expiró" → vuelve a `LoginView` |
| 403 (RLS) | Empty state "No tienes acceso a esto" |
| 5xx | Toast con retry |
| Decoding error | Log + toast genérico — indica drift de schema, flag para dev |
| OTP 6 dígitos incorrectos | Field error inline + animación shake del row |
| Apple Sign-in cancelado por el usuario | Sin error, vuelve al `LoginView` |
| `invite_code` inexistente | Field error inline rojo |
| `display_name` vacío | Submit deshabilitado |
| RPC `create_group_with_admin` falla | Toast con retry, wizard mantiene estado del paso |

## 4. Visual System

Hereda completo del spec hermano (`2026-04-30-tandas-ios-swiftui-liquid-glass-design.md` sección 4). Único delta:

### `.adaptiveGlass(...)` simplificado (sin fallback)

```swift
extension View {
    @ViewBuilder
    func adaptiveGlass<S: Shape>(
        _ shape: S,
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        let style: GlassEffect = {
            let base: GlassEffect = tint.map { .tinted($0) } ?? .regular
            return interactive ? base.interactive() : base
        }()
        self.glassEffect(style, in: shape)
    }
}
```

`accessibilityReduceTransparency` se honra dentro del modifier (cae a `Color(.secondarySystemBackground)` opaco).

### Tokens (`DesignSystem/Tokens.swift`)

| Categoría | Valores |
|---|---|
| Brand | `accent` (lavanda), `accent2` (rosa), `accent3` (cyan) |
| Mesh | 4 colores oscuros saturados para `MeshGradient` 3×3 |
| Group palette | 12 colores brand-friendly para tarjetas Wallet, hash determinista por `group.id` |
| Status | `statusEvent` verde, `statusFine` amarillo, `statusVote` cyan, `statusTurn` morado |
| Radii | `card 22`, `pill 999`, `chip 14`, `field 18` |
| Spacing | `xs 4`, `s 8`, `m 12`, `l 16`, `xl 24`, `2xl 32` |

### Tipografía

- **SF Pro Rounded** — montos (`tandaAmount 24pt bold rounded monospacedDigit`), headers (`tandaHero 28pt bold rounded`).
- **SF Pro** — body (`tandaTitle 18pt semibold`, `tandaBody 15pt regular`, `tandaCaption 11pt medium monospacedDigit`).
- `.monospacedDigit()` obligatorio en dinero, fechas tabulares, OTP slots.

### Componentes Phase 1

| Componente | Usado en |
|---|---|
| `MeshBackground` | LoginView, EmptyGroupsView, GroupsListView, WelcomeView |
| `GlassCard<Content>` | Casi todas las pantallas |
| `GlassCapsuleButton` | CTAs primarias |
| `OTPInput` (6 slots) | OTPInputView |
| `Field` + `FieldLabel` + `FieldDescription` | Forms (paridad con shadcn `field.tsx`) |
| `TypologyCard` | NewGroupWizard paso 1 |
| `WalletGroupCard` | GroupsListView |
| `WelcomeStepCard` | WelcomeView |

### Accesibilidad obligatoria

- `accessibilityReduceTransparency` → glass cae a opaco
- `accessibilityReduceMotion` → MeshBackground no anima; transitions `.identity`
- `colorSchemeContrast == .increased` → border alpha 0.12 → 0.45
- VoiceOver labels en cada `GlassCard` interactivo (`.accessibilityLabel`, `.accessibilityHint`)
- Dynamic Type — todas las fonts via `.system(...)`, sin frames hardcoded

### Haptics

| Trigger | Tipo |
|---|---|
| Cambio tab Phone↔Email, tap TypologyCard | `.selection` |
| Tap WalletGroupCard, botón principal | `.impact(.medium)` |
| OTP correcto, grupo creado, joinear éxito | `.success` (post-respuesta del servidor) |
| OTP incorrecto, RPC falla | `.error` |

## 5. Phase 1 Screens

### Mapa de pantallas (9)

| # | Pantalla | Cuándo aparece | Datos / acción |
|---|---|---|---|
| 1 | `LoginView` | session == nil | botón SiwA + tabs Phone\|Email |
| 2 | `OTPInputView` (param phone\|email) | tras pedir código | 6 slots, auto-submit, resend cooldown 30s |
| 3 | `OnboardingView` | session ≠ nil ∧ `profile.display_name == ''` | input `display_name` + botón "Continuar" |
| 4 | `EmptyGroupsView` | profile completo ∧ `my_groups.empty` | dos CTAs glass: "Crear grupo" / "Unirme con código" |
| 5 | `JoinByCodeView` | tap "Unirme con código" | input 8 chars + RPC `join_group_by_code` |
| 6 | `NewGroupWizard` | tap "Crear grupo" | 3 pasos: tipología → identidad → defaults de evento |
| 7 | `WelcomeView` | post-join o post-create | hero del grupo + grace period card + reglas + miembros |
| 8 | `GroupsListView` | profile completo ∧ `my_groups.any` | cards Wallet glass tinted, color por hash de `id` |
| 9 | `GroupSummaryView` | tap en `WalletGroupCard` | nombre + miembros + `invite_code` copiable + "Salir del grupo" |

### `LoginView` detallado

- `MeshBackground` + logo SF Pro Rounded "Tandas".
- Botón primario `SignInWithAppleButton` (Apple-supplied, glass automático).
- Separador `O` con `FieldSeparator` glass.
- Picker segmented glass `Phone | Email` dentro de un `GlassCard`.
- Phone: input con `+52` prefijo default, `keyboardType: .phonePad`.
- Email: input con `keyboardType: .emailAddress`, `autocapitalization: .never`.
- Botón "Enviarme código" → push a `OTPInputView`.

### `OTPInputView` detallado

- Componente único parametrizado por `Channel` (`.phone(String)` / `.email(String)`).
- 6 slots glass capsule, `textContentType: .oneTimeCode` (iOS lee SMS automático).
- Auto-submit al completar 6 dígitos.
- Resend cooldown 30s con countdown visible.
- Back link "Cambiar [phone|email]".

### `OnboardingView` detallado

- Hero: "¿Cómo te llaman?" SF Pro Rounded 28pt bold.
- Input `display_name` con autocomplete `.name`.
- Subtitle: "Así te van a ver tus grupos."
- Botón "Continuar" glass capsule, deshabilitado si vacío.
- Submit → UPDATE `profiles.display_name` → AuthGate detecta y avanza.

### `EmptyGroupsView` detallado

- Hero: "No tienes grupos todavía" SF Pro Rounded 28pt.
- Card glass "Crear un grupo nuevo" + subtitle "Anfitrión de cenas, tanda de ahorro, equipo deportivo…" → push `NewGroupWizard`.
- Card glass "Unirme con código" + subtitle "Si alguien ya creó tu grupo, pídele el código de invitación." → push `JoinByCodeView`.

### `JoinByCodeView` detallado

- Input 8 caracteres alfanuméricos (`invite_code` formato `substr(md5(...), 1, 8)`).
- Auto-uppercase + auto-trim.
- Botón "Unirme" → llama `join_group_by_code(code)` → push `WelcomeView` con el grupo retornado.
- Error inline si código no existe ("No encontramos ese grupo. Revisa el código.").

### `NewGroupWizard` detallado

3 pasos con `NavigationStack` + barra de progreso glass arriba.

**Paso 1 — Tipología**: 9 `TypologyCard`s en grid 2 columnas. Cada card: SF Symbol + título + 1-line copy.

| `group_type` | Título | Copy | SF Symbol |
|---|---|---|---|
| `recurring_dinner` | Cena recurrente | "Cena semanal/mensual con anfitrión rotativo" | `fork.knife` |
| `tanda_savings` | Tanda de ahorro | "Pool rotatorio de ahorro" | `dollarsign.circle` |
| `sports_team` | Equipo deportivo | "Partido semanal con posiciones" | `figure.run` |
| `study_group` | Grupo de estudio | "Club de lectura, jevruta, etc." | `book.closed` |
| `band` | Banda | "Ensemble musical/creativo" | `music.note` |
| `poker` | Poker night | "Noche de juego con pots" | `suit.spade` |
| `family` | Familia | "Comidas de domingo, fiestas" | `house` |
| `travel` | Viajes | "Grupo de viajes con fondo común" | `airplane` |
| `other` | Otro | "Define el tuyo" | `square.grid.2x2` |

Tap selecciona y avanza. Estado guarda `selectedType: GroupType`.

**Paso 2 — Identidad**:
- `name` (obligatorio, max 60 chars).
- `description` (opcional, max 280 chars).
- `event_label` (placeholder según tipología — "Cena", "Tanda", "Partido", "Sesión"…).
- `currency` (default `MXN`).

**Paso 3 — Defaults de evento** (sólo si la tipología es `recurring_dinner | sports_team | study_group | poker | family | travel`):
- `default_day_of_week` (picker días Lun–Dom).
- `default_start_time` (TimePicker).
- `default_location` (texto opcional).

Para `tanda_savings | band | other` se omite el paso 3.

Submit → llama `create_group_with_admin(name, description, event_label, currency, timezone, default_day, default_time, default_location, voting_threshold, voting_quorum, fund_enabled, group_type)` → push `WelcomeView`.

### `WelcomeView` detallado

Hero glass card:
- Título: "Bienvenido a {{group.name}}"
- Subtitle: tipología en es-MX
- Stats: "{{member_count}} miembros · {{rule_count}} reglas activas"

`WelcomeStepCard` por sección:
- "Período de gracia activo" (si tu join cae dentro del grace window — derivar de `groups.created_at` o el grace_period_days de migration `00008`). Explica que tus primeros N días no generan multas.
- "Las reglas del grupo" — scroll horizontal con cards de las reglas activas.
- "Quiénes están" — grid de avatares con `display_name`.

CTA "Entrar al grupo" → push `GroupsListView` con la card del nuevo grupo en spotlight (animación matched-geometry).

### `GroupsListView` detallado

- `MeshBackground`.
- Header: "Mis grupos" label + "Hola, {{display_name}}" SF Pro Rounded 28pt.
- ScrollView vertical con `WalletGroupCard`s. Cada card glass tinted con color de `Brand.groupPalette[hash(group.id) % 12]`.
- Cada card muestra: nombre del grupo, tipología (badge chip), miembros count.
- Pull-to-refresh con `.refreshable { await vm.refresh() }`.
- Botón flotante glass "+ Nuevo grupo" abajo a la derecha → push `NewGroupWizard` (también accesible desde toolbar).

### `GroupSummaryView` detallado

Pantalla minimal Phase 1:
- Header: nombre del grupo + tipología.
- `GlassCard` "Invite code" → muestra los 8 chars + botón copiar al clipboard (haptic `.success`).
- `GlassCard` "Miembros" → grid de avatares.
- Botón "Salir del grupo" abajo (peligroso, confirmation alert).

Phase 2 reemplaza esta pantalla por `GroupTimelineView`.

### Repos (Phase 1)

```swift
protocol AuthService: Actor {
    var session: Session? { get async }
    var sessionStream: AsyncStream<Session?> { get async }
    func signInWithApple() async throws -> Session
    func sendPhoneOTP(_ phone: String) async throws
    func verifyPhoneOTP(_ phone: String, code: String) async throws -> Session
    func sendEmailOTP(_ email: String) async throws
    func verifyEmailOTP(_ email: String, code: String) async throws -> Session
    func signOut() async throws
}

protocol ProfileRepository: Actor {
    func loadMine() async throws -> Profile
    func updateDisplayName(_ name: String) async throws
}

protocol GroupsRepository: Actor {
    func listMine() async throws -> [Group]
    func get(_ id: UUID) async throws -> GroupDetail
    func create(_ params: CreateGroupParams) async throws -> Group
    func joinByCode(_ code: String) async throws -> Group
    func leave(_ id: UUID) async throws
}

struct CreateGroupParams {
    let name: String
    let description: String?
    let eventLabel: String
    let currency: String
    let groupType: GroupType
    let defaultDayOfWeek: Int?
    let defaultStartTime: Date?
    let defaultLocation: String?
}

enum GroupType: String, Codable, Sendable, CaseIterable {
    case recurringDinner = "recurring_dinner"
    case tandaSavings   = "tanda_savings"
    case sportsTeam     = "sports_team"
    case studyGroup     = "study_group"
    case band, poker, family, travel, other
}
```

## 6. Backend changes

### Migration `00010_add_group_type_to_create_rpc.sql`

Reemplaza `create_group_with_admin` para aceptar `p_group_type` y persistirlo en la columna agregada por `00009`. La firma vieja queda DROPed para evitar ambigüedad.

```sql
-- Phase 1 iOS: extend create_group_with_admin to accept group_type.
-- The column was added in 00009 with default 'recurring_dinner', but the RPC
-- was never updated, so creating a group via the iOS app couldn't set the type.

drop function if exists public.create_group_with_admin(
  text, text, text, text, text, int, time, text, numeric, numeric, boolean
);

create or replace function public.create_group_with_admin(
  p_name text,
  p_description text,
  p_event_label text,
  p_currency text,
  p_timezone text,
  p_default_day int,
  p_default_time time,
  p_default_location text,
  p_voting_threshold numeric,
  p_voting_quorum numeric,
  p_fund_enabled boolean,
  p_group_type text
)
returns public.groups
language plpgsql security definer set search_path = public as $$
declare g public.groups;
begin
  if auth.uid() is null then raise exception 'auth required'; end if;
  insert into public.groups (
    name, description, created_by, event_label, currency, timezone,
    default_day_of_week, default_start_time, default_location,
    voting_threshold, voting_quorum, fund_enabled, group_type
  ) values (
    p_name, p_description, auth.uid(),
    coalesce(p_event_label, 'Tanda'),
    coalesce(p_currency, 'MXN'),
    coalesce(p_timezone, 'America/Mexico_City'),
    p_default_day, p_default_time, p_default_location,
    coalesce(p_voting_threshold, 0.5),
    coalesce(p_voting_quorum, 0.5),
    coalesce(p_fund_enabled, true),
    coalesce(p_group_type, 'recurring_dinner')
  ) returning * into g;

  insert into public.group_members (group_id, user_id, role, turn_order, on_committee)
  values (g.id, auth.uid(), 'admin', 1, true);
  return g;
end;
$$;
revoke execute on function public.create_group_with_admin(
  text, text, text, text, text, int, time, text, numeric, numeric, boolean, text
) from public, anon;
grant  execute on function public.create_group_with_admin(
  text, text, text, text, text, int, time, text, numeric, numeric, boolean, text
) to authenticated;
```

### Limpieza del repo

- `rm -rf web-deprecated/` como parte de la implementación.
- `.gitignore` agrega `ios/Tandas.xcodeproj/`, `ios/.build/`, `ios/DerivedData/`.

## 7. Testing

| Nivel | Herramienta | Cubre |
|---|---|---|
| Unit | Swift Testing (`@Test`) | Codable mappers (snake_case ↔ camelCase), formatters MXN/es-MX, validators (E.164, RFC email, OTP 6 dígitos), reducer states de viewmodels |
| Integration | Swift Testing + Supabase local | Repos contra Supabase local con seed mínimo. Sólo local dev, no CI. |
| Snapshot UI | swift-snapshot-testing | 9 pantallas × 3 estados (loaded/loading/error) = 27 snapshots iPhone 15 Pro |
| E2E | XCUITest | 1 happy path: launch → tab Phone → OTP mock → onboarding → wizard `recurring_dinner` → welcome → groups list → tap → summary |

**Mocks**: `MockAuthService`, `MockProfileRepository`, `MockGroupsRepository` para `#Preview` y snapshot tests. Cada View tiene preview en 3 estados.

**CI**: `.github/workflows/ios-ci.yml` corre `make project && xcodebuild test -scheme Tandas` en macos-15 + iPhone 15 Pro simulator. Snapshots fail PR si difieren (re-record con flag manual).

## 8. Acceptance Criteria (DoD)

- [ ] `make project` regenera `Tandas.xcodeproj` desde `project.yml` sin errores
- [ ] `xcodebuild build -scheme Tandas` ✓ sin warnings
- [ ] `xcodebuild test -scheme Tandas` ✓ (unit + snapshot)
- [ ] App abre en simulador iOS 26+ y muestra `LoginView` con MeshBackground
- [ ] Sign in with Apple funciona (sandbox o cuenta dev)
- [ ] Phone OTP envía SMS, verifica, retorna sesión
- [ ] Email OTP envía email, verifica, retorna sesión
- [ ] `OnboardingView` aparece para usuarios sin `display_name`, persiste en `profiles`
- [ ] `EmptyGroupsView` aparece para usuarios sin grupos
- [ ] Crear grupo recorre wizard 3 pasos, llama `create_group_with_admin` con `group_type`, persiste en Postgres
- [ ] Joinear con código existente agrega al usuario a `group_members` (turn_order incrementa)
- [ ] `WelcomeView` muestra reglas + miembros del grupo recién unido
- [ ] `GroupsListView` pinta cards Wallet con color determinístico
- [ ] Tap en card abre `GroupSummaryView` con invite_code copiable
- [ ] Salir del grupo (confirmation) marca `active = false` y vuelve a `GroupsListView`
- [ ] `Reduce Transparency` activado → glass cae a opaco, app legible
- [ ] FPS ≥ 55 en simulador iPhone 15 (Instruments)
- [ ] Migration `00010_add_group_type_to_create_rpc.sql` aplicada en Supabase remoto
- [ ] `web-deprecated/` eliminado del repo
- [ ] TestFlight build #1 instalado en device del usuario

## 9. Signing & Capabilities (Phase 1)

- **Bundle ID:** `com.josejmizrahi.tandas` (tentativo, cuenta Apple Developer personal). Team ID se confirma al configurar `project.yml`.
- **Capabilities Phase 1:**
  - Sign in with Apple
- **Capabilities diferidas:**
  - Push Notifications (Phase 7)
  - App Groups (Phase 3 cuando entren Live Activity)
  - Associated Domains (cuando se compre dominio para Universal Links)
- **TestFlight:** build #1 al cerrar Phase 1.
- **App Store submission:** después de Phase 4 (multas + pago) — antes corre riesgo de rejection por "minimum functionality".

## 10. Out of Scope (Phase 1)

- Eventos / RSVP / check-in (Phase 2)
- Reglas / votos / propuestas (Phase 3)
- Multas / pago SPEI / apelaciones (Phase 4)
- Anti-tirania UI (grace + cap visible) (Phase 4.5)
- Live Activity / push APNs (Phase 7)
- Realtime subscriptions
- Account linking SiwA ↔ phone preexistente (diferido)
- Light mode (v2)
- iPad layout específico
- Idiomas distintos a es-MX
- Offline-first / SwiftData / sync layer
- TCA u otra arquitectura más compleja que `@Observable`

## 11. Risks & Mitigations

| # | Riesgo | Mitigación |
|---|---|---|
| R1 | Apple Developer team personal aún sin App ID `com.josejmizrahi.tandas` | Crear App ID + provisioning profile como primer paso de la implementación. Si choca, usar `com.josejmizrahi.tandas.dev` como dev fallback. |
| R2 | xcodegen no instalado | `brew install xcodegen` documentado como prereq #1 |
| R3 | Sign in with Apple en simulador requiere cuenta iCloud configurada | Documentar; tests automated usan `MockAuthService` |
| R4 | Migration `00010` rompe llamadas existentes a `create_group_with_admin` desde web | La web está deprecada y se elimina en Phase 1; `00010` puede DROPear la firma vieja sin riesgo |
| R5 | `MeshGradient + glassEffect` pesados en simulador M1 sin GPU | Slice incluye perf check Instruments; si <55fps en device real, fallback a `LinearGradient` (no afecta target iOS 26 firme — sólo el visual) |
| R6 | Supabase RLS rompe edge case nuevo | Reuso de RPCs existentes minimiza superficie nueva; `00010` cambia firma pero no lógica |

## 12. Open Questions (resueltas en brainstorming)

Todas las open questions del brainstorming quedaron resueltas:
- ✅ Apple Developer team → cuenta personal
- ✅ xcodegen → instalar en implementación
- ✅ `web-deprecated/` → eliminar en implementación
- ✅ Migration `00010` → la creo yo en Phase 1

Pendiente para confirmar al configurar signing:
- Team ID exacto de la cuenta personal (se obtiene de `developer.apple.com/account`).
