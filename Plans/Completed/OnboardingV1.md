# ruul — Onboarding V1

**Branch**: `claude/onboarding-v1`
**Status**: PLAN — awaiting review before implementation
**Depends on**: `claude/design-system-liquid-glass-d4x9M` (DS V1) merged to main

---

## 0. Resumen ejecutivo

Implementar los 2 flows de onboarding (fundador 6 pasos / invitado
4 pasos) consumiendo el DS V1. Reemplaza `LoginView`, `OTPInputView`,
`OnboardingView`, `EmptyGroupsView`, `JoinByCodeView`, `NewGroupWizard`,
`WelcomeView` legacy. El target Xcode sigue siendo `Tandas`; renombre
queda como tarea separada.

**Estrategia de coexistencia con Phase 1**:
- Las views legacy (`Features/Auth/*`, `Features/Groups/*`) siguen
  compilando y los tests existentes pasan durante el desarrollo.
- El nuevo onboarding vive en `Features/Onboarding/`.
- En el último commit de V1, `AuthGate` se reescribe para enrutar al
  nuevo flow y los archivos legacy se mueven a `Features/_Legacy/`.
- El cleanup de `_Legacy/` (DS + features) queda para un PR final una
  vez todas las pantallas estén migradas.

**Bloqueante absoluto antes de empezar a codear**: hay 6 decisiones
sin confirmar de la última ronda de preguntas (Wassenger flow,
ruul.app hosting, AASA hosting, PostHog, Wallet stub, V1 genérico vs
existing `group_type`). El plan asume defaults razonables y los
documenta — confirmá o cambiá antes de aprobar.

---

## 1. Respuestas a las 10 preguntas

### 1.1 ¿DS implementado?
**Sí, V1 completa** en `claude/design-system-liquid-glass-d4x9M`
(13 commits, esperando CI). Inventario completo:
- Tokens: Colors (light/dark/HC), Typography, Spacing, Radius, Motion,
  Haptics, Elevation, Glass.
- Primitivos: 17 listos. Todos los que el prompt lista están.
- Patterns: 9 listos.
- Templates: 4 listos.
- Showcase con shake gesture (`#if DEBUG`).

**Faltantes para onboarding V1** (planeo agregarlos al DS, NO al módulo
de onboarding — y voy a abrir un PR chico al DS para esto antes de
empezar features):

| Componente | Necesidad | Por qué al DS y no al feature |
|---|---|---|
| `RuulPhoneField` | Paso 1 fundador, paso 5a, paso 3 invitado | Todo lo que sea "input con validación" pertenece al DS. `RuulTextField .phone` actual no hace formato/lada. |
| `RuulCoverPicker` | Paso 2 fundador | Componente reusable de "scroll horizontal + tap-select con animación". Aplicable a otros flows. |
| `RuulFlowChips` | Paso 3 fundador (vocabulario) | Layout flow-wrap de chips selectables. |
| `ContactsAccessSheet` | Paso 5 fundador | Wrapper sobre `CNContactPickerViewController`. |
| `RuulActionableCard` | Paso 5 fundador (3 cards de invitar) | Card de glass con icon + título + descripción + tap action. Usado en Onboarding y probablemente Settings después. |

→ Antes de empezar onboarding, abro un PR chico al DS V1.1 con esos 5
componentes (sin tests integrados al onboarding aún, solo previews
+ snapshots). Si me dices que prefieres un approach distinto, ajusto.

### 1.2 ¿Auth con Supabase configurada? Cómo OTP hoy
Sí. `LiveAuthService` envuelve `auth.signInWithOTP(phone:)`,
`signInWithOTP(email:)`, `verifyOTP(...)`, `signInWithApple(...)`.
El proveedor SMS detrás es Twilio (default Supabase). **Cero
WhatsApp/Wassenger** — flow completo ese hay que armarlo.

### 1.3 Wassenger
**Sin configurar.** Plan: Edge Function (recomendación firme — API key
nunca al cliente). Detalle en §4.

### 1.4 Tests existentes
- 5 tests en `TandasTests/` + 1 UI en `TandasUITests/` + 1 nuevo del DS.
- `HappyPathTests` (UI) presiona botones de `LoginView`. Como el
  prompt prohíbe tocar el DS y vamos a reemplazar `LoginView` con
  `WelcomeView` + flow nuevo, el UI test se rompe. Plan: marcarlo como
  `.disabled` con TODO en §9.

### 1.5 ¿AASA en ruul.app?
**No.** Sin entitlement `com.apple.developer.associated-domains`,
sin AASA file, sin handling. El plan agrega:
- Entitlement.
- AASA spec en `Plans/aasa.json` (template) — TÚ tienes que deployear
  a `https://ruul.app/.well-known/apple-app-site-association` (yo no
  tengo acceso al dominio).
- Handler en `RuulApp` (`onContinueUserActivity`).

**Decisión a confirmar**: ¿`ruul.app` ya está registrado y bajo tu
control, o stubeo Universal Links y vamos solo con código de invite
text? Si stub: el invite es "Comparte el link" con un fallback
`ruul://invite/<code>` (URL scheme custom) que sí podemos shippear sin
AASA. Pierde el flujo App-Store-instala-y-abre-con-context, pero V1
funciona. **Mi recomendación**: stub UL en V1, AASA real en V2.

### 1.6 Bundle ID + team
Listos. `com.josejmizrahi.ruul` + `G3TMTFSG7S`. iOS 26 deployment.

### 1.7 ¿Schema existe?
**Parcialmente.** Hay 10 migrations con tablas `groups`, `group_members`,
`rules`, `events`, etc. **Conflictos** con el schema propuesto en el
prompt (sección "Modelo de datos"). Resumen del conflicto:

