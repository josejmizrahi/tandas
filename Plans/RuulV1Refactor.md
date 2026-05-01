# Ruul V1 — Refactor Plan

> Branch: `claude/refactor-ios-onboarding-8rWbi`
> Status: **Draft 2 — esperando review antes de codear**
> Supersedes: `Plans/OnboardingRefactor.md` (draft 1, scope multi-tipo)
> Date: 2026-05-01

V1 es un refactor de base mucho más amplio que un onboarding: replantea
brand, schema, onboarding (founder + invited), event layer básico,
balance y Apple Wallet — todo bajo el principio "publica ya, refina
después".

---

## 0. Cambios vs draft 1

| Tema | Draft 1 (multi-tipo) | V1 (genérico) |
|---|---|---|
| Brand | "Tandas" o "Ruul" (Q1 abierta) | **Ruul** (decidido) |
| Tipos de grupo | 6 con presets | **Sin tipos**, todo genérico |
| Onboarding fundador | 8 pasos | **6 pasos** |
| Schema groups | columns adicivas (frequency, modules, propose_mode...) | **Greenfield** drop+recreate |
| Votaciones | sí | **No en V1** |
| Comité, fund, pots, expenses | conservados | **Removidos** del schema V1 |
| Reglas: status proposed/active/archived | sí | **`is_active` + `rule_type` enum** |
| Event layer | out of scope | **In scope** (crear, RSVP, check-in, cerrar) |
| Balance | out of scope | **Lista mínima + payment methods externos** |
| Apple Wallet | no mencionado | **Pass per evento confirmado** |
| Apelaciones | vía vote | **Decisión del host** (texto libre + accept/reject) |
| Folder | `ios/Tandas/` | **`ios/Ruul/`** + rename Xcode target |
| Multi-grupo | sí | **Un grupo activo a la vez** en V1 |
| Rotación host | automática | **Manual** por evento |

---

## 1. Preguntas críticas V1

### Q1 — Schema strategy: greenfield o adapt?
El schema V1 (groups, members, rules, events, rsvps, check_ins, fines,
appeals) es **forma muy distinta** de los 10 migrations actuales:
- `members` reemplaza `group_members` (nombre y campos diferentes).
- `rules` cambia de `trigger jsonb + action jsonb + status enum` a
  `rule_type enum + config jsonb + is_active bool`.
- `events` pierde `cycle_number`, `rotation_enabled`, `rsvp_deadline`.
- `event_attendance` se split en `rsvps` + `check_ins`.
- `fines` pierde `paid_to_fund`, `waived`, `auto_generated`,
  `appeal_vote_id`. Gana `status enum` + tabla `appeals` separada.
- Tablas borradas: `votes`, `vote_ballots`, `pots`, `pot_entries`,
  `expenses`, `expense_shares`, `payments`.

**Mi recomendación**: greenfield. Migration 00011 hace `drop ... cascade`
de todas las tablas de phases anteriores (sin data en producción) y
crea V1 desde cero. Rule engine también se reescribe (`evaluate_event_rules_v1`).
Trade-off: tiramos ~2000 líneas de SQL pulido (Phase 1-4.6) que
volveremos a necesitar cuando V2/V3 reincorporen tipos, votos, fund.

**Alternativa**: adaptar. Mantener tablas existentes y mapear V1 a los
campos que ya existen (e.g., `members` aliasea `group_members`,
`rsvps` = view sobre `event_attendance`). Más cirugía, sin perder SQL.

**¿Greenfield (mi rec) o adapt?**

### Q2 — Wassenger ahora sí (V1 lo dobla)
El brief V1 dice **"WhatsApp OTP preferido (Wassenger), SMS fallback
automático"** sin más detalle. Hoy la auth usa Supabase Phone OTP (SMS
nativo). Para Wassenger necesito saber:

- ¿Hay cuenta Wassenger ya creada? ¿API key disponible?
- ¿Acepto que la integración sea: Edge Function `tandas-otp-send` +
  `tandas-otp-verify` que generan/validan códigos contra una tabla
  `otp_codes`, y luego emiten un magic-link de Supabase para crear
  la sesión? (custom flow, NO usa Auth Hooks oficiales)
- O alternativa: ¿hookear Supabase Auth → SMS Hook (función PG
  `auth.send_sms`) que rutea a Wassenger en lugar de Twilio? Esto
  requiere acceso a auth schema, que Supabase **bloquea** en projects
  Free/Pro hasta el plan Team. **¿Estás en Team?**

**Mi recomendación**: V1 ship con SMS (Supabase nativo). Wassenger
queda detrás de un `protocol OTPDelivery` listo para inyectar en V1.1
cuando confirmemos cuenta + plan Supabase. Si quieres Wassenger ahora,
necesito las dos respuestas (cuenta + plan).

