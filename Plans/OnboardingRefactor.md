# Onboarding Refactor — Plan de implementación

> Branch: `claude/refactor-ios-onboarding-8rWbi`
> Status: **Draft — esperando review antes de codear**
> Author: Claude
> Date: 2026-05-01

Este plan refactoriza el onboarding de la app iOS a dos flujos distintos
(fundador / invitado) usando SwiftUI + Liquid Glass + Supabase, siguiendo
los principios del brief.

---

## 0. Contexto: qué hay hoy en el repo

Antes de proponer, lo que ya existe (no parto de cero):

### Auth
- `LiveAuthService` (actor) con: Sign in with Apple, Phone OTP (Supabase
  built-in SMS, NO Wassenger), Email OTP, signOut, sessionStream.
- `LoginView` muestra Apple + selector phone/email + OTP.
- `OTPInputView` ya implementado, 6 dígitos, glass slots, paste-from-SMS
  vía `.textContentType(.oneTimeCode)`.
- `AuthGate` conmuta entre `LoginView` / `OnboardingView` /
  `EmptyGroupsView` / `GroupsListView` según session+profile+groups.

### Onboarding actual
- **Una sola pantalla**: `OnboardingView` que pide solo `displayName`.
  No tiene noción de fundador vs invitado.

### Creación de grupo
- `NewGroupWizard`: 3 pasos (typology → identity → frequency-defaults).
  Ya tiene `TypologyCard` con 9 tipos (`recurring_dinner`, `tanda_savings`,
  `sports_team`, `study_group`, `band`, `poker`, `family`, `travel`,
  `other`). Tipos NO coinciden 1:1 con los 6 que pide el brief, pero
  hay overlap.
- `JoinByCodeView`: pide código manual de 8 chars (NO universal links).
- `WelcomeView` post-creación con 3 cards informativas.

### Design system
- `Brand` enum con colors, spacing, radius, mesh palette (oscura,
  morados/púrpuras, no "cremosa cálida" como pide el brief).
- `MeshBackground` animado con `MeshGradient` 3x3.
- `adaptiveGlass(_:)` modifier que usa `Glass.regular`/`.tint(_:)`/
  `.interactive()` con fallback `reduceTransparency`.
- Componentes: `GlassCard`, `GlassCapsuleButton`, `Field`, `OTPInput`,
  `TypologyCard`, `WelcomeStepCard`, `WalletGroupCard`.
- Fonts: `tandaHero`, `tandaTitle`, `tandaBody`, `tandaCaption`,
  `tandaAmount`.

### Estado / arquitectura
- `AppState` (`@Observable`, `@MainActor`) combina session + profile +
  groups + repos. Inyectado como `@Environment`.
- Repos son `actor` (Sendable): `LiveAuthService`,
  `LiveProfileRepository`, `LiveGroupsRepository`. Cada uno con su
  Mock equivalente.
- No hay `AppEnvironment` separado. No hay analytics. No hay haptics
  helper (se usa `.sensoryFeedback(_:trigger:)` directo).

### Backend (10 migrations)
- `groups` tiene: `name`, `description`, `event_label` (texto, ya cubre
  la idea de "vocabulario" parcialmente), `currency`, `timezone`,
  `default_day_of_week`, `default_start_time`, `default_location`,
  `voting_threshold`, `voting_quorum`, `vote_duration_hours`,
  `fund_enabled`, `block_unpaid_attendance`, `invite_code` (8 chars
  random), `group_type` (text, 9 valores).
- `group_members` tiene: `role` (admin|member), `on_committee`,
  `turn_order`, `active`, `joined_at`. NO existe `is_founder` ni
  `joined_at_event_count` (pero `created_by` en `groups` indica el
  fundador implícitamente; el primer admin = fundador).
- `rules` ya existe (Phase 3) con jsonb trigger/action, status
  `proposed|active|archived`. RPC `propose_rule` ya crea voto
  automáticamente.
- RPC `create_group_with_admin(name, description, event_label, ...,
  group_type)` existe (migration 10).

### Project setup
- Bundle ID: `com.josejmizrahi.ruul`. Display name: **"Ruul"** (no
  "Tandas"). El header del LoginView dice "Ruul. La vida en grupo, sin
  pleitos."
- Generado con `xcodegen` desde `ios/project.yml`. Pbxproj NO
  versionado.
- Deployment iOS 26.0, Swift 6.0, strict concurrency complete.
- Packages: `supabase-swift` 2.20+, `swift-snapshot-testing` 1.17+.
- SwiftData NO incluido.
- Universal Links NO configurados (entitlement de Apple Sign In es lo
  único). Sin AASA.

---

## 1. Preguntas críticas que necesito que respondas antes de codear