| Prompt propone | Existing | Resolución |
|---|---|---|
| `groups.event_vocabulary` | `groups.event_label` | **Mantener `event_label`** (ya migrado, ya hay RPCs que lo usan). Swift property se llama `eventVocabulary` y mapea al column `event_label` via `CodingKeys`. |
| `groups.frequency_type` text | (no existe) | **Agregar.** |
| `groups.frequency_config` jsonb | (no existe) | **Agregar.** Existing `default_day_of_week` + `default_start_time` se preservan; `frequency_config` los duplica para soportar `monthly` (day_of_month). |
| `groups.fines_enabled` | (no existe) — fines siempre via rules | **Agregar.** Para que paso 4 skip → `fines_enabled = false`. |
| `groups.rotation_mode` text | `groups.rotation_enabled` boolean | **Agregar `rotation_mode`** (`auto_order`/`manual`/`no_host`). `rotation_enabled` queda como derivada (true si mode != 'no_host'); UPDATE trigger para mantenerla sincronizada. |
| `groups.cover_image_name` | (no existe) | **Agregar.** |
| `groups.grace_period_events` | **YA EXISTE** (00008) | Reusar. |
| `groups.founder_id` | `groups.created_by` | **Mantener `created_by`**. Swift `founderId` mapea via CodingKeys. |
| `groups.group_type` | **YA EXISTE** (00009) | Default `'recurring_dinner'`. V1 no lo expone en UI. |
| `members` (table name) | `group_members` | **Mantener `group_members`**. |
| `members.is_founder` | `group_members.role` ('admin'/'member') | **Mantener role**. `is_founder := role == 'admin' AND user_id == groups.created_by`. |
| `members.joined_at_event_count` | (no existe) | **Agregar columna a `group_members`.** |
| `members.rotation_order` | `group_members.turn_order` | **Mantener `turn_order`**. |
| `rules.rule_type` text | `rules.code` text + `trigger.type` jsonb | Usar **`code`** column (`'late' / 'no_rsvp' / 'cancel_same_day' / 'no_show' / 'host_no_menu'`). Trigger jsonb sigue el shape existing del rule engine. |
| `rules.config` jsonb | `rules.action` jsonb | El "monto editable" del paso 4 va en `action.amount_mxn`. |
| `invites` (tabla nueva) | (no existe — solo `groups.invite_code`) | **Crear tabla nueva.** |

Migration plan en §2. Existing data (cero rows en producción, Phase 1
no shipped) no se afecta — pero por higiene la migración usa
`add column if not exists` y `create table if not exists`.

### 1.8 Analytics SDK
Sin nada configurado. Plan: **PostHog** (open source, plan free
generoso, fácil de auto-hostear en Supabase si lo necesitas más
adelante). Implementación detrás de protocol `AnalyticsService` para
que swap sea trivial. Si prefieres Mixpanel o Amplitude, solo cambia
la implementación concreta. **Confirmá la elección antes de que
lleguemos a §13.**

### 1.9 ¿SwiftData configurado?
**No.** Cero `import SwiftData`, cero `@Model`. Plan agrega:
- `import SwiftData` en target.
- `ModelContainer(for: [OnboardingProgress.self])` en `RuulApp` scene.
- `@Model final class OnboardingProgress` con MainActor isolation
  (SwiftData en Swift 6 requiere atención específica con strict
  concurrency).

### 1.10 Apple Wallet certs
**Cero.** Plan: **stub**. `WalletPassGenerator.createPass(...)` retorna
`nil` y loga `os_log(.debug, "Wallet pass would be generated for
event=\(id)")`. La call en el paso 4 invitado queda condicional
(`if let pass = ...`). En V2 se agrega cert + Edge Function que firma
el `.pkpass`. Confirmá si OK con stub.

---

## 2. Migración Supabase

Archivo nuevo: `supabase/migrations/00011_onboarding_v1.sql`.

### 2.1 Cambios a `groups`
```sql
alter table public.groups
  add column if not exists cover_image_name text,
  add column if not exists frequency_type text
    check (frequency_type is null or frequency_type in ('weekly','biweekly','monthly','unscheduled')),
  add column if not exists frequency_config jsonb not null default '{}'::jsonb,
  add column if not exists fines_enabled boolean not null default true,
  add column if not exists rotation_mode text not null default 'manual'
    check (rotation_mode in ('auto_order','manual','no_host'));

-- Sync rotation_enabled (legacy bool) ↔ rotation_mode (V1 enum) automatically.
create or replace function public.sync_rotation_fields()
returns trigger language plpgsql as $$
begin
  new.rotation_enabled := new.rotation_mode != 'no_host';
  return new;
end;
$$;

drop trigger if exists groups_sync_rotation on public.groups;
create trigger groups_sync_rotation
  before insert or update of rotation_mode on public.groups
  for each row execute function public.sync_rotation_fields();
```

### 2.2 Cambios a `group_members`
```sql
alter table public.group_members
  add column if not exists joined_at_event_count int not null default 0;

-- Helper view to expose `is_founder` without storing it.
create or replace view public.group_members_with_founder as
select
  gm.*,
  (gm.role = 'admin' and gm.user_id = g.created_by) as is_founder
from public.group_members gm
join public.groups g on g.id = gm.group_id;
```

### 2.3 Tabla `invites` (nueva)
```sql
create table if not exists public.invites (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.groups(id) on delete cascade,
  invited_by uuid not null references auth.users(id) on delete cascade,
  phone_e164 text,                 -- nullable: only set for "agregar por número"
  used_at timestamptz,
  used_by_user_id uuid references auth.users(id) on delete set null,
  expires_at timestamptz not null default (now() + interval '30 days'),
  created_at timestamptz not null default now()
);

create index idx_invites_group on public.invites(group_id);
create index idx_invites_phone on public.invites(phone_e164) where phone_e164 is not null;
create unique index uq_invites_used_by on public.invites(used_by_user_id) where used_by_user_id is not null;
```