### Q3 — Folder + project rename Tandas → Ruul
Hoy: `ios/Tandas/`, `Tandas.xcodeproj` (generado), `TandasApp.swift`,
test targets `TandasTests`/`TandasUITests`, scheme `Tandas`. Bundle
ID ya es `com.josejmizrahi.ruul` y display `Ruul`. ¿Renombro todo a
`Ruul`?

**Mi recomendación**: sí. En el mismo PR. Es mecánico (file moves +
sed en `project.yml` + sed en imports `@testable import Tandas` →
`Ruul` + sed en strings literales). El repo se sigue llamando
`tandas/` por GitHub history; el código y el producto pasan a Ruul.
Confirma y procedo.

### Q4 — Rule engine: server-side, client-side o ambos?
El brief lista `Services/RuleEngine.swift` en el árbol. Pero
client-side significa que un cliente malicioso puede skipear multas.
Server-side (RPC) es la única forma segura.

**Mi recomendación**: rule engine canónico es server-side (RPC
`evaluate_event_v1(p_event_id)` que corre al cerrar evento).
`Services/RuleEngine.swift` en cliente es un **preview helper**: dado
un evento + check-ins, predice qué multas se generarían. Permite
mostrar el "preview de multas" en `CloseEventFlow` antes de confirmar.
La fuente de verdad sigue siendo SQL.

### Q5 — Apple Wallet pass: ¿lo shippeamos en V1?
PassKit requiere:
- **Pass Type ID** registrado en Apple Developer
- **Pass signing certificate** privado (.p12)
- **Backend que firma** los .pkpass dinámicamente (Edge Function
  Supabase con OpenSSL)
- Bundle entitlement `com.apple.developer.passkit`

Es trabajo no trivial (~2 días extra). **¿Tienes Pass Type ID?
¿Quieres que lo configure ahora o queda en V1.1?**

**Mi recomendación**: V1 muestra el botón "Add to Wallet" en estado
`disabled` con copy "Próximamente". Cuando esté listo el cert, el
mismo botón se activa. No bloquea nada del flow.

### Q6 — Universal Links domain
El brief dice `ruul.app`. Asumo lo controlas. Necesito:
- AASA file en `https://ruul.app/.well-known/apple-app-site-association`
- Entitlement `com.apple.developer.associated-domains` con
  `applinks:ruul.app`

¿Listo el dominio + DNS + algún server (Vercel, Cloudflare) que
sirva el AASA con `Content-Type: application/json` y HTTPS válido?

**Mi recomendación**: lo configuro en el plan. Mientras el AASA no
esté servido, el invitado puede pegar el invite code manual como
fallback (no rompe nada).

### Q7 — Auth timing: anonymous sign-in
**El brief V1 dice explícitamente**: "al final del paso 2, el grupo
está vivo en Supabase". Eso requiere `auth.uid()` antes del paso 2,
o sea **antes** de pedir teléfono (que es paso 5a).

Solución: `auth.signInAnonymously()` al iniciar el flujo del fundador
(paso 0 → 1). Eso da una sesión válida con un user row en `auth.users`
sin email/phone. En paso 5a, llamamos `updateUser(phone:)` + verifyOTP
que vincula el phone al **mismo** user UUID. Sin pérdida de datos.

**Riesgos**:
- Anonymous sign-in tiene que estar **habilitado** en Supabase
  dashboard (Auth → Providers → Anonymous). ¿Está? Si no, lo activo
  con MCP.
- Si el usuario abandona en paso 3, queda un user anónimo + grupo
  huérfano sin miembros confirmados (excepto el founder anónimo).
  Limpiable con `pg_cron` weekly que borra anonymous users >7 días sin
  phone vinculado y `cascade delete` los grupos.

**Mi recomendación**: anonymous sign-in habilitado + cron de limpieza.
Plan asume esto.

### Q8 — `rules.config` shape per `rule_type`
V1 reduce reglas a un enum + jsonb config. Defino las shapes por tipo:

```swift
// rule_type: "late"
{ "base_amount": 200, "step_amount": 50, "step_minutes": 30, "max_amount": null }

// rule_type: "no_rsvp"
{ "amount": 200, "deadline_offset_hours": 24, "deadline_hour_local": 20 }

// rule_type: "cancel_same_day"
{ "amount": 200 }

// rule_type: "no_show"
{ "amount": 300 }

// rule_type: "host_no_menu"
{ "amount": 200, "deadline_offset_hours": 24 }

// rule_type: "manual" (host la dispara a mano)
{ "amount": 0, "label": "Custom" }
```

¿Te suenan los defaults? El cliente puede editar `amount` inline; el
server valida `amount >= 0`.