He marcado en cada sección con **[Q#]** los puntos donde mi
implementación depende de tu decisión. Las críticas:

### Q1 — ¿"Ruul" o "Tandas" como nombre de la app?
El bundle ID, display name y el header del login son **"Ruul"**, no
"Tandas". El brief dice "Bienvenido a Tandas" y el repo se llama
`tandas/`. ¿Renombro todos los copy del onboarding a "Ruul" o el rename
oficial es a "Tandas"? Por ahora el plan asume **"Ruul"** (consistente
con lo que el usuario ve hoy). Si es Tandas, hay que cambiar también
`Info.plist`, `LoginView`, etc.

### Q2 — WhatsApp OTP via Wassenger
El brief lo menciona como canal preferido. **Hoy no existe**. La auth
usa Supabase Phone OTP (envío SMS via Twilio/MessageBird/lo que tenga
configurado el Supabase project). Integrar Wassenger es trabajo grande:
- Edge Function en Supabase que escucha el hook `send_sms`
  (Auth → SMS Hooks) y enrutará a Wassenger en lugar de Twilio.
- O custom flow: `tandas-otp` Edge Function que genera código, lo
  guarda en una tabla `otp_codes`, lo manda por Wassenger HTTP API, y
  un RPC `verify_custom_otp` que valida contra la tabla y emite un
  link de magic-link de Supabase.

**Mi recomendación**: para este refactor, **mantener Supabase Phone OTP
(SMS)** como única vía. El brief habla de "Wassenger preferido, SMS
fallback" pero implementar Wassenger es un proyecto separado. Dejo un
TODO con la integración planeada y un protocolo `OTPDelivery` para
inyectarlo después sin tocar las vistas. **¿Sigo así o quieres
priorizar Wassenger ahora?**

### Q3 — Sign in with Apple
El brief dice "**NO** requerir Sign in with Apple/Google/email". Hoy
el LoginView lo ofrece prominentemente. ¿Lo elimino o lo dejo opcional?
- **Opción A**: lo elimino del flow del fundador (solo phone+OTP),
  pero lo dejo en una pantalla de "ya tengo cuenta" para usuarios
  recurrentes. **No es del onboarding pero existe.**
- **Opción B**: lo elimino completamente (también del LoginView).
- **Opción C**: lo dejo como está hoy.

Mi recomendación: **A**. El onboarding nuevo es phone-only, pero
mantener Apple para login recurrente reduce fricción.

### Q4 — ¿Cuándo se autentica el fundador?
El brief pone el OTP en el **paso 7a**, después de 6 minutos llenando
todo. Pero **Supabase RLS exige `auth.uid()` para escribir grupos**.
Estrategias:

- **A. Anonymous Sign-In de Supabase**: al iniciar onboarding del
  fundador, llamamos `supabase.auth.signInAnonymously()`. Eso da una
  sesión válida con un `auth.users` row sin email/phone. Vamos
  guardando el draft en SwiftData (no DB) hasta el paso 7. En el paso
  7a, llamamos `auth.updateUser(phone:)` + verifyOTP que **vincula** el
  phone al usuario anónimo (mismo UUID). Después en paso 8,
  `create_group_with_admin` corre normal. Es la aproximación más
  cercana al brief.
  - **Riesgo**: si el usuario abandona en paso 6, queda un user
    anónimo huérfano en `auth.users`. Limpiable con cron.
  - **Riesgo**: anonymous sign-in tiene que estar habilitado en el
    Supabase dashboard (Auth → Providers → Anonymous). Verificar.

- **B. Todo en local hasta el paso 7**: el draft vive en SwiftData
  (sin sesión Supabase). Paso 7a es la primera llamada a Supabase
  (sendOTP). En paso 8 ya hay sesión real y creamos grupo normal. La
  ventaja: cero "huérfanos". La desventaja: si el usuario cambia de
  device entre paso 5 y paso 7, pierde el draft (no hay sync).

- **C. Auth primero (status quo)**: como hoy, el OTP es la primera
  pantalla. El brief explícitamente quiere lo contrario.

Mi recomendación: **B**. Más limpio, conversion data sigue medible
con AnalyticsService, sin riesgo de orphans. La promesa del brief de
"el draft no se pierde si cierras la app" la cumplimos con SwiftData.
**¿Va o prefieres A?**

### Q5 — Universal Links: dominio
Para `https://tandas.app/invite/[code]` funcionar:
- Necesito que `tandas.app` sirva un archivo
  `/.well-known/apple-app-site-association` con la app's
  `appID = G3TMTFSG7S.com.josejmizrahi.ruul`.
- El bundle es `com.josejmizrahi.ruul`. ¿El dominio es `ruul.app`,
  `tandas.app`, o algo más? **¿Tienes el dominio comprado y poder
  publicar el AASA?**

Mi recomendación: el plan asume `ruul.app` (consistente con el bundle
ID). Si es otro, lo cambias en una constante. Mientras no esté el
dominio listo, el onboarding del invitado funciona también con un
"pegar código" como fallback (no romper nada).

### Q6 — ¿Reescritura completa o convivencia?
El `NewGroupWizard` y `OnboardingView` actuales **siguen siendo el path
en producción**. ¿Los borro o los dejo detrás de un flag mientras
estabilizamos el nuevo? Si la app no está aún en App Store, no hay
backwards compat que cuidar. **¿Borro o feature-flag?**

Mi recomendación: la app aún no está publicada, así que **borrar**.
Tests viejos los actualizo / reemplazo. `NewGroupWizard` queda como
referencia removida. El skip rápido a producción es valioso.

### Q7 — Analytics SDK
El brief pide PostHog/Mixpanel/Amplitude/Apple. **¿Cuál?** Por defecto
hago `protocol AnalyticsService` con un `LiveAnalyticsService` que es
un no-op + `OSLogAnalyticsService` que solo printea. Cuando elijas
SDK, agregar el wrapper es ~30 líneas.

### Q8 — ¿`event_vocabulary` separado de `event_label`?
La columna `groups.event_label text` ya existe y se usa para "Cena",
"Tanda", etc. El brief introduce un `event_vocabulary` aparentemente
para lo mismo. ¿Lo renombro `event_label` → `event_vocabulary` o son
dos cosas distintas? **Mi lectura: es lo mismo.** El plan reusa
`event_label` y lo sigue llamando así internamente.

### Q9 — `groupType` overlap
El brief lista 6 tipos: `dinnerRecurring`, `tandaSavings`, `gameGroup`,
`bandTeam`, `travelGroup`, `other`. El backend tiene 9. Mapeos
propuestos:
- `dinnerRecurring` → `recurring_dinner` ✓
- `tandaSavings` → `tanda_savings` ✓
- `gameGroup` → `poker` (más cercano)
- `bandTeam` → `band`
- `travelGroup` → `travel`
- `other` → `other`

Los tipos `sports_team`, `study_group`, `family` quedan ocultos en el
onboarding nuevo pero siguen válidos en DB. **¿OK?**

### Q10 — Grace period y rules_propose_mode: ¿hard-coded o por grupo?
El brief introduce `grace_period_events int default 3` y
`rules_propose_mode enum`. Estas dos columnas son nuevas en `groups`.
Las uso solo en el frontend (cliente decide), o el backend las
**enforça** (e.g., `evaluate_event_rules` salta los primeros 3 eventos)?

Mi recomendación: las agrego a `groups` y enforço `grace_period_events`
en `evaluate_event_rules` (un `if` arriba del loop). `rules_propose_mode`
es un hint para el cliente al crear reglas iniciales.

---

## 2. Migration de Supabase (`00011_onboarding_refactor.sql`)

Añade las columnas que el onboarding nuevo escribe, todas idempotentes.

```sql
-- Columnas nuevas en groups
alter table public.groups
  add column if not exists frequency_type text
    check (frequency_type in ('weekly','biweekly','monthly','none')),
  add column if not exists frequency_config jsonb not null default '{}'::jsonb,
  add column if not exists enabled_modules jsonb not null
    default '{"expenses":false,"fund":true,"fines":true,"pots":false}'::jsonb,
  add column if not exists grace_period_events int not null default 3
    check (grace_period_events >= 0),
  add column if not exists rules_propose_mode text not null default 'propose_to_vote'
    check (rules_propose_mode in ('propose_to_vote','active_immediately'));

-- Columnas nuevas en group_members
alter table public.group_members
  add column if not exists is_founder boolean not null default false,
  add column if not exists joined_at_event_count int not null default 0;

-- Backfill: el creador original de cada grupo es founder
update public.group_members gm
  set is_founder = true
  from public.groups g
  where gm.group_id = g.id
    and gm.user_id = g.created_by;

-- Enforce grace_period_events en el rule engine
-- (se modifica evaluate_event_rules para abortar si el grupo está
-- dentro del periodo de gracia, contado en eventos completed).
create or replace function public.is_in_grace_period(p_group_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(
    (select count(*) from public.events
       where group_id = p_group_id and status = 'completed'),
    0
  ) < (select grace_period_events from public.groups where id = p_group_id);
$$;
revoke execute on function public.is_in_grace_period(uuid) from public, anon;
grant execute on function public.is_in_grace_period(uuid) to authenticated;

-- Patch evaluate_event_rules: si el grupo está en grace period, no genera fines.
-- (el rule engine se actualiza con un early-return arriba del loop principal)

-- RPC nueva: create_group_full(...) que recibe el draft completo del onboarding
-- en una sola llamada (evita 4 round-trips: create_group, set_modules, add_rules, etc).
-- Devuelve el grupo creado + las rules creadas. Idempotente per (founder, draft_id).
create or replace function public.create_group_full(
  p_name text,
  p_description text,
  p_event_label text,
  p_group_type text,
  p_frequency_type text,
  p_frequency_config jsonb,
  p_enabled_modules jsonb,
  p_default_day int,
  p_default_time time,
  p_default_location text,
  p_grace_period_events int,
  p_rules_propose_mode text,
  p_initial_rules jsonb  -- [{title, trigger, action, enabled}]
) returns public.groups
language plpgsql security definer set search_path = public as $$
declare g public.groups; rule_row jsonb;
begin
  if auth.uid() is null then raise exception 'auth required'; end if;

  insert into public.groups (
    name, description, created_by, event_label, currency, timezone,
    default_day_of_week, default_start_time, default_location,
    fund_enabled, group_type,
    frequency_type, frequency_config, enabled_modules,
    grace_period_events, rules_propose_mode
  ) values (
    p_name, p_description, auth.uid(),
    coalesce(p_event_label, 'Evento'), 'MXN', 'America/Mexico_City',
    p_default_day, p_default_time, p_default_location,
    coalesce((p_enabled_modules->>'fund')::boolean, true),
    coalesce(p_group_type, 'other'),
    p_frequency_type, coalesce(p_frequency_config, '{}'::jsonb),
    coalesce(p_enabled_modules, '{}'::jsonb),
    coalesce(p_grace_period_events, 3),
    coalesce(p_rules_propose_mode, 'propose_to_vote')
  ) returning * into g;

  insert into public.group_members (group_id, user_id, role, turn_order, on_committee, is_founder)
  values (g.id, auth.uid(), 'admin', 1, true, true);

  -- Insertar rules iniciales según rules_propose_mode
  if p_initial_rules is not null then
    for rule_row in select * from jsonb_array_elements(p_initial_rules) loop
      insert into public.rules (
        group_id, title, description, trigger, action, exceptions,
        status, enabled, proposed_by
      ) values (
        g.id,
        rule_row->>'title',
        rule_row->>'description',
        rule_row->'trigger',
        rule_row->'action',
        '[]'::jsonb,
        case when p_rules_propose_mode = 'active_immediately' then 'active' else 'proposed' end,
        case when p_rules_propose_mode = 'active_immediately' then true else false end,
        auth.uid()
      );
    end loop;
  end if;

  return g;
end;
$$;
grant execute on function public.create_group_full(
  text, text, text, text, text, jsonb, jsonb, int, time, text, int, text, jsonb
) to authenticated;
```

### Rollback
```sql
drop function if exists public.create_group_full(...);
drop function if exists public.is_in_grace_period(uuid);
alter table public.groups drop column if exists frequency_type;
alter table public.groups drop column if exists frequency_config;
alter table public.groups drop column if exists enabled_modules;
alter table public.groups drop column if exists grace_period_events;
alter table public.groups drop column if exists rules_propose_mode;
alter table public.group_members drop column if exists is_founder;
alter table public.group_members drop column if exists joined_at_event_count;
```

### Aplicación
Sin destructive ops; columnas con default → safe. Aplico con
`mcp__653f7f48...__apply_migration` cuando me confirmes Q1-Q10.

---

## 3. Modelos Swift nuevos

```
ios/Tandas/Models/
├── GroupDraft.swift          # struct mutable que viaja por el coordinator
├── GroupPreset.swift         # defaults asociados a un GroupType
├── GroupPresets.swift        # diccionario GroupType → GroupPreset
├── FrequencyType.swift       # enum: weekly, biweekly, monthly, none
├── FrequencyConfig.swift     # struct con dayOfWeek/dayOfMonth/hour/minute
├── EnabledModules.swift      # OptionSet: expenses, fund, fines, pots
├── RulesProposeMode.swift    # enum: proposeToVote, activeImmediately
├── RulePreset.swift          # struct con las 5 reglas iniciales preseteadas
├── OnboardingProgress.swift  # @Model SwiftData
└── (existentes: Group, GroupType, Member, Profile)
```

`GroupType` ya existe pero con 9 cases. **Decidido en Q9**: lo dejo
como está, el onboarding solo expone 6.

`RulePreset` será un enum-like con 5 valores fijos:
`.lateArrival`, `.noConfirmation`, `.sameDayCancel`, `.noShow`,
`.hostFoodLate` — cada uno con `defaultEnabled: Bool`, `baseAmount: Int`,
`triggerJSON: () -> [String: Any]`, `actionJSON: () -> [String: Any]`.

---

## 4. SwiftData schema

```swift
import SwiftData

@Model
final class OnboardingProgress {
    @Attribute(.unique) var id: UUID
    var flowTypeRaw: String       // "founder" | "invited"
    var currentStepRaw: String    // FounderStep.rawValue / InvitedStep.rawValue
    var draftJSON: Data           // Codable GroupDraft o InvitedDraft, encoded
    var inviteCode: String?
    var updatedAt: Date

    init(flowType: FlowType, inviteCode: String? = nil) {
        self.id = UUID()
        self.flowTypeRaw = flowType.rawValue
        self.currentStepRaw = ""
        self.draftJSON = Data()
        self.inviteCode = inviteCode
        self.updatedAt = .now
    }
}

enum FlowType: String, Codable { case founder, invited }
```

`TandasApp` añade `.modelContainer(for: OnboardingProgress.self)`.
`OnboardingProgressStore` (actor) lee/escribe via `ModelContext`.
**Importante**: el schema es estable; si cambia la forma del draft, el
JSON puede deserializar a `nil` y el flow vuelve al paso 0 — comportamiento
aceptable para un draft.

---

## 5. Repositories

Hoy: `AuthService`, `ProfileRepository`, `GroupsRepository`. Añadir:

```
ios/Tandas/Supabase/Repos/
├── AuthService.swift            (existente — agregar updatePhone)
├── ProfileRepository.swift      (existente — agregar updateAvatar(URL))
├── GroupsRepository.swift       (existente — agregar createFull(draft))
├── InviteRepository.swift       (NUEVO)
│   protocol InviteRepository: Actor {
│       func fetchGroupPreview(inviteCode: String) async throws -> GroupInvitePreview
│       func generateInviteLink(for group: Group) async throws -> URL
│   }
│   GroupInvitePreview: { groupName, founderName, memberCount,
│                          firstFiveAvatars, frequencyDescription, ageInDays }
└── RulesRepository.swift        (NUEVO — solo wrappers de propose_rule
                                  + bulk insert para initial rules)
```

Todos `actor` para concurrency safety. Mocks por cada uno.

`createFull(_ draft: GroupDraft)`: llama al RPC `create_group_full` de
una sola vez con todo el payload del draft.

---

## 6. Coordinators (`@Observable`)

```
ios/Tandas/Features/Onboarding/Founder/
├── FounderOnboardingCoordinator.swift
├── FounderStep.swift            # enum con 11 cases (8 pasos + sub-pasos)
└── Views/...

ios/Tandas/Features/Onboarding/Invited/
├── InvitedOnboardingCoordinator.swift
├── InvitedStep.swift            # enum con 4 cases
└── Views/...
```

```swift
@MainActor
@Observable
final class FounderOnboardingCoordinator {
    var draft: GroupDraft = .empty
    var path: [FounderStep] = []
    var isLoading: Bool = false
    var errorMessage: String?

    private let auth: any AuthService
    private let profileRepo: any ProfileRepository
    private let groupsRepo: any GroupsRepository
    private let progressStore: OnboardingProgressStore
    private let analytics: any AnalyticsService
    private let haptics: HapticManager

    init(...) { ... }

    func advance() async { ... }
    func skip() { ... }
    func goBack() { ... }
    func saveProgress() async { ... }
    func finalize() async throws -> Group { ... }
}
```

Inyección por init, sin singletons. Vista raíz: `FounderOnboardingView`
con `NavigationStack(path: $coordinator.path)` y
`navigationDestination(for: FounderStep.self) { step in ... }`.

`FounderStep` enum:
```swift
enum FounderStep: Hashable, Codable {
    case welcome, identity, groupType, groupName, vocabulary,
         frequency, money, rules, invite, phoneVerify, confirmation
}
```

`InvitedStep` enum:
```swift
enum InvitedStep: Hashable, Codable {
    case welcome(InviteCode), identity, verify, tour
}
```

---

## 7. Vistas SwiftUI

| Vista | Pantalla brief | Complejidad | Observaciones |
|---|---|---|---|
| `WelcomeView` | Founder paso 0 | S | Mesh + glass card + 1 CTA |
| `FounderIdentityView` | Founder paso 1 | S | TextField + PhotosPicker opcional |
| `GroupTypeView` | Founder paso 2 | M | Grid 2-col 6 `GroupTypeCard`, single-select, auto-advance |
| `GroupNameView` | Founder paso 3a | S | TextField + glass chips de sugerencias |
| `GroupVocabularyView` | Founder paso 3b | S | Glass chips + "otro" inline |
| `GroupFrequencyView` | Founder paso 4 | M | Picker condicional según frequencyType |
| `MoneyQuestionView` | Founder paso 5 | M | 4 toggle cards + 1 exclusiva |
| `InitialRulesView` | Founder paso 6 | L | 5 cards con monto editable + segmented control de propose mode |
| `InviteMembersView` | Founder paso 7 | L | ShareLink + ContactsPicker (permission lazy) + Skip |
| `PhoneVerifyView` | Founder paso 7a | M | Reusa OTPInput, request OTP + verify |
| `ConfirmationView` | Founder paso 8 | M | 3 stacked CTAs + glass-morph a MainTabView |
| `InviteWelcomeView` | Invited paso 1 | M | Fetch preview + avatares en GlassEffectContainer |
| `InvitedIdentityView` | Invited paso 2 | S | Reusa FounderIdentityView template |
| `InvitedVerifyView` | Invited paso 3 | S | Reusa OTP component |
| `GroupTourOverlay` | Invited paso 4 | M | Overlay non-modal sobre MainTabView |

Tamaños: S = ~80 LOC, M = ~150 LOC, L = ~250 LOC. Total estimado:
~2200 LOC de vistas + 800 LOC de coordinators/models + 600 LOC de
componentes nuevos. **~3600 LOC de Swift nuevo**.

---

## 8. Componentes glass reutilizables

Nuevos en `ios/Tandas/DesignSystem/Components/`:

| Componente | Uso | Reutiliza |
|---|---|---|
| `GlassChip` | Picker de vocabulario, sugerencias de nombre | `adaptiveGlass(Capsule(), tint:)` |
| `GlassToggleCard` | Cards on/off de Money + Rules | `GlassCard` |
| `GlassSegmentedControl` | "Proponer / Activar inmediato" | `adaptiveGlass(Capsule())` por opción |
| `OnboardingProgressBar` | Header de cada paso | `Capsule` + spring animation |
| `OnboardingContainer` | Wrapper común: bg + safe area + skip toolbar | composes existing |
| `SkipButton` | ToolbarItem reusable | plain button |
| `AvatarStack` | Hero del invitado con 3-5 avatares | `GlassEffectContainer` |
| `GroupTypeCard` | Grid del paso 2 | adapt `TypologyCard` |
| `MeshBackground` | Ya existe (paleta cálida nueva) | ajustar `Brand.meshColors` o variant |

Ya existentes que se reusan tal cual: `GlassCard`, `GlassCapsuleButton`,
`Field`, `OTPInput`, `WelcomeStepCard`, `MeshBackground`,
`adaptiveGlass(_:)`.

**Cambio sutil al `MeshBackground`**: el brief pide "cremoso cálido" y
hoy es oscuro morado. Propongo añadir `MeshBackground.warm` y
`MeshBackground.dark` (variants), usar `warm` en `WelcomeView` e
`InviteWelcomeView`, dark en el resto. Sin breaking change.

---

## 9. Universal Links setup

### Entitlements (`Tandas.entitlements`)
```xml
<key>com.apple.developer.associated-domains</key>
<array>
    <string>applinks:ruul.app</string>   <!-- o tandas.app, ver Q5 -->
</array>
```

### AASA file (en `ruul.app/.well-known/apple-app-site-association`)
```json
{
  "applinks": {
    "details": [{
      "appIDs": ["G3TMTFSG7S.com.josejmizrahi.ruul"],
      "components": [{ "/": "/invite/*", "comment": "Group invites" }]
    }]
  }
}
```

Sirviendo con `Content-Type: application/json` y HTTPS.

### App
```swift
// AppEnvironment.swift (NUEVO; refactor liviano de AppState)
@MainActor
@Observable
final class AppEnvironment {
    let appState: AppState
    var pendingInvite: String?

    func handleIncomingURL(_ url: URL) {
        guard url.host == "ruul.app",
              url.pathComponents.count >= 3,
              url.pathComponents[1] == "invite"
        else { return }
        pendingInvite = url.pathComponents[2]
    }
}

// TandasApp.swift
WindowGroup {
    RootView()
        .environment(appEnvironment)
        .modelContainer(for: OnboardingProgress.self)
        .onOpenURL { appEnvironment.handleIncomingURL($0) }
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
            if let url = activity.webpageURL {
                appEnvironment.handleIncomingURL(url)
            }
        }
}
```

`RootView` decide:
1. Si `pendingInvite != nil` y no hay sesión → `InvitedOnboardingCoordinator(inviteCode: ...)`
2. Si hay `OnboardingProgress` activo → restaura ese coordinator en su step
3. Sin sesión y sin invite → `LoginView` (rebrandeado: "te invitaron? pega el código")
4. Con sesión sin grupos → `FounderOnboardingCoordinator` (puede saltar al paso 2)
5. Con sesión y grupos → `MainTabView`

### Fallback sin universal links
Mientras el AASA no esté en producción, `JoinByCodeView` actual sigue
funcionando como entrada manual.

---

## 10. Permisos lazy

| Permiso | Cuándo se pide | Cómo |
|---|---|---|
| `UNUserNotificationCenter` (push) | Al crear primer evento (post-onboarding) | `requestAuthorization(options:)` |
| `CNContactStore` (contacts) | Al tocar "Agregar por número" en paso 7 | `requestAccess(for: .contacts)` |
| `PHPhotoLibrary` (photos) | Al tocar avatar picker en paso 1 | `PhotosPicker` lo pide automático |
| `AVCaptureDevice` (camera) | Igual que photos (PhotosPicker maneja) | n/a explícito |

Ninguno se pide al iniciar la app.

---

## 11. AnalyticsService

```
ios/Tandas/Supabase/Services/AnalyticsService.swift

protocol AnalyticsService: Sendable {
    func track(_ event: AnalyticsEvent)
}

enum AnalyticsEvent {
    case onboardingStarted(flow: FlowType)
    case onboardingStepCompleted(step: String, durationMs: Int)
    case onboardingStepSkipped(step: String)
    case onboardingAbandoned(lastStep: String, totalMs: Int)
    case onboardingCompleted(flow: FlowType, totalMs: Int)
    case groupCreated(type: GroupType)
    case memberJoinedViaInvite(timeFromInviteSentSec: Int)
}

actor NoopAnalyticsService: AnalyticsService { ... }
actor OSLogAnalyticsService: AnalyticsService { ... }   // dev/test
// LiveAnalyticsService { ... }                          // post-Q7 SDK
```

Inyectado por `init`, expuesto en `AppEnvironment`.

---

## 12. Tests

Stack: `swift-testing` (unit) + `swift-snapshot-testing` (snapshots) +
`XCTest` (UI) — todo ya disponible en `project.yml`.

```
ios/TandasTests/
├── ModelsTests.swift                   (existente — agregar GroupDraft, EnabledModules)
├── OnboardingProgressStoreTests.swift  (NUEVO — SwiftData CRUD)
├── FounderCoordinatorTests.swift       (NUEVO — happy path + cada skip + cada error)
├── InvitedCoordinatorTests.swift       (NUEVO — happy path + falta sesión + invite inválido)
├── GroupPresetsTests.swift             (NUEVO — cada GroupType produce defaults)
├── PhoneFormatterTests.swift           (NUEVO — +52 normalization)
├── InitialRulesEncodingTests.swift     (NUEVO — JSON shape de las 5 rules)
└── snapshots/                          (snapshot tests por vista clave)
    ├── WelcomeView_default.png
    ├── GroupTypeView_default.png
    ├── InitialRulesView_loaded.png
    └── ...

ios/TandasUITests/
├── HappyPathTests.swift                (existente — adaptar al nuevo flow)
└── FounderE2ETests.swift               (NUEVO — flow completo con MockAuthService)
```

Snapshot tests con tres estados por vista clave: default, loading, error.

Para lo del `MockAuthService.sessionStream` que tiene el TODO en
`HappyPathTests.swift` (T18): aprovecho el refactor para arreglarlo
con un patrón de continuation registry o `AsyncChannel` style. Sin
ese fix los integration tests no son confiables.

---

## 13. Plan de feature flag

Decidido en **Q6**: como la app no está publicada, **no hace falta
feature flag**. El refactor:
- Reemplaza `OnboardingView` actual con `FounderOnboardingCoordinator`.
- Reemplaza `EmptyGroupsView` (entry point a crear/unirse) por
  `RootView` que enruta entre los dos flows.
- Mantiene `NewGroupWizard` y `JoinByCodeView` BORRADOS — el nuevo
  onboarding cubre ambos casos.

Si después necesitamos rollback rápido, `git revert` del PR del
refactor lo hace en una operación.

---

## 14. Estructura de archivos final

Resumen de adds vs cambios vs removes:

```
ios/Tandas/
├── App/
│   ├── TandasApp.swift              [MOD] añade modelContainer + onOpenURL
│   ├── RootView.swift               [NEW] reemplaza AuthGate + EmptyGroupsView
│   └── AppEnvironment.swift         [NEW] envuelve AppState + pendingInvite + analytics
├── Shell/
│   └── AuthGate.swift               [DEL] reemplazado por RootView
├── Features/
│   ├── Auth/
│   │   ├── LoginView.swift          [MOD] simplificar (Q3): Apple opcional, "Crear / Unirme"
│   │   ├── OnboardingView.swift     [DEL] reemplazado por FounderIdentityView
│   │   ├── OTPInputView.swift       [MOD] extraer logic a OTPCoordinator
│   │   └── AuthViewModel.swift      [DEL] absorbido por LoginView simplificado
│   ├── Groups/
│   │   ├── NewGroupWizard.swift     [DEL] reemplazado por FounderOnboardingCoordinator
│   │   ├── EmptyGroupsView.swift    [DEL] reemplazado por RootView
│   │   ├── JoinByCodeView.swift     [MOD] solo fallback "ya tengo código" si no hay UL
│   │   ├── WelcomeView.swift        [MOD] convertido en GroupTourOverlay (invitado)
│   │   ├── GroupSummaryView.swift   [keep] sin cambios
│   │   ├── GroupsListView.swift     [MOD] futuro MainTabView wrap (out of scope ahora)
│   │   └── GroupsViewModel.swift    [keep] sin cambios
│   └── Onboarding/                  [NEW]
│       ├── Founder/
│       │   ├── FounderOnboardingCoordinator.swift
│       │   ├── FounderStep.swift
│       │   └── Views/  (11 archivos)
│       ├── Invited/
│       │   ├── InvitedOnboardingCoordinator.swift
│       │   ├── InvitedStep.swift
│       │   └── Views/  (4 archivos)
│       └── Shared/
│           ├── OnboardingContainer.swift
│           ├── OnboardingProgressBar.swift
│           ├── SkipButton.swift
│           ├── GlassChip.swift
│           ├── GlassToggleCard.swift
│           ├── GlassSegmentedControl.swift
│           └── AvatarStack.swift
├── Models/
│   ├── (existentes sin cambios)
│   ├── GroupDraft.swift             [NEW]
│   ├── GroupPreset.swift            [NEW]
│   ├── GroupPresets.swift           [NEW]
│   ├── FrequencyType.swift          [NEW]
│   ├── FrequencyConfig.swift        [NEW]
│   ├── EnabledModules.swift         [NEW]
│   ├── RulesProposeMode.swift       [NEW]
│   ├── RulePreset.swift             [NEW]
│   └── OnboardingProgress.swift     [NEW] @Model SwiftData
├── Supabase/
│   ├── Repos/
│   │   ├── GroupsRepository.swift   [MOD] add createFull(draft)
│   │   ├── ProfileRepository.swift  [MOD] add updateAvatar
│   │   ├── InviteRepository.swift   [NEW]
│   │   └── RulesRepository.swift    [NEW]
│   └── Services/
│       ├── OnboardingProgressStore.swift  [NEW] SwiftData wrapper actor
│       ├── AnalyticsService.swift         [NEW]
│       ├── HapticManager.swift            [NEW]
│       └── PhoneFormatter.swift           [NEW]
├── DesignSystem/
│   ├── MeshBackground.swift         [MOD] add .warm variant
│   └── (otros sin cambios)
└── Resources/
    ├── Info.plist                   [MOD] (si Q1 dice rebrand)
    └── Tandas.entitlements          [MOD] add associated-domains
```

---

## 15. Orden de ejecución (TODO macro)

Cuando me confirmes Q1-Q10, ejecuto en este orden:

1. **Migration 00011** aplicada vía Supabase MCP. Verificar
   `list_tables` post-apply.
2. **Models nuevos** (Swift): GroupDraft, presets, frequency, modules,
   rules, OnboardingProgress (SwiftData).
3. **Repos extendidos**: `createFull`, `InviteRepository`,
   `RulesRepository` con Mocks.
4. **Services**: `OnboardingProgressStore`, `AnalyticsService`,
   `HapticManager`, `PhoneFormatter`.
5. **Componentes glass nuevos**.
6. **Coordinators**: founder primero, invited después.
7. **Vistas Founder**: en orden (Welcome → Identity → Type → Name →
   Vocabulary → Frequency → Money → Rules → Invite → PhoneVerify →
   Confirmation).
8. **Vistas Invited**: InviteWelcome → Identity → Verify → Tour.
9. **AppEnvironment + RootView + Universal Links**: cableado final.
10. **LoginView simplificado** (rebrand "Iniciar sesión" para usuarios
    recurrentes).
11. **Borrar**: `AuthGate`, `OnboardingView`, `NewGroupWizard`,
    `EmptyGroupsView`, `AuthViewModel`. Mover/adaptar `WelcomeView`
    a `GroupTourOverlay`.
12. **Tests**: unit + snapshot + UI.
13. **Verificación**: `make test` clean, smoke en simulador iOS 26.

Estimado de esfuerzo: **2-3 días de implementación** asumiendo
respuestas claras a Q1-Q10 y que la migration apply sea sin fricción.

---

## Apéndice — Respuestas a las preguntas del brief

> 1. ¿El proyecto Xcode actual ya tiene algún onboarding implementado?

**Sí**: `OnboardingView` (1 paso, solo nombre) + `NewGroupWizard`
(3 pasos para crear grupo). Ambos se reemplazan completamente. Reuso:
`OTPInput`, `Field`, `GlassCard`, `GlassCapsuleButton`, `MeshBackground`,
`adaptiveGlass`, `Brand` tokens, `TypologyCard` (adapt). El resto, plano
nuevo.

> 2. ¿Cómo está organizada la auth actual?

`AuthService` protocol con `LiveAuthService` y `MockAuthService` actors.
Phone OTP, Email OTP, Sign in with Apple ya implementados. Lo que falta:
`updatePhone(...)` para vincular phone al usuario anónimo (si vamos por
la opción A de Q4) o flujo de `signInAnonymously()` si es A.

> 3. ¿Wassenger?

No existe. Ver Q2.

> 4. ¿Tests existentes que pueda romper?

`HappyPathTests.swift` (XCUITest) está skipped por bug en
MockAuthService. `ModelsTests`, `MockGroupsRepositoryTests`,
`MockProfileRepositoryTests`, `MockAuthServiceTests` (swift-testing)
pasan. El refactor actualiza ModelsTests (Group adquiere campos
nuevos), añade los nuevos suites, y reemplaza `HappyPathTests` por
`FounderE2ETests` con el flow completo. Cero rotura silenciosa: si algo
deja de compilar o pasar, lo arreglo en el mismo PR.

> 5. ¿Design system tokens?

Sí. `Brand` enum con accent/spacing/radius/mesh palette. Fonts en
`Typography.swift`. `adaptiveGlass(_:)` modifier. Todo reutilizable
tal cual.

> 6. ¿Publicada en App Store?

No. Por eso (Q6) propongo borrar el flow viejo sin feature flag.

> 7. ¿Universal Links configurados?

No. Plan completo en sección 9. Bloqueado en Q5 (dominio).

> 8. ¿Analytics SDK?

Ninguno. Plan en sección 11. Bloqueado en Q7.

> 9. ¿Bundle ID + Team ID?

Sí: `com.josejmizrahi.ruul`, team `G3TMTFSG7S`. Listos para Universal
Links cuando el AASA esté servido.