### 2.4 RLS policies (additivas)
```sql
alter table public.invites enable row level security;

-- Members of the group can SELECT their group's invites
create policy invites_select_group_members on public.invites
  for select using (public.is_group_member(group_id, auth.uid()));

-- Group admins can INSERT new invites
create policy invites_insert_admin on public.invites
  for insert with check (public.is_group_admin(group_id, auth.uid()));

-- Anonymous SELECT by invite_code (for /invite/<code> preview before login).
-- Cross-references groups by id; we restrict columns via a view.
create or replace view public.invite_preview as
select
  i.id,
  i.expires_at,
  i.used_at,
  g.id as group_id,
  g.name as group_name,
  g.cover_image_name,
  g.event_label,
  (select count(*) from public.group_members gm where gm.group_id = g.id and gm.active) as member_count
from public.invites i
join public.groups g on g.id = i.group_id;

grant select on public.invite_preview to anon, authenticated;
```

### 2.5 RPCs nuevas
```sql
-- create_initial_group: groups + admin member en un statement.
-- Reutiliza create_group_with_admin (existing 00010); SOLO agrega cover.
-- Approach: extender la firma o llamar al existing y luego UPDATE cover.
-- Decisión: extender 00010 con un parámetro p_cover (con default null) para
-- evitar 2 round-trips desde el cliente.

create or replace function public.create_group_with_admin(
  p_name text,
  p_event_label text default null,
  p_currency text default 'MXN',
  p_timezone text default 'America/Mexico_City',
  p_group_type text default 'recurring_dinner',
  p_cover_image_name text default null      -- NEW
) returns public.groups
language plpgsql security definer set search_path = public as $$
-- ... existing body, with cover_image_name inserted into INSERT
$$;

-- mark_invite_used: cuando el invitado completa OTP.
create or replace function public.mark_invite_used(p_invite_id uuid)
returns public.invites
language plpgsql security definer set search_path = public as $$
declare i public.invites;
begin
  update public.invites
    set used_at = now(), used_by_user_id = auth.uid()
    where id = p_invite_id and used_at is null and expires_at > now()
    returning * into i;
  if i.id is null then raise exception 'invite not available'; end if;
  return i;
end;
$$;

grant execute on function public.mark_invite_used(uuid) to authenticated;
```

### 2.6 Default rules (creadas client-side, no como seed SQL)
El paso 4 del fundador crea las 5 rules llamando 5 veces a `propose_rule`
existente — pero con `status='active'` directo (skipping vote). Esto
requiere una RPC nueva:

```sql
create or replace function public.create_initial_rule(
  p_group_id uuid,
  p_code text,
  p_title text,
  p_description text,
  p_trigger jsonb,
  p_action jsonb
) returns public.rules
language plpgsql security definer set search_path = public as $$
declare r public.rules;
begin
  if not public.is_group_admin(p_group_id, auth.uid()) then
    raise exception 'only admins can seed rules';
  end if;
  insert into public.rules (group_id, code, title, description, trigger, action, status, enabled, proposed_by)
    values (p_group_id, p_code, p_title, p_description, p_trigger, p_action, 'active', true, auth.uid())
    returning * into r;
  return r;
end;
$$;

grant execute on function public.create_initial_rule(uuid, text, text, text, jsonb, jsonb) to authenticated;
```

### 2.7 Rollback strategy
Migración aplica `add column if not exists` + `create table if not
exists` en todas. Para rollback manual:
```sql
-- 00011_rollback.sql (NOT applied automatically)
drop trigger if exists groups_sync_rotation on public.groups;
drop function if exists public.sync_rotation_fields();
drop function if exists public.create_initial_rule(uuid, text, text, text, jsonb, jsonb);
drop function if exists public.mark_invite_used(uuid);
drop view if exists public.invite_preview;
drop view if exists public.group_members_with_founder;
drop table if exists public.invites;
alter table public.group_members drop column if exists joined_at_event_count;
alter table public.groups
  drop column if exists rotation_mode,
  drop column if exists fines_enabled,
  drop column if exists frequency_config,
  drop column if exists frequency_type,
  drop column if exists cover_image_name;
```
No corremos el rollback automáticamente. Está documentado para emergencias.

---

## 3. Modelos Swift

Estructura nueva en `ios/Tandas/Models/Onboarding/` (existing `Group.swift`
se EXTIENDE, no se reemplaza, para no romper Phase 1).

### 3.1 Regular structs (Sendable, Codable, Hashable)

```swift
// Models/Onboarding/GroupDraft.swift
struct GroupDraft: Sendable {            // mutable, in-memory only
    var name: String
    var coverImageName: String?
    var eventVocabulary: String          // maps to event_label
    var customVocabulary: String?        // user-typed "otro" value
    var frequencyType: FrequencyType?
    var frequencyConfig: FrequencyConfig?
    var finesEnabled: Bool = true
    var rotationMode: RotationMode = .manual
    var rules: [RuleDraft] = []
}

enum FrequencyType: String, Sendable, Codable, Hashable {
    case weekly, biweekly, monthly, unscheduled
}

struct FrequencyConfig: Sendable, Codable, Hashable {
    var dayOfWeek: Int?         // 0=Sun..6=Sat (matches existing default_day_of_week)
    var dayOfMonth: Int?        // 1..31 (for monthly)
    var hour: Int?              // 0..23
    var minute: Int?            // 0..59
}

enum RotationMode: String, Sendable, Codable, Hashable {
    case autoOrder = "auto_order"
    case manual
    case noHost = "no_host"
}

struct RuleDraft: Identifiable, Sendable, Hashable {
    let id: UUID = UUID()
    let code: String                     // 'late','no_rsvp','cancel_same_day','no_show','host_no_menu'
    var title: String
    var description: String
    var amountMXN: Int                   // editable inline
    var enabled: Bool                    // toggle
    let trigger: RuleTriggerSpec         // immutable per code (built from defaults)
}

struct RuleTriggerSpec: Sendable, Codable, Hashable {
    let type: String                     // matches existing trigger jsonb shape
    let params: [String: AnyCodable]     // small JSON shim
}
```