### Q9 — Cover gallery: cuántos covers y de dónde
Brief: "8-10 covers genéricos en `Assets.xcassets/EventCovers/`".
¿Tienes assets ya o los genero? Para draft puedo poner placeholders
de `MeshGradient` programáticos (no es lo ideal pero unblocks
desarrollo). ¿Cómo prefieres?

**Mi recomendación**: arranco con 10 mesh-gradient covers programáticos
(zero asset shipping size, fáciles de variar). Reemplazables más tarde
con PNGs reales sin tocar el código del picker.

### Q10 — MapKit autocomplete vs solo TextField
Brief: "TextField ubicación con autocomplete via MapKit". Eso usa
`MKLocalSearchCompleter` + `MKLocalSearch`. Sin API key, gratis.
Privacy: requiere `NSLocationWhenInUseUsageDescription` solo si pides
ubicación del usuario; el autocomplete por sí solo NO lo requiere.

**Mi recomendación**: autocomplete sin pedir location del user.
Resultados son sugerencias globales por texto. Si el usuario quiere
"cerca de mí", añadimos un botón `Use my location` que sí pide
permiso. V1 → solo autocomplete genérico.

---

## 2. Schema V1 (migration 00011)

Asumiendo Q1 = greenfield. Si Q1 = adapt, este SQL se rehace.

```sql
-- 00011_ruul_v1_greenfield.sql

-- 1. Drop anteriores (cascade limpia FK)
drop view if exists public.group_balances cascade;
drop function if exists public.evaluate_event_rules(uuid) cascade;
drop function if exists public.create_group_with_admin(...) cascade;
drop function if exists public.join_group_by_code(text) cascade;
-- ... (todos los RPCs de phases 1-4.6)
drop table if exists public.payments cascade;
drop table if exists public.expense_shares cascade;
drop table if exists public.expenses cascade;
drop table if exists public.pot_entries cascade;
drop table if exists public.pots cascade;
drop table if exists public.fines cascade;
drop table if exists public.vote_ballots cascade;
drop table if exists public.votes cascade;
drop table if exists public.event_attendance cascade;
drop table if exists public.events cascade;
drop table if exists public.rules cascade;
drop table if exists public.group_members cascade;
drop table if exists public.groups cascade;
-- profiles SE QUEDA (vinculado a auth.users via trigger handle_new_user)

-- 2. Recreate V1 shape

create table public.groups (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(name) between 1 and 80),
  cover_image_url text,
  event_vocabulary text not null default 'evento',
  frequency_type text check (frequency_type in ('weekly','biweekly','monthly','unscheduled')),
  frequency_config jsonb not null default '{}'::jsonb,
  fines_enabled boolean not null default true,
  grace_period_events int not null default 3 check (grace_period_events >= 0),
  invite_code text not null unique default substr(md5(random()::text || clock_timestamp()::text), 1, 8),
  founder_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger groups_set_updated_at before update on public.groups
for each row execute function public.set_updated_at();
create index idx_groups_founder on public.groups(founder_id);

create table public.members (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.groups(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  display_name text,
  avatar_url text,
  is_founder boolean not null default false,
  joined_at_event_count int not null default 0,
  joined_at timestamptz not null default now(),
  unique(group_id, user_id)
);
create index idx_members_user on public.members(user_id);
create index idx_members_group on public.members(group_id);

create table public.rules (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.groups(id) on delete cascade,
  rule_type text not null check (rule_type in ('late','no_rsvp','cancel_same_day','no_show','host_no_menu','manual')),
  is_active boolean not null default true,
  config jsonb not null,
  created_at timestamptz not null default now()
);
create index idx_rules_group on public.rules(group_id);

create table public.events (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.groups(id) on delete cascade,
  title text not null,
  cover_image_url text,
  description text,
  scheduled_at timestamptz not null,
  location_name text,
  location_lat numeric,
  location_lng numeric,
  host_id uuid references public.members(id) on delete set null,
  apply_rules boolean not null default true,
  status text not null default 'upcoming' check (status in ('upcoming','in_progress','closed')),
  closed_at timestamptz,
  created_by uuid references public.members(id) on delete set null,
  created_at timestamptz not null default now()
);
create index idx_events_group on public.events(group_id);
create index idx_events_scheduled on public.events(scheduled_at);
create index idx_events_status on public.events(status);

create table public.rsvps (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  member_id uuid not null references public.members(id) on delete cascade,
  status text not null default 'pending' check (status in ('going','maybe','not_going','pending')),
  responded_at timestamptz,
  unique(event_id, member_id)
);
create index idx_rsvps_event on public.rsvps(event_id);

create table public.check_ins (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  member_id uuid not null references public.members(id) on delete cascade,
  checked_in_at timestamptz not null default now(),
  unique(event_id, member_id)
);

create table public.fines (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  member_id uuid not null references public.members(id) on delete cascade,
  rule_id uuid references public.rules(id) on delete set null,
  amount numeric(12,2) not null check (amount >= 0),
  reason text not null,
  status text not null default 'pending' check (status in ('pending','paid','appealed','cancelled')),
  generated_by text not null default 'auto' check (generated_by in ('auto','manual')),
  created_at timestamptz not null default now(),
  unique(event_id, member_id, rule_id)  -- evita doble-multa idempotente
);
create index idx_fines_member on public.fines(member_id);
create index idx_fines_status on public.fines(status);

create table public.appeals (
  id uuid primary key default gen_random_uuid(),
  fine_id uuid not null references public.fines(id) on delete cascade,
  member_id uuid not null references public.members(id) on delete cascade,
  reason text not null,
  status text not null default 'pending' check (status in ('pending','accepted','rejected')),
  decided_by uuid references public.members(id) on delete set null,
  decided_at timestamptz,
  created_at timestamptz not null default now(),
  unique(fine_id)  -- una apelación por multa
);

-- 3. RLS policies (todas: solo miembros del grupo pueden leer/escribir)

alter table public.groups enable row level security;
alter table public.members enable row level security;
alter table public.rules enable row level security;
alter table public.events enable row level security;
alter table public.rsvps enable row level security;
alter table public.check_ins enable row level security;
alter table public.fines enable row level security;
alter table public.appeals enable row level security;

create or replace function public.is_group_member_v1(gid uuid, uid uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.members where group_id = gid and user_id = uid);
$$;

create policy groups_select on public.groups for select to authenticated
  using (founder_id = auth.uid() or public.is_group_member_v1(id, auth.uid()));
create policy groups_insert on public.groups for insert to authenticated
  with check (founder_id = auth.uid());
create policy groups_update on public.groups for update to authenticated
  using (founder_id = auth.uid());
-- (políticas equivalentes para members/rules/events/rsvps/check_ins/fines/appeals)

-- 4. RPCs V1

create or replace function public.create_group_v1(
  p_name text,
  p_cover_image_url text,
  p_event_vocabulary text,
  p_frequency_type text,
  p_frequency_config jsonb,
  p_fines_enabled boolean,
  p_grace_period_events int,
  p_initial_rules jsonb  -- [{rule_type, is_active, config}]
) returns public.groups
language plpgsql security definer set search_path = public as $$
declare g public.groups; rule_row jsonb; m public.members;
begin
  if auth.uid() is null then raise exception 'auth required'; end if;

  insert into public.groups (
    name, cover_image_url, event_vocabulary,
    frequency_type, frequency_config,
    fines_enabled, grace_period_events, founder_id
  ) values (
    p_name, p_cover_image_url, coalesce(p_event_vocabulary, 'evento'),
    p_frequency_type, coalesce(p_frequency_config, '{}'::jsonb),
    coalesce(p_fines_enabled, true), coalesce(p_grace_period_events, 3),
    auth.uid()
  ) returning * into g;

  insert into public.members (group_id, user_id, is_founder)
  values (g.id, auth.uid(), true) returning * into m;

  if p_initial_rules is not null then
    for rule_row in select * from jsonb_array_elements(p_initial_rules) loop
      insert into public.rules (group_id, rule_type, is_active, config)
      values (g.id, rule_row->>'rule_type',
              coalesce((rule_row->>'is_active')::boolean, true),
              rule_row->'config');
    end loop;
  end if;
  return g;
end;
$$;

create or replace function public.join_group_v1(p_invite_code text, p_display_name text, p_avatar_url text)
returns public.groups ...

create or replace function public.set_rsvp_v1(p_event_id uuid, p_status text)
returns public.rsvps ...

create or replace function public.check_in_v1(p_event_id uuid, p_member_id uuid)
returns public.check_ins ...

create or replace function public.close_event_v1(p_event_id uuid)
returns int ... -- corre rule engine, devuelve count de multas

create or replace function public.evaluate_event_v1(p_event_id uuid)
returns table (rule_id uuid, member_id uuid, amount numeric, reason text)
... -- preview puro: NO inserta, devuelve lo que `close_event_v1` insertaría

create or replace function public.appeal_fine_v1(p_fine_id uuid, p_reason text)
returns public.appeals ...

create or replace function public.decide_appeal_v1(p_appeal_id uuid, p_accept boolean)
returns public.appeals ... -- solo el host del evento o founder
```

(El SQL completo con políticas, RPCs y comentarios va a ser ~600
líneas. Lo escribo cuando confirmes Q1=greenfield. Si Q1=adapt, replanteo.)

### Rollback
- `git revert` del commit de la migration. Schema vuelve al estado
  Phase 4.6.
- Como zero data en producción, drop+recreate de la 00011 también es
  válido durante desarrollo.

### Apply
Vía MCP: `mcp__653f7f48...__apply_migration` con name
`ruul_v1_greenfield`.

---

## 3. Project rename (Tandas → Ruul)