### 3.2 Update existing `Group.swift`
Extender con nuevas columnas mediante `CodingKeys`:
```swift
struct Group: Identifiable, Codable, Sendable, Hashable {
    let id: UUID
    let name: String
    let description: String?
    let groupType: GroupType
    let inviteCode: String
    let coverImageName: String?            // NEW
    let eventVocabulary: String            // NEW (maps to event_label)
    let frequencyType: FrequencyType?      // NEW
    let frequencyConfig: FrequencyConfig?  // NEW
    let finesEnabled: Bool                 // NEW
    let rotationMode: RotationMode         // NEW
    let createdBy: UUID                    // NEW (founder)
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, name, description
        case groupType = "group_type"
        case inviteCode = "invite_code"
        case coverImageName = "cover_image_name"
        case eventVocabulary = "event_label"
        case frequencyType = "frequency_type"
        case frequencyConfig = "frequency_config"
        case finesEnabled = "fines_enabled"
        case rotationMode = "rotation_mode"
        case createdBy = "created_by"
        case createdAt = "created_at"
    }
}
```

Consumers existentes de `Group` (Phase 1 views) seguirán funcionando —
los nuevos campos son opcionales o tienen defaults razonables.

### 3.3 SwiftData entity

```swift
// Models/Onboarding/OnboardingProgress.swift
import SwiftData

@Model final class OnboardingProgress {
    enum FlowType: String, Codable { case founder, invited }
    enum FounderStep: String, Codable {
        case welcome, founderIdentity, groupIdentity, vocabulary, rules, invite, phoneVerify, otp, confirm
    }
    enum InvitedStep: String, Codable {
        case welcome, identity, phoneVerify, otp, tour
    }

    var id: UUID
    var flowTypeRaw: String              // FlowType raw (SwiftData doesn't love enum)
    var founderStepRaw: String?
    var invitedStepRaw: String?
    var inviteCode: String?              // for invited flow
    var draftJSON: Data?                 // encoded GroupDraft snapshot (founder)
    var displayName: String?
    var avatarLocalPath: String?         // before upload, store local file URL
    var phoneE164: String?
    var startedAt: Date
    var lastUpdatedAt: Date

    init(flowType: FlowType, inviteCode: String? = nil) {
        self.id = UUID()
        self.flowTypeRaw = flowType.rawValue
        self.inviteCode = inviteCode
        self.startedAt = Date()
        self.lastUpdatedAt = Date()
    }
}
```

Nota Swift 6: `@Model` classes son automáticamente `@MainActor`-safe
cuando se accede vía `ModelContext` correctamente. Tests cubren esto.

---

## 4. Repositories + Services

### 4.1 GroupRepository (actor)
```swift
protocol GroupRepository: Sendable {
    func createInitialGroup(_ draft: GroupDraft) async throws -> Group
    func updateGroup(_ id: UUID, with patch: GroupPatch) async throws -> Group
    func fetchByInviteCode(_ code: String) async throws -> InvitePreview
    func currentUserGroups() async throws -> [Group]
}

actor SupabaseGroupRepository: GroupRepository {
    private let client: SupabaseClient
    // ...
}
```

`GroupPatch` es un struct con todos los fields opcionales para
partial updates (no PATCH all).

### 4.2 MemberRepository (actor)
```swift
protocol MemberRepository: Sendable {
    func upsertMyMembership(groupId: UUID, displayName: String, avatarURL: URL?) async throws -> Member
    func members(of groupId: UUID, limit: Int) async throws -> [Member]
}
```

### 4.3 InviteRepository (actor)
```swift
protocol InviteRepository: Sendable {
    func createInvite(groupId: UUID, phoneE164: String?) async throws -> Invite
    func fetchPreview(byCode code: String) async throws -> InvitePreview
    func markInviteUsed(_ inviteId: UUID) async throws -> Invite
    func sendWhatsApp(invite: Invite, message: String) async throws  // calls edge function
}
```

### 4.4 RuleRepository (actor)
```swift
protocol RuleRepository: Sendable {
    func createInitialRules(groupId: UUID, drafts: [RuleDraft]) async throws -> [Rule]
    func rules(of groupId: UUID) async throws -> [Rule]
}
```
`createInitialRules` itera y llama al RPC `create_initial_rule` por
cada `RuleDraft.enabled == true`. Las disabled NO se crean en V1.

### 4.5 OTP service

```swift
protocol OTPService: Sendable {
    /// Returns the channel actually used (whatsapp falls back to sms after 5s timeout).
    func requestCode(phoneE164: String) async throws -> OTPChannel
    func verifyCode(phoneE164: String, code: String, channel: OTPChannel) async throws -> AuthSession
}

enum OTPChannel: String, Codable, Sendable { case whatsapp, sms }
```

Implementación `LiveOTPService`:
1. POST a edge function `send-otp` con `{ phone, prefer: "whatsapp" }`.
2. Edge function genera código 6 dígitos, guarda en tabla nueva
   `otp_codes (phone, code_hash, channel, expires_at, attempts)`,
   intenta mandar por Wassenger.
3. Si Wassenger falla o timeout >5s, edge function llama
   `auth.signInWithOtp({ phone, channel: 'sms' })` y retorna
   `{ channel: 'sms' }`.
4. Edge function retorna `{ channel: "whatsapp" | "sms", expires_at }`.
5. Cliente UI swap "Te mandamos por WhatsApp" / "Te mandamos un SMS"
   según el channel devuelto.
6. `verifyCode` POST a `verify-otp`. Si channel=whatsapp, edge function
   valida contra `otp_codes` table y crea sesión via Supabase Admin
   API. Si channel=sms, forward a `auth.verifyOtp(...)`.

Edge function code va en `supabase/functions/send-otp/index.ts` y
`supabase/functions/verify-otp/index.ts`. Wassenger API key como
secret `WASSENGER_API_KEY`.