Asumiendo Q3 = sí, lo hago en commit separado **antes** del refactor:

```
ios/Tandas/                  → ios/Ruul/
ios/TandasTests/             → ios/RuulTests/
ios/TandasUITests/           → ios/RuulUITests/
ios/Tandas.xcodeproj/        → ios/Ruul.xcodeproj/   (regenerado por xcodegen)
ios/project.yml              → name: Ruul (sed)
ios/Tandas/TandasApp.swift   → ios/Ruul/RuulApp.swift
ios/Tandas/Resources/Tandas.entitlements → Ruul.entitlements
@testable import Tandas      → @testable import Ruul (sed)
```

Strings literales user-facing ya están en español ("Bienvenido a…"
no menciona Tandas excepto en `LoginView` "Ruul" header — ya consistente).
El folder `supabase/`, las migrations y el repo path no cambian
(GitHub: `josejmizrahi/tandas`).

Bundle ID `com.josejmizrahi.ruul` se queda. Display `Ruul` se queda.

---

## 4. Modelos Swift V1

```
ios/Ruul/Models/
├── Group.swift                  [REWRITE V1 shape]
├── GroupDraft.swift             [NEW — coordinador del founder]
├── Member.swift                 [REWRITE: standalone, ya no es group_members]
├── Rule.swift                   [NEW]
├── RuleType.swift               [NEW: enum late|no_rsvp|cancel_same_day|no_show|host_no_menu|manual]
├── RuleConfig.swift             [NEW: typed config per RuleType]
├── RulePreset.swift             [NEW: 5 defaults para InitialRulesView]
├── FrequencyType.swift          [NEW]
├── FrequencyConfig.swift        [NEW]
├── Event.swift                  [NEW]
├── RSVP.swift                   [NEW]
├── RSVPStatus.swift             [NEW: enum going|maybe|notGoing|pending]
├── CheckIn.swift                [NEW]
├── Fine.swift                   [NEW]
├── FineStatus.swift             [NEW: enum pending|paid|appealed|cancelled]
├── Appeal.swift                 [NEW]
├── EventCover.swift             [NEW: enum con 10 mesh covers programáticos]
├── OnboardingProgress.swift     [NEW: @Model SwiftData]
├── Profile.swift                [keep]
├── ViewState.swift              [keep]
└── (DEL) GroupType.swift, CreateGroupParams, GroupDetail
```

`GroupDraft`:
```swift
struct GroupDraft: Codable, Sendable, Equatable {
    var name: String = ""
    var coverImageURL: URL?
    var eventVocabulary: String = "evento"
    var frequencyType: FrequencyType?
    var frequencyConfig: FrequencyConfig?
    var finesEnabled: Bool = true
    var rules: [RulePreset] = RulePreset.defaults
    static let empty = GroupDraft()
}
```

---

## 5. Repositories V1

```
ios/Ruul/Supabase/Repos/
├── AuthService.swift            [MOD: añade signInAnonymously, updatePhone]
├── ProfileRepository.swift      [keep, minor]
├── GroupRepository.swift        [REWRITE: createV1, fetchByInviteCode, generateInviteLink]
├── MemberRepository.swift       [NEW: list, leave, updateAvatar]
├── EventRepository.swift        [NEW: create, list, get, close]
├── RuleRepository.swift         [NEW: list, update, toggle]
├── RSVPRepository.swift         [NEW: setStatus, listForEvent]
├── CheckInRepository.swift      [NEW: checkIn, list]
├── FineRepository.swift         [NEW: listForMember, listForEvent, markPaid]
├── AppealRepository.swift       [NEW: create, decide]
└── InviteRepository.swift       [NEW: fetchPreview, generateLink]
```

Todos `actor` + Mock equivalente. Sendable.

---

## 6. Coordinators y Stores @Observable

```
ios/Ruul/Features/
├── Onboarding/
│   ├── Founder/Coordinator/
│   │   ├── FounderOnboardingCoordinator.swift
│   │   └── FounderStep.swift  (welcome|identity|groupIdentity|vocabularyFrequency|rules|invite|phoneVerify|confirmation)
│   └── Invited/Coordinator/
│       ├── InvitedOnboardingCoordinator.swift
│       └── InvitedStep.swift  (welcome|identity|verify|tour)
├── Events/Coordinator/
│   └── EventCoordinator.swift          (state per evento abierto)
└── Balance/Coordinator/
    └── BalanceCoordinator.swift
```

`FounderOnboardingCoordinator` clave:
- `advance()` para cada paso, valida draft, persiste en SwiftData
- En el paso 0 → 1: `auth.signInAnonymously()` (Q7 resolved)
- En el paso 2 (GroupIdentity al confirmar): llama
  `groupRepository.createV1(draft)` y guarda `currentGroup`
- En el paso 3-4: `update`s incrementales sobre el grupo ya creado
- En el paso 5a: `auth.updatePhone(...)` + `verifyOTP`
- En el paso 6: navega a destino seleccionado

Inyección por init, sin singletons.

---

## 7. Vistas V1

### Onboarding fundador (8 archivos: 6 pasos + 1 sub-paso + 1 root)

| Vista | Paso | Complejidad |
|---|---|---|
| `WelcomeView` | 0 | S — mesh + glass card + 1 CTA |
| `FounderIdentityView` | 1 | S — name + PhotosPicker |
| `GroupIdentityView` | 2 | M — name + cover gallery picker |
| `GroupVocabularyView` | 3 | M — chips + frequency picker condicional |
| `InitialRulesView` | 4 | L — 5 cards monto editable + skip "sin multas" |
| `InviteMembersView` | 5 | L — ShareLink + ContactsPicker + Skip |
| `PhoneVerifyView` | 5a | M — reusa OTPInput |
| `ConfirmationView` | 6 | M — 3 stacked CTAs accionables |

### Onboarding invitado (4 archivos)

| Vista | Paso | Complejidad |
|---|---|---|
| `InviteWelcomeView` | 1 | M — fetch preview + AvatarStack |
| `InvitedIdentityView` | 2 | S — name + photo |
| `InvitedVerifyView` | 3 | S — OTP |
| `GroupTourOverlay` | 4 | M — overlay glass + Wallet add (disabled si Q5=no) |

### Event Layer (5 archivos)

| Vista | Complejidad |
|---|---|
| `CreateEventView` | L — cover picker + datetime + MapKit autocomplete + host toggle + apply rules toggle |
| `EventDetailView` | L — header + RSVPStateView + lista invitados + acciones host |
| `RSVPStateView` | M — 3 estados visuales distintos como cards persistentes |
| `CloseEventFlow` | M — sheet con check-ins + preview multas + confirm |
| `AppealSheet` | S — TextField + submit |

### Balance (2 archivos)

| Vista | Complejidad |
|---|---|
| `BalanceView` | M — lista miembros con totales + sheet |
| `PaymentMethodsSheet` | S — links externos (Venmo/CLABE/etc.) |

### Shell

| Vista | Complejidad |
|---|---|
| `RootView` | M — ruta entre Login / Founder / Invited / Main |
| `MainTabView` | M — 3 tabs: Eventos / Reglas / Balance (V1 mínimo) |
| `LoginView` | M — simplificado: "Crear grupo" / "Tengo invitación" / "Iniciar sesión" |

**Total V1 ~22 vistas + 4 coordinators + ~600 LOC SQL + ~400 LOC
modelos + ~300 LOC repos + ~400 LOC componentes ≈ 4000-4500 LOC Swift.**

---

## 8. Componentes glass nuevos

`ios/Ruul/DesignSystem/Components/`:

| Componente | Uso | Reusa |
|---|---|---|
| `GlassChip` | Vocabulario, sugerencias nombre | adaptiveGlass(Capsule, tint:) |
| `GlassToggleCard` | Rules cards on/off | GlassCard |
| `OnboardingProgressBar` | Header fundador | Capsule + spring |
| `OnboardingContainer` | Layout común con bg + safe + skip | composes |
| `SkipButton` | ToolbarItem | plain |
| `CoverPicker` | Galería 10 covers programáticos | scroll horizontal de mesh thumbs |
| `AvatarStack` | InviteWelcomeView | GlassEffectContainer |
| `RSVPButton` | EventDetailView "Voy/Tal vez/No voy" | tres estados glass tinted |
| `RSVPStateCard` | post-RSVP persistent card | GlassCard tinted por status |
| `MeshBackground.warm` | Welcome views | nueva paleta cálida |
| `EventCoverThumbnail` | thumb en grid + EventDetail header | MeshGradient |
| `InvitedListCard` | Lista invitados agrupados por status | composición |

Reusa tal cual: `GlassCard`, `GlassCapsuleButton`, `Field`, `OTPInput`,
`adaptiveGlass`, `Brand` tokens, fonts.

---

## 9. Services

```
ios/Ruul/Services/
├── SupabaseClient.swift         [keep]
├── OTPService.swift             [NEW: protocol OTPDelivery, impls SMS (now) + Wassenger (later)]
├── AnalyticsService.swift       [NEW: protocol + OSLog impl + Noop mock]
├── RuleEngine.swift             [NEW: client preview only]
├── WalletPassGenerator.swift    [NEW (stub si Q5=defer)]
├── LocationCompleter.swift      [NEW: MKLocalSearchCompleter wrapper]
├── HapticManager.swift          [NEW: wraps .sensoryFeedback triggers]
├── PhoneFormatter.swift         [NEW: +52 normalization]
├── InviteLinkGenerator.swift    [NEW: ruul.app/invite/CODE]
└── OnboardingProgressStore.swift [NEW: SwiftData wrapper actor]
```