**Riesgo crítico**: validar contra Wassenger requiere el cliente del
edge function. La función `verify-otp` para channel=whatsapp debe
crear una sesión via Admin API (`supabase.auth.admin.generateLink`
o similar). Es sutil — investigaré edge case durante implementación,
si descubro que no se puede sin warts, **fallback a Supabase Auth
SMS only en V1** y WhatsApp viene en V2.

### 4.6 AnalyticsService (protocol + PostHog impl + Mock)
```swift
protocol AnalyticsService: Sendable {
    func track(_ event: AnalyticsEvent) async
    func setUser(_ userId: UUID, properties: [String: AnalyticsValue]) async
}
```

`AnalyticsEvent` es un enum con todos los eventos del prompt.
PostHog impl + Mock para tests.

### 4.7 WalletPassGenerator (stub)
```swift
protocol WalletPassGenerator: Sendable {
    func createPass(for eventId: UUID, memberId: UUID) async -> URL?
}

struct StubWalletPassGenerator: WalletPassGenerator {
    func createPass(for eventId: UUID, memberId: UUID) async -> URL? {
        os_log(.debug, "Wallet pass would be generated for event=\(eventId)")
        return nil
    }
}
```

---

## 5. Coordinators

Dos coordinators, ambos `@Observable`. State machines explícitas.

### 5.1 FounderOnboardingCoordinator

```swift
@Observable @MainActor
final class FounderOnboardingCoordinator {
    enum Step: Int, CaseIterable, Sendable {
        case welcome = 0, identity, group, vocabulary, rules, invite, phoneVerify, otp, confirm
    }

    private(set) var currentStep: Step = .welcome
    private(set) var draft: GroupDraft = .empty
    private(set) var displayName: String = ""
    private(set) var avatarURL: URL?
    private(set) var phoneE164: String = ""
    private(set) var otpAttempts: Int = 0
    private(set) var pendingInvites: [PendingInvite] = []
    private(set) var createdGroup: Group?
    private(set) var error: OnboardingError?
    private(set) var isLoading: Bool = false

    private let groupRepo: any GroupRepository
    private let memberRepo: any MemberRepository
    private let inviteRepo: any InviteRepository
    private let ruleRepo: any RuleRepository
    private let otp: any OTPService
    private let analytics: any AnalyticsService
    private let progress: OnboardingProgressManager
    private let session: SessionID = UUID()

    init(groupRepo: ..., memberRepo: ..., ...) { ... }

    func advance() async { ... }
    func skip() async { ... }
    func retry() async { ... }
    func reset() async { ... }
    func restore(from progress: OnboardingProgress) async { ... }
}
```

### 5.2 InvitedOnboardingCoordinator
Análogo, 5 pasos: `welcome → identity → phoneVerify → otp → tour`.

### 5.3 OnboardingProgressManager
Wrapper sobre `ModelContext` con methods `save(_:)`, `loadActive()`,
`clear()`. Persistence layer aislada del coordinator.

### 5.4 Transiciones (founder)
```
welcome --advance--> founderIdentity
founderIdentity --advance(name + avatar?)--> groupIdentity
                --skip--> groupIdentity (avatar=nil, name fallback "Tú")
groupIdentity --advance(create RPC)--> vocabulary
                                    [error: stay on groupIdentity, show toast]
vocabulary --advance(update RPC)--> rules
            --skip--> rules (vocabulary=default, frequency=null)
rules --advance(create rules + update RPC)--> invite
       --skip--> invite (fines_enabled=false, rules=[])
invite --advance--> phoneVerify
       --skip--> phoneVerify (no invites)
phoneVerify --advance(otp.requestCode)--> otp
otp --advance(otp.verifyCode + member.upsert)--> confirm
     [3 fail: error state, manual reset to phoneVerify]
confirm --done--> destination (createEvent | invite | home)
```

### 5.5 Transiciones (invited)
```
welcome --advance(fetch invitePreview)--> identity
        [code invalid/expired: ErrorStateView, no advance]
identity --advance(name + avatar?)--> phoneVerify (no skip)
phoneVerify --advance--> otp
otp --advance(verify + member.upsert + mark_invite_used)--> tour
     [3 fail: error, reset]
tour --done--> MainAppScreenTemplate placeholder + (optional) wallet pass
```

### 5.6 Save incremental
Cada `advance` que cambia state:
1. Llama al repo correspondiente.
2. Si éxito, actualiza `OnboardingProgress` en SwiftData (encoded
   draft + currentStep).
3. Track analytics.
4. Avanza UI.

---

## 6. Vistas

### 6.1 Founder views (orden de implementación)

| # | View | Depende de |
|---|---|---|
| 1 | `WelcomeView` | DS templates |
| 2 | `FounderIdentityView` | DS primitives, PhotosPicker |
| 3 | `GroupIdentityView` | DS + RuulCoverPicker (nuevo en DS) |
| 4 | `GroupVocabularyView` | DS + RuulFlowChips (nuevo en DS) |
| 5 | `InitialRulesView` | DS (RuulCard, RuulToggle, RuulSheet, RuulSegmentedControl) |
| 6 | `InviteMembersView` | DS + ContactsAccessSheet (nuevo) + RuulActionableCard (nuevo) |
| 7 | `PhoneVerifyView` | DS + RuulPhoneField (nuevo) |
| 8 | `OTPVerifyView` (compartido) | DS (RuulOTPInput) |
| 9 | `ConfirmationView` | DS templates |

### 6.2 Invited views

| # | View | Depende de |
|---|---|---|
| 1 | `InviteWelcomeView` | DS + RuulAvatarStack + LoadingStateView |
| 2 | `InvitedIdentityView` | DS + PhotosPicker |
| 3 | `InvitedVerifyView` | DS + RuulPhoneField |
| 4 | `InvitedOTPView` | DS (RuulOTPInput) |
| 5 | `GroupTourOverlay` | DS (RuulCard) — overlay no-modal |

### 6.3 Patrón común
Cada view recibe el coordinator vía `@Environment(...)` (NO `@State`,
porque las views son pushed dentro de un NavigationStack y tienen que
ver el mismo coordinator instance). El coordinator se crea en
`OnboardingRootView` con `@State` y se inyecta vía
`.environment(coordinator)`.

### 6.4 Glass-morph entre pasos
`NavigationStack` default push/pop animation es OK para iOS 26. Si el
prompt requiere específicamente glass-morph (no es claro), evaluamos en
implementación. Por defecto: NavigationStack default.

### 6.5 Progress bar
`OnboardingStepContainer` ya recibe `progress: Double, stepCount: Int?`.
Cada view pasa `Double(currentStep.rawValue) / Double(Step.allCases.count - 1)`.

---

## 7. Universal Links

### 7.1 Decisión por tomar
**Opción A — UL real con AASA**: requiere `ruul.app` activo + acceso al
hosting para deployear AASA. Si tienes esto, entitlement +
onContinueUserActivity handler en `RuulApp`.

**Opción B — UL stub con custom URL scheme**: `ruul://invite/<code>`,
sin AASA, sin associated-domains. Funciona desde dentro de la app
(tap en mensaje WhatsApp/SMS abre la app si está instalada). Si la app
no está instalada, el link no abre nada — el usuario tiene que
descargar la app y luego pegar el código manualmente.

**Mi recomendación V1: Opción B**. Es ~80% del valor con 20% del setup.
Cuando `ruul.app` esté listo, AASA se agrega en V2 sin cambios al
código del cliente (solo entitlements + AASA file).

### 7.2 Implementación opción B
```swift
// RuulApp.swift
.onOpenURL { url in
    appEnv.handleIncomingURL(url)
}

// AppEnvironment.handleIncomingURL
func handleIncomingURL(_ url: URL) {
    guard url.scheme == "ruul",
          url.host == "invite",
          let code = url.pathComponents.last else { return }
    pendingInviteCode = code
    // RootView will react and route to invited flow
}
```

### 7.3 Plan de migración a opción A
Cuando ruul.app esté listo:
1. Deploy AASA a `https://ruul.app/.well-known/apple-app-site-association`.
2. Add entitlement `applinks:ruul.app`.
3. Add `.onContinueUserActivity(NSUserActivityTypeBrowsingWeb)` handler.
4. Mensaje pre-redactado en `InviteMembersView` cambia de
   `ruul://invite/<code>` a `https://ruul.app/invite/<code>`.

Sin tocar coordinators ni views.

---

## 8. Apple Wallet

**Stub en V1**, como respondí en §1.10. `WalletPassGenerator` retorna
`nil`. La call en `GroupTourOverlay` (paso 4 invitado) es:
```swift
if let passURL = await walletGen.createPass(for: nextEventId, memberId: myMemberId) {
    PKAddPassesView(passURL: passURL)  // shown only if non-nil
}
```
En V1, `passURL == nil` siempre → la subview no se muestra.

V2 plan: cert + Edge Function que firma `.pkpass` + `PKAddPassesViewController`.

---

## 9. Tests

Total estimado: ~50 tests + ~80 snapshots.

### 9.1 Unit tests (swift-testing)

**`FounderOnboardingCoordinatorTests`** (8 tests)
- happy path completo (welcome → confirm).
- skip vocabulary (defaults).
- skip rules (`fines_enabled = false`).
- skip invite (no invites creadas).
- error en `createInitialGroup` → no avanza, error state.
- error en OTP → contador correcto, después de 3 falla error state.
- restoration desde SwiftData en step `.rules`.
- reset limpia draft + progress.

**`InvitedOnboardingCoordinatorTests`** (5 tests)
- happy path (welcome → tour).
- invite_code inválido → error state.
- invite_code expirado → error state.
- error en OTP → contador correcto.
- mark_invite_used falla → muestra error pero coordinator NO retrocede.

**`OTPServiceTests`** (4 tests)
- WhatsApp success → `OTPChannel.whatsapp`.
- WhatsApp timeout (>5s) → fallback to SMS, returns `.sms`.
- WhatsApp + SMS fail → throws.
- VerifyCode wrong code → throws + attempts incremented.

**`RuleEngineSetupTests`** (3 tests)
- Default 5 RuleDrafts: 4 enabled + 1 disabled (`host_no_menu`).
- skipRules → `createInitialRules` NO se llama, `fines_enabled = false`.
- amount edits propagate to Rule.action.amount_mxn.

**`OnboardingProgressManagerTests`** (3 tests)
- save persists draft + step.
- loadActive retrieves the latest unfinished progress.
- clear removes progress.

**`UniversalLinkParsingTests`** (3 tests)
- valid `ruul://invite/abc123` → code extracted.
- malformed URL → ignored.
- query params preserved (for future).

### 9.2 Snapshot tests (~80)

Cada vista del onboarding × {default, loading, filled, error} ×
{light, dark, HC} = ~13 views × 3-4 estados × 3 modos.

### 9.3 Integration tests
- Founder flow end-to-end con repos mockeados (assert que cada RPC se
  llama con el payload correcto).
- Invited flow end-to-end.
- Universal link → invited flow se enruta correctamente.
- Restoration en cualquier paso.

### 9.4 Tests existentes que se rompen
- `HappyPathTests` (UI). Plan: `.disabled("Replaced by onboarding V1")`
  con TODO de reescribir. Cuando se reescriba, será sobre el nuevo
  flow.

---

## 10. Estructura de archivos