`String+Vocabulary.swift` extension:
```swift
extension String {
    static func eventNoun(for group: Group) -> String { group.eventVocabulary }
    static func eventNounPluralized(for group: Group) -> String { ... }
}
```

---

## 10. Universal Links

### Entitlements
```xml
<key>com.apple.developer.associated-domains</key>
<array><string>applinks:ruul.app</string></array>
```

### AASA en `https://ruul.app/.well-known/apple-app-site-association`
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

### App
```swift
// AppEnvironment.swift
@MainActor @Observable
final class AppEnvironment {
    var pendingInvite: String?
    let appState: AppState
    let analytics: any AnalyticsService
    let haptics: HapticManager

    func handleIncomingURL(_ url: URL) {
        guard url.host == "ruul.app",
              url.pathComponents.count >= 3,
              url.pathComponents[1] == "invite"
        else { return }
        pendingInvite = url.pathComponents[2]
    }
}
```

`RootView` enruta:
1. `pendingInvite != nil` y sin sesión → `InvitedOnboardingCoordinator`
2. `OnboardingProgress` activo en SwiftData → restaura coordinator
3. Sin sesión sin invite → `LoginView`
4. Con sesión sin grupos → `FounderOnboardingCoordinator`
5. Con sesión y grupos → `MainTabView`

---

## 11. Apple Wallet integration (Q5-dependent)

**Si Q5 = ship V1**:
- Edge Function `ruul-wallet-pass` (Deno+Supabase) firma `.pkpass` con
  cert privado almacenado en secrets
- Cliente llama al endpoint con `event_id`, recibe `.pkpass`, lo abre
  con `PKAddPassesViewController`
- Entitlement `com.apple.developer.passkit`

**Si Q5 = defer**: dejo botón "Add to Wallet" disabled con copy
"Próximamente" en `EventDetailView` (cuando RSVP=going) y
`GroupTourOverlay`. Reactivar = quitar el flag y conectar
`WalletPassGenerator` a la Edge Function.

---

## 12. SwiftData

```swift
@Model final class OnboardingProgress {
    @Attribute(.unique) var id: UUID
    var flowTypeRaw: String        // "founder" | "invited"
    var currentStepRaw: String     // FounderStep / InvitedStep .rawValue
    var draftJSON: Data            // GroupDraft o InvitedDraft encoded
    var inviteCode: String?
    var groupId: UUID?             // si paso 2 ya creó el grupo en Supabase
    var anonymousUserId: UUID?     // founder paso 0+ pre-phone link
    var updatedAt: Date
}
```

Schema versioned: si cambia el shape del draft, deserialize falla
silente y vuelve a paso 0. Aceptable para draft.

---

## 13. Permisos lazy

| Permiso | Cuándo | Cómo |
|---|---|---|
| Notifications | Al crear primer evento (post-onboarding) | `requestAuthorization` |
| Contacts | "Agregar por número" en paso 5 | `CNContactStore.requestAccess` |
| Photos | Avatar picker (PhotosPicker maneja) | n/a explícito |
| Location | Solo si user tap "cerca de mí" en CreateEvent | `CLLocationManager.requestWhenInUse` |
| Camera | n/a en V1 | — |

Ninguno al iniciar.

---

## 14. AnalyticsService eventos V1

Brief lista los eventos. Implementación:

```swift
enum AnalyticsEvent {
    // Onboarding
    case onboardingStarted(flow: FlowType)
    case onboardingStepCompleted(step: String, durationMs: Int)
    case onboardingStepSkipped(step: String)
    case onboardingAbandoned(lastStep: String, totalMs: Int)
    case onboardingCompleted(flow: FlowType, totalMs: Int)
    // Domain
    case groupCreated(groupId: UUID)
    case memberJoinedViaInvite(timeFromInviteSentSec: Int)
    case eventCreated(eventId: UUID, hasHost: Bool)
    case rsvpSubmitted(eventId: UUID, status: RSVPStatus)
    case eventClosed(eventId: UUID, autoOrManual: ClosedBy)
    case fineGenerated(ruleType: RuleType)
    case fineAppealed(fineId: UUID)
    case finePaid(fineId: UUID)
}
```

V1 ship con `OSLogAnalyticsService` (zero deps). Real SDK queda
detrás de protocol — cuando me digas cuál (PostHog/Mixpanel/Amplitude),
añado el wrapper en ~30 LOC.

---

## 15. Tests V1

Stack ya disponible: `swift-testing` + `swift-snapshot-testing` +
XCUITest.