```
ios/Tandas/
├── Features/
│   ├── Onboarding/
│   │   ├── Founder/
│   │   │   ├── Coordinator/
│   │   │   │   ├── FounderOnboardingCoordinator.swift
│   │   │   │   └── FounderStep.swift
│   │   │   └── Views/
│   │   │       ├── WelcomeView.swift
│   │   │       ├── FounderIdentityView.swift
│   │   │       ├── GroupIdentityView.swift
│   │   │       ├── GroupVocabularyView.swift
│   │   │       ├── InitialRulesView.swift
│   │   │       ├── InviteMembersView.swift
│   │   │       ├── PhoneVerifyView.swift
│   │   │       ├── OTPVerifyView.swift          # shared
│   │   │       └── ConfirmationView.swift
│   │   ├── Invited/
│   │   │   ├── Coordinator/
│   │   │   │   ├── InvitedOnboardingCoordinator.swift
│   │   │   │   └── InvitedStep.swift
│   │   │   └── Views/
│   │   │       ├── InviteWelcomeView.swift
│   │   │       ├── InvitedIdentityView.swift
│   │   │       ├── InvitedVerifyView.swift
│   │   │       ├── InvitedOTPView.swift
│   │   │       └── GroupTourOverlay.swift
│   │   ├── Shared/
│   │   │   ├── OnboardingRootView.swift          # routes to founder vs invited
│   │   │   ├── OnboardingFlowCoordinator.swift   # protocol
│   │   │   └── OnboardingProgressManager.swift   # SwiftData manager
│   │   └── Routing/
│   │       └── AppEnvironment+OnboardingRoute.swift
│   └── _Legacy/                                  # at end, move legacy auth+groups views here
├── Models/
│   └── Onboarding/
│       ├── GroupDraft.swift
│       ├── FrequencyType.swift
│       ├── FrequencyConfig.swift
│       ├── RotationMode.swift
│       ├── RuleDraft.swift
│       ├── RuleTriggerSpec.swift
│       ├── PendingInvite.swift
│       ├── Invite.swift
│       ├── InvitePreview.swift
│       └── OnboardingProgress.swift              # @Model
├── Supabase/
│   └── Repos/
│       ├── InviteRepository.swift                # NEW
│       ├── RuleRepository.swift                  # NEW
│       └── GroupsRepository.swift                # EXTEND
├── Services/
│   ├── OTP/
│   │   ├── OTPService.swift                      # protocol
│   │   └── LiveOTPService.swift
│   ├── Analytics/
│   │   ├── AnalyticsService.swift                # protocol
│   │   ├── PostHogAnalyticsService.swift
│   │   └── MockAnalyticsService.swift
│   └── Wallet/
│       ├── WalletPassGenerator.swift             # protocol
│       └── StubWalletPassGenerator.swift         # V1
├── Utilities/
│   ├── PhoneFormatter.swift                      # E.164 normalization
│   └── InviteLinkGenerator.swift                 # ruul://invite/<code>
└── Resources/
    └── Assets.xcassets/
        ├── EventCovers/                          # 8-10 covers (you provide)
        └── Logo/                                 # ruul wordmark (you provide)

ios/TandasTests/
├── Onboarding/
│   ├── FounderOnboardingCoordinatorTests.swift
│   ├── InvitedOnboardingCoordinatorTests.swift
│   ├── OTPServiceTests.swift
│   ├── RuleEngineSetupTests.swift
│   ├── OnboardingProgressManagerTests.swift
│   └── UniversalLinkParsingTests.swift
└── Snapshots/
    └── Onboarding/__Snapshots__/

supabase/
├── migrations/
│   └── 00011_onboarding_v1.sql
└── functions/
    ├── send-otp/
    │   └── index.ts
    └── verify-otp/
        └── index.ts

Plans/
└── OnboardingV1.md                              # this file

Plans/Templates/
└── apple-app-site-association.json              # AASA template for opt-in
```

---

## 11. Plan de feature flag

**No es necesario un feature flag para V1.** Razones:
- Phase 1 NO está deployed a usuarios reales (verificado: el bundle id
  `com.josejmizrahi.ruul` no está en App Store).
- El swap legacy → onboarding nuevo es atómico (un commit).
- El "rollback" es revert del commit.

Si más adelante se shippea Phase 1 antes de onboarding V1, se agrega
flag remote-config (Supabase). Pero no aplica hoy.

---

## 12. Plan de ejecución (commits sugeridos)

Total estimado: ~25 commits. Cada uno verde (compila + tests pasan).

### Bloque 0 — pre-requisitos
1. **`ds: V1.1 — RuulPhoneField + RuulFlowChips + RuulCoverPicker + RuulActionableCard + ContactsAccessSheet`**
   En la rama del DS (no en `claude/onboarding-v1`). Pequeño PR
   apuntando a main, con previews + snapshots.

### Bloque 1 — backend
2. `db: 00011 onboarding v1 migration (cover, frequency, rotation_mode, fines_enabled, invites table)`
3. `db: 00011 add create_initial_rule + mark_invite_used RPCs`
4. `edge: send-otp + verify-otp Edge Functions (Wassenger + SMS fallback)`

### Bloque 2 — Swift foundations
5. `chore: add SwiftData ModelContainer + OnboardingProgress @Model`
6. `feat(models): GroupDraft, FrequencyType, RotationMode, RuleDraft + extended Group`
7. `feat(repos): InviteRepository + RuleRepository + extended GroupsRepository`
8. `feat(services): OTPService protocol + LiveOTPService`
9. `feat(services): AnalyticsService protocol + PostHog impl + Mock`
10. `feat(services): StubWalletPassGenerator`
11. `feat(util): PhoneFormatter + InviteLinkGenerator`

### Bloque 3 — coordinators
12. `feat(onboarding): FounderOnboardingCoordinator state machine`
13. `feat(onboarding): InvitedOnboardingCoordinator state machine`
14. `feat(onboarding): OnboardingProgressManager (SwiftData)`
15. `test(onboarding): coordinator tests (15 tests)`
16. `test(onboarding): OTPService + AnalyticsService + Util tests`

### Bloque 4 — founder views
17. `feat(onboarding/founder): WelcomeView + FounderIdentityView + snapshots`
18. `feat(onboarding/founder): GroupIdentityView + GroupVocabularyView + snapshots`
19. `feat(onboarding/founder): InitialRulesView + snapshots`
20. `feat(onboarding/founder): InviteMembersView + PhoneVerifyView + OTPVerifyView + snapshots`
21. `feat(onboarding/founder): ConfirmationView + snapshots`