```
ios/RuulTests/
├── ModelsTests.swift                  [REWRITE para shape V1]
├── GroupDraftTests.swift              [NEW]
├── RulePresetsTests.swift             [NEW: defaults shape correcto]
├── RuleEngineTests.swift              [NEW: cada rule_type, edge cases]
├── PhoneFormatterTests.swift          [NEW]
├── OnboardingProgressStoreTests.swift [NEW: SwiftData CRUD]
├── FounderCoordinatorTests.swift      [NEW: happy + skips + errors + restore from draft]
├── InvitedCoordinatorTests.swift      [NEW: happy + invalid invite + no session]
├── EventCoordinatorTests.swift        [NEW: create → RSVP → close]
├── BalanceCoordinatorTests.swift      [NEW]
├── MockAuthServiceTests.swift         [keep + extender]
├── MockRepositoriesTests.swift        [REWRITE: cubre los nuevos repos]
└── snapshots/                         [snapshot por vista clave: default + loading + error]

ios/RuulUITests/
├── HappyPathTests.swift               [REWRITE flow founder completo]
├── InviteFlowTests.swift              [NEW flow invitado]
└── EventLifecycleTests.swift          [NEW: crear → RSVP → close → multa]
```

`MockAuthService.sessionStream` bug pendiente (T18 nota en
HappyPathTests) lo arreglo de paso: replace `lazy var AsyncStream`
con un patrón continuation-registry confiable bajo concurrency.

---

## 16. Lo que NO hago en V1 (vs draft 1)

- ❌ Tipos de grupo + presets — fuera por scope V1
- ❌ Votos / `votes` / `vote_ballots` / comité — fuera
- ❌ Pots, expenses, payments, fund — fuera
- ❌ Rotación automática host — fuera (host manual)
- ❌ Multi-grupo simultáneo — fuera (un grupo activo)
- ❌ Anuario / Wrapped / lore / achievements — fuera
- ❌ Sign in with Apple para fundadores nuevos — fuera del onboarding
  (lo dejo en LoginView para usuarios recurrentes, ver Q3 del draft 1)
- ❌ Email OTP — fuera (sin email forzado en V1)

Si en implementación algo de esta lista parece imprescindible, pregunto.

---

## 17. Orden de ejecución

Cuando confirmes Q1-Q10:

1. **Project rename** (Tandas → Ruul) — commit aislado
2. **Migration 00011** — apply via MCP, verificar tablas
3. **Modelos Swift V1** — todos los structs/enums + GroupDraft
4. **Repos V1** + Mocks — cada uno con tests unit
5. **Services**: AnalyticsService, HapticManager, PhoneFormatter,
   OnboardingProgressStore, OTPService (SMS), RuleEngine (client preview),
   LocationCompleter
6. **Componentes glass nuevos**
7. **Auth update**: signInAnonymously + updatePhone
8. **FounderOnboardingCoordinator + 8 vistas**
9. **InvitedOnboardingCoordinator + 4 vistas**
10. **AppEnvironment + RootView + Universal Links wiring**
11. **Event Layer**: EventRepository, RSVPRepository, CheckInRepository,
    FineRepository, EventCoordinator, 5 vistas
12. **Balance**: BalanceCoordinator, 2 vistas
13. **MainTabView** mínimo (3 tabs)
14. **Borrar legacy**: AuthGate, OnboardingView, NewGroupWizard,
    EmptyGroupsView, JoinByCodeView (reemplazado), AuthViewModel,
    GroupSummaryView (reemplazado por EventDetail-equivalente)
15. **Tests**: unit + snapshot + UI
16. **Smoke** en simulador iOS 26

**Estimado**: 4-6 días de implementación lineal asumiendo Q1-Q10
respondidas y zero blockers de Wassenger/Wallet (Q2/Q5).

---

## 18. Resumen de preguntas que necesito antes de codear

| # | Pregunta | Mi rec |
|---|---|---|
| Q1 | Greenfield drop+recreate del schema, o adapt | Greenfield |
| Q2 | Wassenger ahora o en V1.1 | V1.1 (ship con SMS, OTPDelivery protocol listo) |
| Q3 | Rename ios/Tandas → ios/Ruul ahora | Sí |
| Q4 | RuleEngine server-side canónico, client preview | Sí, ambos |
| Q5 | Apple Wallet pass en V1 o V1.1 | V1.1 (botón disabled) |
| Q6 | Dominio ruul.app listo para AASA | Asumo sí, fallback código manual mientras |
| Q7 | Anonymous sign-in habilitado en Supabase | Lo activo con MCP si me confirmas |
| Q8 | Defaults de `rules.config` por tipo (ver §1.Q8) | Confirma valores |
| Q9 | 10 covers mesh-gradient programáticos vs PNG reales | Programáticos por ahora |
| Q10 | MapKit autocomplete sin pedir location | Sí |

Con un "sí a recomendaciones, ojo en X y Y" arranco la implementación
en el orden de §17.