### Bloque 5 — invited views
22. `feat(onboarding/invited): all 5 views + snapshots`

### Bloque 6 — wiring
23. `feat: AppEnvironment route handling + URL scheme + RootView routing`
24. `feat: replace LoginView/OnboardingView with OnboardingRootView in AuthGate`
25. `chore: move legacy auth + groups views to Features/_Legacy/, disable HappyPathTests`

---

## 13. Decisiones a confirmar antes de implementar

Resumen de TODAS las decisiones tomadas en este plan que requieren
tu OK explícito:

1. **Schema mapping** (§1.7 / §2): mantener nombres existentes
   (`event_label`, `created_by`, `group_members`, `rotation_enabled`)
   y agregar nuevos columns/tabla `invites`. El Swift mapea via
   `CodingKeys`. **Alternativa**: rename + drop legacy migrations
   (más limpio, más invasivo).
2. **Universal Links**: opción B (custom URL scheme `ruul://invite/`)
   en V1. AASA real en V2 cuando ruul.app esté listo.
3. **Wassenger**: edge functions con secret. SMS-only fallback si la
   integración Admin-API resulta no implementable sin warts.
4. **PostHog** como analytics SDK.
5. **Apple Wallet stub** en V1 (cert + signing en V2).
6. **DS V1.1**: PR previo agregando 5 componentes (Phone, FlowChips,
   CoverPicker, ActionableCard, ContactsAccessSheet).
7. **NO feature flag**: swap legacy ↔ nuevo es atómico vía commit.
8. **`HappyPathTests` UI test**: marcado como disabled en commit 25,
   reescribir en PR aparte.
9. **NO renombrar target Xcode** `Tandas` → `Ruul` (sigue como en V1).
10. **`group_type`** existing default `'recurring_dinner'` queda.
    V1 NO expone tipos en UI (genérico); el campo está en BD pero el
    onboarding ni lo lee ni lo escribe.

---

## 14. Riesgos identificados

### 14.1 Wassenger session creation desde Edge Function
**Riesgo**: para channel=whatsapp, el edge function `verify-otp` debe
crear una sesión Supabase válida. La Admin API permite
`generateLink({ type: 'magiclink' })` pero requiere email. Para
phone-only, la única opción puede ser `auth.signInWithOtp({phone})` y
luego `auth.verifyOtp({phone, token})` con un token que el edge
function debe poder forzar. **Si esto NO es posible**, fallback es
cancelar WhatsApp y usar SMS-only en V1. La WhatsApp UX vendría en V2
con un workaround más invasivo (crear users via auth.admin.createUser
y luego custom JWT signing).

### 14.2 SwiftData en Swift 6 strict concurrency
`@Model` classes y `ModelContext` tienen edge cases. Si encontramos
warnings de concurrency que bloquean build, fallback a `UserDefaults`
con `Codable` para `OnboardingProgress` (menos rico pero suficiente
para guardar step + draftJSON).

### 14.3 ruul.app sin AASA bloqueante
Si el plan V2 espera AASA y nunca llega, el invite link compartido vía
ShareLink (paso 5 fundador) tendrá fallback feo (link no abre app si no
está instalada). Mitigación V1: ShareLink message incluye texto
"Descarga la app aquí: <App Store URL>" antes del invite link.

### 14.4 Apple Wallet stub
`GroupTourOverlay` muestra el botón "Add to Wallet" condicional. En V1
nunca aparece (stub returns nil). La UI no se diseña asumiendo que
existe — diseño defensivo.

### 14.5 Tabla `otp_codes`
Necesaria para flujo Wassenger. NO está en §2.1-2.5 porque es interna
al edge function. Migration la agrega:
```sql
create table public.otp_codes (
  id uuid primary key default gen_random_uuid(),
  phone_e164 text not null,
  code_hash text not null,
  channel text not null check (channel in ('whatsapp','sms')),
  expires_at timestamptz not null,
  attempts int not null default 0,
  consumed_at timestamptz,
  created_at timestamptz not null default now()
);
create index idx_otp_codes_phone on public.otp_codes(phone_e164) where consumed_at is null;
```
RLS: solo edge function (service_role) accede.

---

## 15. DoD del PR final

- [ ] `make -C ios test` pasa.
- [ ] `make -C ios build` sin warnings nuevos (Swift 6 strict).
- [ ] `supabase db push` aplica `00011_onboarding_v1.sql` sin errores.
- [ ] Edge functions desplegadas en Supabase (`send-otp`, `verify-otp`).
- [ ] Cada view del onboarding tiene `#Preview` y snapshot tests.
- [ ] PostHog API key configurada via `Tandas.local.xcconfig` (NO en repo).
- [ ] Wassenger API key configurada como Supabase secret.
- [ ] `WASSENGER_TIMEOUT_MS=5000` configurable.
- [ ] `Plans/Templates/apple-app-site-association.json` listo para
      cuando deployees ruul.app.
- [ ] HappyPathTests disabled con TODO.
- [ ] AuthGate enrutando al nuevo OnboardingRootView.
- [ ] Legacy views en `Features/_Legacy/`.

---

## 16. Lo que viene después de este PR

- **Prompt 3 — Home + main app shell**: TabView + GroupHeader + lista
  de eventos próximos.
- **Prompt 4 — Event creation flow**: el "Crear primer evento" del
  paso 6 fundador finalmente tiene destino real.
- **Prompt 5 — Rule engine UX**: editar reglas + propose/vote.
- **V2 follow-ups**: AASA real, Apple Wallet real, group types con
  presets, anuario, achievements.

---

**Espero tu review antes de implementar.** Confirmá las 10 decisiones
de §13 (o decime cuáles cambiar) y arrancamos.
