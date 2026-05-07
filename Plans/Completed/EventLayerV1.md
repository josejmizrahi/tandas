# ruul — Event Layer V1

**Branch**: `claude/event-layer-v1`
**Status**: PLAN — awaiting review before implementation
**Depends on**: `claude/onboarding-v1` merged (which depends on
`claude/design-system-liquid-glass-d4x9M`)

---

## 0. Resumen ejecutivo

Implementar el event layer (crear/ver/RSVP/check-in) consumiendo el DS
V1 + Onboarding V1. El sistema reusa la tabla `event_attendance` y RPCs
existentes (`create_event`, `set_rsvp`, `check_in_attendee`, `close_event`,
`roll_event_series`) con extensiones aditivas para soportar covers,
descripción, ubicación geo, recurrencia opt-in, y check-in híbrido.

**MainTabView** se crea aquí (era stub `MainPlaceholderView` en
onboarding V1). Tab principal: HomeView.

**Edge Functions**: 2 críticas (`auto-generate-events` cron + `auto-close-
events` cron). Las otras 2 (`send-event-notification`, `generate-wallet-
pass`) van como stubs si APNs/Wallet certs no están listos.

**Bloqueante absoluto**: 4 decisiones de §1 sin confirmar (APNs certs,
Wallet certs, recurrencia client-vs-edge, MainTabView ubicación). Plan
asume defaults razonables — confirmá antes de aprobar.

---

## 1. Respuestas a las 12 preguntas

### 1.1 ¿Onboarding implementado y funcional?
**Sí**, en `claude/onboarding-v1` (10 commits + 11 del DS V1). Cualquier
grupo creado tiene `created_by` (founder), reglas iniciales, miembros
válidos. **PERO** §1 del followup de onboarding flagea que el grupo se
crea como `auth.uid()`-required pero el usuario no está autenticado al
step 2 — esto es un blocker para producción real, NO para event layer
(que opera sobre grupos que ya existen). Para tests + dev, cualquier
grupo creado vía `MockGroupsRepository` funciona.

### 1.2 ¿APNs certs configurados?
**No verificable desde el repo.** No hay cert files, no hay APNs key
configurada en el `Tandas.local.xcconfig`, no veo registro APNs en
`TandasApp.init`. Plan asume **NO configurados**. Implementación V1:
- **Local notifications**: completas (`UNUserNotificationCenter`).
  Schedule 24h/2h/start. Cancel on RSVP change. Trabajan offline. Listo
  para shippear.
- **Remote notifications**: stub. `NotificationTokenRepository` registra
  el token al iniciar app (si granted) y lo guarda en
  `notification_tokens` table — pero las edge functions que dispararían
  push remoto (event creation, host reminders, deadline warnings) NO
  envían APNs realmente, solo loguean. Cuando configures APNs,
  swap el stub por una llamada real.

**Para wirear remote en V1.x**: 
1. Apple Developer → Certificates → APNs Auth Key
2. Supabase Dashboard → Settings → Auth → Apple Push Configuration
3. Edge function `send-event-notification` ya tiene la firma correcta;
   solo cambia el body para llamar APNs vía supabase-js helper.

### 1.3 ¿Apple Wallet Pass Type ID + cert?
**No.** Sin cert, sin Pass Type ID, sin entitlement
(`com.apple.developer.pass-type-identifiers`). Plan: **stub completo**.
- `WalletPassService.generatePass(forEvent:)` retorna `nil` y loguea.
- "Agregar a Wallet" button en `RSVPStateView` solo aparece si
  `WalletPassService.isAvailable == true` (V1 = false).
- QR personal del check-in sigue funcionando como sub-sheet en
  `EventDetailView` (no requiere Wallet).
- Real Wallet en V1.x cuando tengas cert + edge function que firme
  `.pkpass`.

### 1.4 ¿Migrations onboarding ya corrieron?
**No verificable desde el repo.** La migration `00011_onboarding_v1.sql`
está committed en `claude/onboarding-v1`. **Asumo**: tú la corres en
Supabase con `supabase db push` antes de validar este event layer
contra la BD real.

Esta nueva migration es `00012_event_layer_v1.sql` y es aditiva (no
toca columnas existentes de events / event_attendance). Si 00011 no
corrió, 00012 sigue funcionando porque no depende de 00011 — usa
`events`, `event_attendance`, `groups` que existen desde Phase 1.

### 1.5 ¿Tests existentes que pueda romper?
- 5 tests Phase 1 (`MockAuthServiceTests`, etc.) — intactos.
- 1 test del DS V1 (`TokenResolutionTests`) — intacto.
- 21 tests onboarding V1 (`FounderOnboardingCoordinatorTests`,
  `InvitedOnboardingCoordinatorTests`, util tests) — intactos.
- `HappyPathTests` UI — sigue disabled.

Plan agrega ~30 tests más (event repos + coordinators + services).
Ningún test existente se rompe.

### 1.6 ¿`MainTabView` existe?
**No.** Onboarding V1 dejó un stub `MainPlaceholderView` en
`Shell/AuthGate.swift`. Plan crea **`MainTabView`** que reemplaza el
stub. V1 tiene 1 tab (Home); más tabs vendrán en prompts futuros
(Rules → prompt 4, Settings → prompt 5).

### 1.7 ¿Edge Functions disponibles? Runtime?
**Sí, Deno.** Onboarding V1 ya shippeo 3 edge functions
(`send-otp`, `verify-otp`, `send-whatsapp-invite`) en
`supabase/functions/` con Deno + `@supabase/supabase-js` via esm.sh.
Nuevas edge functions siguen el mismo patrón.

### 1.8 ¿Secret server-side para QR signing?
**No existe.** Plan crea **un nuevo secret** `RUUL_QR_SIGNING_SECRET`
(32 bytes random). Se usa en:
- Backend: `generate-wallet-pass` (cuando exista) firma el QR del pass
  con HMAC-SHA256(secret, payload).
- iOS: `QRSignatureService` valida durante check-in scanner usando
  el mismo secret. **Riesgo**: el secret debe estar en el cliente
  iOS (en `Tandas.local.xcconfig`) Y en Supabase secrets. Si el cliente
  se compromete, todos los grupos se afectan.

**Alternativa más segura V1.x**: solo backend firma; cliente envía el
QR scanned al backend para verificar. +1 round-trip per scan, pero
más seguro. **Plan V1 va con shared secret por simplicidad** —
documentamos el upgrade path.

### 1.9 ¿Galería `EventCovers/` ya existe?
**No.** El onboarding V1 no usó assets — `RuulCoverCatalog` genera
covers programáticos (10 mesh-gradient covers identificados por string
key: "sunset", "midnight", "citrus", "ocean", "forest", "candy",
"ember", "lilac", "mint", "clay"). Reuso el mismo catalog para events.
- `events.cover_image_name` puede contener un id del catalog
  ("sunset") O una URL si el host subió foto custom.
- `RuulCoverView` renderiza desde el id; AsyncImage para URLs custom.

Si más adelante quieres assets reales (PNG/HEIC), agregan `.imageset`
y el catalog acepta ambos paths. No bloquea V1.

### 1.10 ¿Analytics SDK conectado?
**LogAnalyticsService** (no-op + OSLog) wired en onboarding V1.
PostHog, Mixpanel, etc. no conectados. Plan extiende
`AnalyticsEvent` enum con los 13 nuevos eventos del prompt + sigue
usando `LogAnalyticsService`. Cuando wireas PostHog (V1.x), todos
los eventos fluyen automáticamente.

### 1.11 ¿`NSCameraUsageDescription` en Info.plist?
**No.** Plan agrega:
```xml
<key>NSCameraUsageDescription</key>
<string>Para escanear códigos QR y marcar llegadas a tus eventos.</string>
```

### 1.12 ¿`NSLocationWhenInUseUsageDescription` en Info.plist?
**No.** Plan agrega:
```xml
<key>NSLocationWhenInUseUsageDescription</key>
<string>Para sugerir ubicaciones cercanas y verificar llegadas a eventos.</string>
```

---

## 2. Migración Supabase

Archivo nuevo: `supabase/migrations/00012_event_layer_v1.sql`. Aditivo,
idempotente.

### 2.1 Cambios a `groups`
```sql
alter table public.groups
  add column if not exists auto_generate_events boolean not null default false;
```

### 2.2 Cambios a `events`
```sql
alter table public.events
  add column if not exists cover_image_name text,
  add column if not exists cover_image_url text,
  add column if not exists description text,
  add column if not exists location_lat numeric(10, 7),
  add column if not exists location_lng numeric(10, 7),
  add column if not exists apply_rules boolean not null default true,
  add column if not exists is_recurring_generated boolean not null default false,
  add column if not exists closed_at timestamptz,
  add column if not exists cancellation_reason text,
  add column if not exists duration_minutes int default 180;

-- Status: existing values are scheduled/in_progress/completed/cancelled.
-- The Swift EventStatus enum maps:
--   .upcoming  → 'scheduled'
--   .inProgress→ 'in_progress'
--   .closed    → 'completed'
--   .cancelled → 'cancelled'
```

### 2.3 Cambios a `event_attendance`
```sql
alter table public.event_attendance
  add column if not exists check_in_method text
    check (check_in_method in ('self','qr_scan','host_marked')),
  add column if not exists check_in_location_verified boolean not null default false;
```

### 2.4 Tabla `notification_tokens` (nueva)
```sql
create table if not exists public.notification_tokens (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  token text not null,
  platform text not null default 'ios' check (platform in ('ios','android','web')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(user_id, token)
);

create index if not exists idx_notif_tokens_user on public.notification_tokens(user_id);

alter table public.notification_tokens enable row level security;

create policy notif_tokens_self on public.notification_tokens
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());
```

### 2.5 RPCs nuevas / extendidas
```sql
-- create_event extended: cover, description, lat/lng, apply_rules,
-- is_recurring_generated. Wraps existing create_event semantics +
-- supports the new richer payload from CreateEventView.
create or replace function public.create_event_v2(
  p_group_id uuid,
  p_title text,
  p_starts_at timestamptz,
  p_duration_minutes int default 180,
  p_location_name text default null,
  p_location_lat numeric default null,
  p_location_lng numeric default null,
  p_host_id uuid default null,
  p_cover_image_name text default null,
  p_cover_image_url text default null,
  p_description text default null,
  p_apply_rules boolean default true,
  p_is_recurring_generated boolean default false
) returns public.events
language plpgsql security definer set search_path = public as $$
declare
  e public.events;
  g public.groups;
  v_cycle int;
  v_host uuid;
  v_ends_at timestamptz;
begin
  if not public.is_group_member(p_group_id, auth.uid()) then
    raise exception 'not a member';
  end if;

  select * into g from public.groups where id = p_group_id;
  v_cycle := (select coalesce(max(cycle_number), 0) + 1
              from public.events where group_id = p_group_id);
  v_host := coalesce(p_host_id,
    case when g.rotation_enabled then public.next_host_for_group(p_group_id, v_cycle) else null end);
  v_ends_at := p_starts_at + make_interval(mins => p_duration_minutes);

  insert into public.events (
    group_id, title, starts_at, ends_at, location, location_lat, location_lng,
    host_id, cycle_number, rsvp_deadline, cover_image_name, cover_image_url,
    description, apply_rules, is_recurring_generated, duration_minutes, created_by
  ) values (
    p_group_id, p_title, p_starts_at, v_ends_at,
    p_location_name, p_location_lat, p_location_lng,
    v_host, v_cycle, p_starts_at - interval '4 hours',
    p_cover_image_name, p_cover_image_url, p_description,
    p_apply_rules, p_is_recurring_generated, p_duration_minutes, auth.uid()
  ) returning * into e;

  -- Pre-create attendance rows for all active members (existing pattern).
  insert into public.event_attendance (event_id, user_id)
    select e.id, gm.user_id
    from public.group_members gm
    where gm.group_id = p_group_id and gm.active
    on conflict do nothing;

  return e;
end;
$$;
revoke execute on function public.create_event_v2(uuid, text, timestamptz, int, text, numeric, numeric, uuid, text, text, text, boolean, boolean) from public, anon;
grant  execute on function public.create_event_v2(uuid, text, timestamptz, int, text, numeric, numeric, uuid, text, text, text, boolean, boolean) to authenticated;

-- check_in_v2: extends check_in_attendee with method + location verification.
create or replace function public.check_in_v2(
  p_event_id uuid,
  p_user_id uuid,
  p_method text default 'self',
  p_location_verified boolean default false,
  p_arrived_at timestamptz default null
) returns public.event_attendance
language plpgsql security definer set search_path = public as $$
declare
  g uuid; att public.event_attendance;
begin
  if p_method not in ('self','qr_scan','host_marked') then
    raise exception 'invalid method';
  end if;
  select group_id into g from public.events where id = p_event_id;
  if not (auth.uid() = p_user_id or public.is_group_admin(g, auth.uid())) then
    raise exception 'not allowed';
  end if;
  update public.event_attendance
    set arrived_at = coalesce(p_arrived_at, now()),
        marked_by = auth.uid(),
        check_in_method = p_method,
        check_in_location_verified = p_location_verified
    where event_id = p_event_id and user_id = p_user_id
    returning * into att;
  return att;
end;
$$;
revoke execute on function public.check_in_v2(uuid, uuid, text, boolean, timestamptz) from public, anon;
grant  execute on function public.check_in_v2(uuid, uuid, text, boolean, timestamptz) to authenticated;

-- cancel_event: marks event cancelled with optional reason.
create or replace function public.cancel_event(
  p_event_id uuid,
  p_reason text default null
) returns public.events
language plpgsql security definer set search_path = public as $$
declare e public.events;
begin
  select * into e from public.events where id = p_event_id;
  if not found then raise exception 'event not found'; end if;
  if not (public.is_group_admin(e.group_id, auth.uid()) or e.host_id = auth.uid()) then
    raise exception 'host or admin only';
  end if;
  update public.events
    set status = 'cancelled', cancellation_reason = p_reason, updated_at = now()
    where id = p_event_id
    returning * into e;
  return e;
end;
$$;
revoke execute on function public.cancel_event(uuid, text) from public, anon;
grant  execute on function public.cancel_event(uuid, text) to authenticated;

-- close_event_no_fines: V1 closes event WITHOUT firing rule engine.
-- Phase 4 will replace this with one that calls evaluate_event_rules.
-- We don't drop the existing close_event (it auto-rolls the next event);
-- this v2 just changes the closed_at + status without rule eval.
create or replace function public.close_event_no_fines(p_event_id uuid)
returns public.events
language plpgsql security definer set search_path = public as $$
declare e public.events;
begin
  select * into e from public.events where id = p_event_id;
  if not found then raise exception 'event not found'; end if;
  if not (public.is_group_admin(e.group_id, auth.uid()) or e.host_id = auth.uid()) then
    raise exception 'host or admin only';
  end if;
  update public.events
    set status = 'completed', closed_at = now(), updated_at = now()
    where id = p_event_id
    returning * into e;
  return e;
end;
$$;
revoke execute on function public.close_event_no_fines(uuid) from public, anon;
grant  execute on function public.close_event_no_fines(uuid) to authenticated;

-- next_event_for_group: helper used by client to compute "next scheduled
-- event" without N+1 queries.
create or replace function public.next_event_for_group(p_group_id uuid)
returns public.events
language sql stable security definer set search_path = public as $$
  select * from public.events
  where group_id = p_group_id and status = 'scheduled' and starts_at >= now()
  order by starts_at asc limit 1;
$$;
grant execute on function public.next_event_for_group(uuid) to authenticated;
```

### 2.6 RLS policies (additivas)
Las políticas existentes para `events` / `event_attendance` siguen
aplicando. Solo agregamos políticas para `notification_tokens` (ya
arriba).

### 2.7 Rollback
Archivo: `supabase/migrations/00012_rollback.sql`. Drop nuevas RPCs +
columns + tabla `notification_tokens`. (No dropea event_attendance
columns porque podrían tener datos en producción real — solo plan,
documentado.)

---

## 3. Modelos Swift

Estructura nueva en `ios/Tandas/Models/Events/`.

### 3.1 Event + EventDraft
```swift
struct Event: Identifiable, Codable, Sendable, Hashable {
    let id: UUID
    let groupId: UUID
    let title: String
    let coverImageName: String?       // RuulCoverCatalog id, "sunset" etc.
    let coverImageURL: URL?            // custom upload
    let description: String?
    let startsAt: Date
    let endsAt: Date?
    let durationMinutes: Int
    let locationName: String?
    let locationLat: Double?
    let locationLng: Double?
    let hostId: UUID?
    let applyRules: Bool
    let status: EventStatus
    let cancellationReason: String?
    let isRecurringGenerated: Bool
    let parentEventId: UUID?
    let cycleNumber: Int?
    let rsvpDeadline: Date?
    let closedAt: Date?
    let createdBy: UUID
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, title, description, status
        case groupId               = "group_id"
        case coverImageName        = "cover_image_name"
        case coverImageURL         = "cover_image_url"
        case startsAt              = "starts_at"
        case endsAt                = "ends_at"
        case durationMinutes       = "duration_minutes"
        case locationName          = "location"
        case locationLat           = "location_lat"
        case locationLng           = "location_lng"
        case hostId                = "host_id"
        case applyRules            = "apply_rules"
        case cancellationReason    = "cancellation_reason"
        case isRecurringGenerated  = "is_recurring_generated"
        case parentEventId         = "parent_event_id"
        case cycleNumber           = "cycle_number"
        case rsvpDeadline          = "rsvp_deadline"
        case closedAt              = "closed_at"
        case createdBy             = "created_by"
        case createdAt             = "created_at"
    }
}

struct EventDraft: Sendable, Hashable {
    var title: String = ""
    var coverImageName: String?
    var coverImageURL: URL?
    var description: String = ""
    var startsAt: Date
    var durationMinutes: Int = 180
    var locationName: String?
    var locationLat: Double?
    var locationLng: Double?
    var hostId: UUID?
    var applyRules: Bool = true
    var recurrenceOption: RecurrenceOption = .onlyThis

    var isReadyToPublish: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty
    }

    static func empty(suggestedDate: Date) -> EventDraft {
        EventDraft(startsAt: suggestedDate)
    }
}
```

### 3.2 Enums
```swift
enum EventStatus: String, Codable, Sendable, Hashable {
    case scheduled
    case inProgress = "in_progress"
    case completed         // UI label = "Cerrado"
    case cancelled

    var displayName: String {
        switch self {
        case .scheduled:  return "Próximo"
        case .inProgress: return "Pasando ahora"
        case .completed:  return "Cerrado"
        case .cancelled:  return "Cancelado"
        }
    }
}

enum RSVPStatus: String, Codable, Sendable, Hashable {
    case pending
    case going
    case maybe
    case declined          // UI label = "No voy"

    var displayName: String {
        switch self {
        case .pending:  return "Sin responder"
        case .going:    return "Voy"
        case .maybe:    return "Tal vez"
        case .declined: return "No voy"
        }
    }
}

enum CheckInMethod: String, Codable, Sendable, Hashable {
    case selfMethod   = "self"
    case qrScan       = "qr_scan"
    case hostMarked   = "host_marked"
}

enum RecurrenceOption: String, Codable, Sendable, Hashable, CaseIterable {
    case onlyThis        // create only this event
    case nextFour        // create next 4
    case untilCancelled  // set groups.auto_generate_events = true

    var displayName: String {
        switch self {
        case .onlyThis:       return "Solo este por ahora"
        case .nextFour:       return "Sí, los siguientes 4 eventos"
        case .untilCancelled: return "Sí, todos hasta que cancele"
        }
    }
}
```

### 3.3 RSVP + CheckIn
```swift
struct RSVP: Identifiable, Codable, Sendable, Hashable {
    let id: UUID
    let eventId: UUID
    let userId: UUID
    let status: RSVPStatus
    let respondedAt: Date?
    let cancelledReason: String?
    let arrivedAt: Date?
    let checkInMethod: CheckInMethod?
    let checkInLocationVerified: Bool
    let markedBy: UUID?

    enum CodingKeys: String, CodingKey {
        case id
        case eventId                  = "event_id"
        case userId                   = "user_id"
        case status                   = "rsvp_status"
        case respondedAt              = "rsvp_at"
        case cancelledReason          = "cancelled_reason"
        case arrivedAt                = "arrived_at"
        case checkInMethod            = "check_in_method"
        case checkInLocationVerified  = "check_in_location_verified"
        case markedBy                 = "marked_by"
    }

    var isCheckedIn: Bool { arrivedAt != nil }
}
```

---

## 4. Repositorios

### 4.1 EventRepository
```swift
protocol EventRepository: Actor {
    func upcomingEvents(in groupId: UUID, limit: Int) async throws -> [Event]
    func pastEvents(in groupId: UUID, limit: Int) async throws -> [Event]
    func event(_ id: UUID) async throws -> Event
    func nextEvent(in groupId: UUID) async throws -> Event?
    func createEvent(_ draft: EventDraft, in groupId: UUID) async throws -> Event
    func updateEvent(_ id: UUID, patch: EventPatch) async throws -> Event
    func cancelEvent(_ id: UUID, reason: String?) async throws -> Event
    func closeEvent(_ id: UUID) async throws -> Event
}

struct EventPatch: Sendable, Equatable {
    var title: String?
    var description: String?
    var coverImageName: String?
    var coverImageURL: URL?
    var startsAt: Date?
    var durationMinutes: Int?
    var locationName: String?
    var locationLat: Double?
    var locationLng: Double?
    var hostId: UUID?
    var applyRules: Bool?
}
```

`LiveEventRepository` calls `create_event_v2`, `cancel_event`,
`close_event_no_fines`. Uses `from('events').update(...)` for partial
patches. `LiveEventRepository.createEvent` handles
`RecurrenceOption.nextFour` by looping (4 calls to `create_event_v2`)
and `.untilCancelled` by additionally setting
`groups.auto_generate_events = true` via direct update.

### 4.2 RSVPRepository
```swift
protocol RSVPRepository: Actor {
    func rsvps(for eventId: UUID) async throws -> [RSVP]
    func myRSVP(for eventId: UUID) async throws -> RSVP?
    func setRSVP(eventId: UUID, status: RSVPStatus, reason: String?) async throws -> RSVP
}
```

`LiveRSVPRepository.setRSVP` calls existing `set_rsvp` RPC. For
`reason`, do an additional `update event_attendance set cancelled_reason
= ...` after the RPC succeeds.

### 4.3 CheckInRepository
```swift
protocol CheckInRepository: Actor {
    func selfCheckIn(eventId: UUID, locationVerified: Bool) async throws -> RSVP
    func hostMarkCheckIn(eventId: UUID, memberId: UUID) async throws -> RSVP
    func qrScanCheckIn(eventId: UUID, memberId: UUID) async throws -> RSVP
}
```

All three call `check_in_v2` RPC with the appropriate `method` value.

### 4.4 NotificationTokenRepository
```swift
protocol NotificationTokenRepository: Actor {
    func registerToken(_ token: String) async throws
    func revokeToken(_ token: String) async throws
}
```

`LiveNotificationTokenRepository.registerToken` upserts to
`notification_tokens`. Called from `NotificationService.didRegisterDevice
Token(_:)`.

### 4.5 Mocks
Each `Live*Repository` has a corresponding `Mock*Repository` actor for
tests. Mocks support optimistic-update simulation (success/failure
toggles + state inspection).

---

## 5. Services

### 5.1 NotificationService
```swift
@MainActor
@Observable
final class NotificationService {
    enum AuthorizationStatus { case notDetermined, denied, granted, provisional }
    private(set) var authorizationStatus: AuthorizationStatus = .notDetermined

    func requestAuthorization() async -> Bool
    func registerForRemoteNotifications()
    func didRegisterDeviceToken(_ token: Data) async
    func scheduleLocalReminders(for event: Event, vocabulary: String) async
    func cancelLocalReminders(for eventId: UUID) async
    func handleDeepLink(from notification: UNNotification) -> EventDeepLink?
}

struct EventDeepLink: Sendable, Hashable {
    let eventId: UUID
}
```

Schedule strategy:
- **24h before** `starts_at`: "Mañana es [vocabulario] en casa de [host]".
- **2h before**: "[Vocabulario] empieza en 2h. ¿Confirmas?"
- **at start**: "Empezó el [vocabulario]. Marca tu llegada."

Identifier per notification: `"event-\(eventId)-\(slot)"` so we can
selectively cancel.

### 5.2 LocationSearchService
Wraps `MKLocalSearchCompleter`. Returns suggestions as the user types in
the location field. Coordinates resolved on selection via `MKLocalSearch`.

```swift
@MainActor @Observable
final class LocationSearchService: NSObject, MKLocalSearchCompleterDelegate {
    var query: String = "" { didSet { completer.queryFragment = query } }
    private(set) var suggestions: [MKLocalSearchCompletion] = []
    func resolve(_ suggestion: MKLocalSearchCompletion) async -> CLPlacemark?
}
```

### 5.3 WalletPassService
```swift
protocol WalletPassService: Sendable {
    var isAvailable: Bool { get }
    func generatePass(for event: Event, member: Member) async -> URL?
}

final class StubWalletPassService: WalletPassService {
    var isAvailable: Bool { false }
    func generatePass(for event: Event, member: Member) async -> URL? {
        os_log(.debug, "Wallet pass would be generated for event=\(event.id)")
        return nil
    }
}
```

V1.x impl: `LiveWalletPassService` calls edge function
`generate-wallet-pass` returning a `.pkpass` URL; client opens with
`PKAddPassesViewController`.

### 5.4 EventLifecycleService
Status transitions + recurring generation.

**Recurring generation strategy V1**: client-side trigger.

When the host calls `closeEvent(_:)` and the event is
`is_recurring_generated == true` (or the group has
`auto_generate_events == true`), the client queries
`groups.frequency_type/config` and creates the next event via
`createEvent` automatically. This avoids needing a cron edge function
for V1.

For "siguientes 4" path: at create time, loop synchronously creating 4
events at frequency cadence. Simple, predictable.

For "todos hasta cancelar" path: same client-trigger pattern. The flag
`auto_generate_events` is queried by the close-event handler.

**Edge function** (`auto-generate-events` cron): added but optional —
runs hourly, ensures groups with `auto_generate_events=true` have at
least 4 future events. Acts as a safety net if a host never closes
events. Stubbed if Edge Function deploy is too complex for V1; the
client-trigger handles the common case.

### 5.5 QRScannerService + QRSignatureService
```swift
@MainActor @Observable
final class QRScannerService: NSObject, AVCaptureMetadataOutputObjectsDelegate {
    enum State { case idle, scanning, found(String), error(String) }
    private(set) var state: State = .idle

    func start() async throws
    func stop()
}

enum QRSignatureService {
    static func sign(eventId: UUID, memberId: UUID, secret: String) -> String
    static func verify(payload: String, secret: String) -> (eventId: UUID, memberId: UUID)?
}
```

**Format**: `<eventId>:<memberId>:<base64(HMAC-SHA256(secret, "eventId:memberId"))>`.

Secret in `Tandas.local.xcconfig` (gitignored), exposed as
`Bundle.main.infoDictionary["RuulQRSecret"]`.

**Permissions**: camera permission requested at first tap of "Modo
check-in". If denied, show `EmptyStateView` with deeplink to Settings.

### 5.6 EventScheduler (utility)
```swift
enum EventScheduler {
    /// Computes the next N event dates given a frequency + start date.
    static func nextDates(
        from: Date,
        count: Int,
        type: FrequencyType,
        config: FrequencyConfig,
        in calendar: Calendar
    ) -> [Date]
}
```

Handles weekly (7-day stride), biweekly (14), monthly (`Calendar.date
ByAdding(.month, ...)` with day-of-month fallback for Feb 28/29 etc.).
`unscheduled` returns empty.

---

## 6. Coordinators

Cuatro `@Observable @MainActor` coordinators:

### 6.1 HomeCoordinator
```swift
@Observable @MainActor
final class HomeCoordinator {
    private(set) var nextEvent: Event?
    private(set) var upcomingEvents: [Event] = []
    private(set) var myRSVPs: [UUID: RSVP] = [:]   // keyed by eventId
    private(set) var isLoading: Bool = false
    private(set) var error: EventError?

    func refresh(for groupId: UUID) async
    func presentCreate()
    func presentDetail(_ event: Event)
}
```

Cache refresh on `.onAppear` if stale > 5 min. Pull-to-refresh forces
refresh.

### 6.2 EventCreationCoordinator
```swift
@Observable @MainActor
final class EventCreationCoordinator {
    var draft: EventDraft
    private(set) var isPublishing: Bool = false
    private(set) var error: EventError?
    private(set) var createdEvent: Event?
    let recurrenceAvailable: Bool   // true if first event in group AND group has frequency

    init(group: Group, hasExistingEvents: Bool, ...) { ... }

    func publish() async
}
```

`recurrenceAvailable` decides whether `RecurrenceOptionsCard` is shown.

### 6.3 EventDetailCoordinator
```swift
@Observable @MainActor
final class EventDetailCoordinator {
    private(set) var event: Event
    private(set) var rsvps: [RSVP] = []
    private(set) var myRSVP: RSVP?
    private(set) var isLoading: Bool = false
    private(set) var error: EventError?
    let viewerRole: ViewerRole       // .host | .guest
    let walletService: any WalletPassService

    enum ViewerRole { case host, guest }

    func refresh() async
    func setRSVP(_ status: RSVPStatus, reason: String?) async
    func selfCheckIn() async
    func hostMarkCheckIn(memberId: UUID) async
    func cancelEvent(reason: String?) async
    func closeEvent() async
    func sendHostReminders() async
    func generateWalletPass() async -> URL?
}
```

Optimistic UI: `setRSVP` updates `myRSVP` in-memory immediately, then
calls repo. On error, reverts + shows toast.

### 6.4 CheckInScannerCoordinator
```swift
@Observable @MainActor
final class CheckInScannerCoordinator {
    private(set) var recentCheckIns: [(memberId: UUID, name: String, at: Date)] = []
    private(set) var feedbackOverlay: Overlay?
    private(set) var checkedCount: Int
    let totalConfirmed: Int

    enum Overlay: Equatable {
        case success(name: String)
        case alreadyCheckedIn(name: String)
        case invalid
    }

    func handleScan(_ payload: String) async
}
```

Throttles overlay to 1.5s before resuming scan.

---

## 7. Views

### 7.1 Lista priorizada (orden de implementación)

**Bloque A — leaf views (no dependencies)**
1. `EventCard` (replaces `EventCardStub` from DS)
2. `LocationAutocompletePicker` (uses `LocationSearchService`)
3. `RecurrenceOptionsCard` (conditional component for CreateEventView)
4. `MemberQRSheet` (renders QR via Core Image)

**Bloque B — sub-views**
5. `RSVPStateView` — already exists in DS as a stub. **Verify** if it's
   real enough for the 4 RSVP states. If not, extend with concrete
   bindings (the DS version may need a small upgrade — coordinate with
   me before changing the DS).
6. `AttendeesListSection` — sectioned by RSVP status, animates on
   change.
7. `EventHostActionsSection` — host-only actions panel.
8. `CheckInSection` — guest + host check-in UI.

**Bloque C — sheets**
9. `EditEventSheet`, `RemindAttendeesSheet`, `CancelEventSheet`,
   `CancelAttendanceSheet`, `CloseEventSheet` (all wrappers around
   `ModalSheetTemplate` from DS).

**Bloque D — full screens**
10. `CreateEventView` (uses RecurrenceOptionsCard, LocationAutocomplete,
    cover picker)
11. `EventDetailView` (uses RSVPStateView + AttendeesListSection +
    EventHostActionsSection + CheckInSection)
12. `EditEventView` (similar to Create with pre-filled data)
13. `CheckInScannerView` (full-screen camera overlay)
14. `PastEventsView` (chronological reverse list)
15. `HomeView` (FAB, hero card, upcoming list, history link)
16. `MainTabView` (tab container; replaces `MainPlaceholderView`)

### 7.2 Patrones

- Detail uses `RuulFullScreenCover` (slide-up) per spec — the DS
  primitive `RuulFullScreenCover` from V1 already supports drag-to-
  dismiss.
- All edits/cancellation/etc. open as `.ruulSheet` (medium detent
  default, large for forms).
- Glass-morph between RSVP states uses `.matchedGeometryEffect` with
  `RuulMotion.morph` spring.
- Avatar grid in attendees uses `LazyVGrid` with animation triggered by
  count change.

---

## 8. Notifications detail

### 8.1 Local-only V1 path
```swift
// On RSVP change to .going
await notificationService.scheduleLocalReminders(for: event, vocabulary: group.eventVocabulary)
```

3 notifications scheduled with identifiers
`"event-{id}-24h"`, `"event-{id}-2h"`, `"event-{id}-start"`.

### 8.2 Remote path (stub V1, real V1.x)
- `NotificationService.didRegisterDeviceToken(_:)` calls
  `notificationTokenRepo.registerToken(_)`.
- Edge function `send-event-notification` exists but its body is a stub
  that loguea + returns `{sent: false}` until APNs is configured. Real
  impl: query tokens for group, send via APNs HTTP/2.

### 8.3 Permission UX
- Requested at first tap of "Voy" RSVP (lazy permission per spec).
- If denied: silently skip scheduling, no error.
- Subsequent "Voy" taps don't re-prompt.

---

## 9. Tests

Total estimated: ~30 unit tests + ~15 snapshot stubs.

### 9.1 Unit (swift-testing)

**Repository tests (~10)**
- `EventRepositoryTests`: upcoming filters by status='scheduled' + future
  dates; createEvent with .nextFour creates 4 rows; cancelEvent updates
  status.
- `RSVPRepositoryTests`: setRSVP upserts via mock; setRSVP optimistic
  failure rollback.
- `CheckInRepositoryTests`: each method ('self', 'qr_scan',
  'host_marked') sets `check_in_method` correctly.

**Coordinator tests (~10)**
- `HomeCoordinatorTests`: refresh populates nextEvent + upcomingEvents;
  empty state when no events.
- `EventCreationCoordinatorTests`: recurrenceAvailable true only when
  first event AND group has frequency; publish creates event +
  optionally additional 4 if `nextFour`.
- `EventDetailCoordinatorTests`: viewerRole .host shows host actions;
  setRSVP optimistic update; rollback on error; closeEvent triggers
  recurring generation if applicable.
- `CheckInScannerCoordinatorTests`: valid QR → success overlay; invalid
  signature → invalid overlay; already-checked → alreadyCheckedIn
  overlay.

**Service tests (~10)**
- `EventSchedulerTests`: weekly stride; biweekly; monthly with
  31-day-month edge case; unscheduled returns []; respects timezone.
- `QRSignatureServiceTests`: sign/verify roundtrip; tampered payload
  rejected; wrong secret rejected.
- `NotificationServiceTests`: schedule populates 3 identifiers; cancel
  clears them; deep link parsing.

### 9.2 Snapshot
Deferred until you can generate baselines on Mac. Plan documents which
views/states.

### 9.3 Tests that change
None of the existing tests break. Adding 30+ new in
`ios/TandasTests/Events/`.

---

## 10. Estructura de archivos

```
ios/Tandas/Features/Events/
├── Coordinator/
│   ├── HomeCoordinator.swift
│   ├── EventCreationCoordinator.swift
│   ├── EventDetailCoordinator.swift
│   └── CheckInScannerCoordinator.swift
├── Views/
│   ├── HomeView.swift
│   ├── CreateEventView.swift
│   ├── EditEventView.swift
│   ├── EventDetailView.swift
│   ├── PastEventsView.swift
│   ├── CheckInScannerView.swift
│   └── MainTabView.swift
├── Subviews/
│   ├── EventCard.swift
│   ├── RSVPStateView.swift                  # extend the DS stub if needed
│   ├── AttendeesListSection.swift
│   ├── EventHostActionsSection.swift
│   ├── CheckInSection.swift
│   ├── RecurrenceOptionsCard.swift
│   └── LocationAutocompletePicker.swift
└── Sheets/
    ├── EditEventSheet.swift
    ├── RemindAttendeesSheet.swift
    ├── CancelEventSheet.swift
    ├── CancelAttendanceSheet.swift
    ├── CloseEventSheet.swift
    └── MemberQRSheet.swift

ios/Tandas/Models/Events/
├── Event.swift
├── EventDraft.swift
├── EventStatus.swift
├── RSVP.swift
├── RSVPStatus.swift
├── CheckInMethod.swift
└── RecurrenceOption.swift

ios/Tandas/Supabase/Repos/
├── EventRepository.swift            # NEW
├── RSVPRepository.swift             # NEW
├── CheckInRepository.swift          # NEW
└── NotificationTokenRepository.swift # NEW

ios/Tandas/Services/
├── Notifications/
│   ├── NotificationService.swift
│   └── EventDeepLink.swift
├── Location/
│   └── LocationSearchService.swift
├── Wallet/
│   └── (extend existing WalletPassGenerator → WalletPassService)
├── Lifecycle/
│   └── EventLifecycleService.swift
├── QR/
│   ├── QRScannerService.swift
│   └── QRSignatureService.swift
└── Analytics/
    └── (extend AnalyticsEvent enum with 13 new events)

ios/Tandas/Utilities/
├── EventScheduler.swift
├── QRCodeGenerator.swift
└── Date+EventFormatting.swift

ios/TandasTests/Events/
├── EventRepositoryTests.swift
├── RSVPRepositoryTests.swift
├── CheckInRepositoryTests.swift
├── HomeCoordinatorTests.swift
├── EventCreationCoordinatorTests.swift
├── EventDetailCoordinatorTests.swift
├── CheckInScannerCoordinatorTests.swift
├── EventSchedulerTests.swift
├── QRSignatureServiceTests.swift
└── NotificationServiceTests.swift

supabase/
├── migrations/
│   ├── 00012_event_layer_v1.sql
│   └── 00012_rollback.sql
└── functions/
    ├── auto-generate-events/index.ts   # cron, optional V1
    ├── auto-close-events/index.ts      # cron
    ├── send-event-notification/index.ts # stub V1
    └── generate-wallet-pass/index.ts   # stub V1

Plans/
└── EventLayerV1.md                     # this file
```

---

## 11. Plan de ejecución (commits sugeridos)

Total estimado: ~15 commits.

### Bloque 0 — backend
1. `db: 00012 event layer migration (events+columns, event_attendance
   columns, notification_tokens table, 4 RPCs)`
2. `edge: auto-close-events cron + send-event-notification stub +
   generate-wallet-pass stub`

### Bloque 1 — Swift foundations
3. `feat(models/events): Event, EventDraft, EventStatus, RSVP,
   RSVPStatus, CheckInMethod, RecurrenceOption`
4. `feat(repos/events): EventRepository, RSVPRepository,
   CheckInRepository, NotificationTokenRepository (Live + Mock)`
5. `feat(services/events): NotificationService, LocationSearchService,
   QRScannerService, QRSignatureService, EventScheduler`
6. `feat(services): EventLifecycleService + WalletPassService stub
   + analytics events extended`

### Bloque 2 — coordinators + tests
7. `feat(events): HomeCoordinator + EventCreationCoordinator +
   EventDetailCoordinator + CheckInScannerCoordinator`
8. `test(events): repository + coordinator + service tests (~30)`

### Bloque 3 — leaf views + subviews
9. `feat(events): EventCard + RecurrenceOptionsCard +
   LocationAutocompletePicker + MemberQRSheet`
10. `feat(events): RSVPStateView (extend DS stub) + AttendeesListSection
    + EventHostActionsSection + CheckInSection`
11. `feat(events): 5 sheets — Edit, RemindAttendees, CancelEvent,
    CancelAttendance, CloseEvent`

### Bloque 4 — full screens
12. `feat(events): CreateEventView + EditEventView`
13. `feat(events): EventDetailView`
14. `feat(events): CheckInScannerView`
15. `feat(events): HomeView + PastEventsView + MainTabView (replaces
    MainPlaceholderView)`

### Bloque 5 — wiring
16. `feat: AppState extended with eventRepo+rsvpRepo+checkInRepo+
    notificationService; AuthGate routes authenticated users to
    MainTabView; Info.plist adds NSCameraUsageDescription +
    NSLocationWhenInUseUsageDescription`

---

## 12. Decisiones a confirmar antes de implementar

1. **APNs stub V1, real V1.x** (per §1.2). Local notifications are
   real and work offline; remote push functions log only.
2. **Wallet stub V1, real V1.x** (per §1.3). "Add to Wallet" button
   never shows in V1 since `isAvailable=false`.
3. **Recurrence: client-trigger as primary, edge function as safety
   net**. Hosts who close events trigger generation locally.
   `auto-generate-events` cron is optional but I'll include it with a
   simple impl.
4. **MainTabView created here** with 1 tab (Home). More tabs in future
   prompts. Replaces `MainPlaceholderView`.
5. **Schema mapping**: keep `event_attendance` (not new `rsvps` table),
   keep `events.notes` and add `events.description` (Swift maps
   `description`), reuse `cancelled_reason` for "no voy con razón".
6. **EventStatus mapping**: UI says "upcoming/inProgress/closed/
   cancelled"; DB says "scheduled/in_progress/completed/cancelled". Map
   `.upcoming → scheduled` and `.closed → completed` in CodingKeys.
7. **No new `check_ins` table**: extend `event_attendance` with
   `check_in_method` + `check_in_location_verified`. Less duplication.
8. **QR signing secret shared between client + server** (per §1.8). Less
   secure than backend-only validation but simpler V1; documented as
   V2 upgrade.
9. **`close_event` V1**: NEW `close_event_no_fines` RPC. Phase 4 will
   add a `close_event_with_fines` that calls `evaluate_event_rules`.
10. **Event covers** = same `RuulCoverCatalog` as onboarding (10 mesh-
    gradient covers). No new asset files.
11. **`RSVPStateView` from DS V1** is currently a stub; verify before I
    extend. If extending, will be a small DS PR (similar to the V1.1
    primitives I added for onboarding).
12. **NO renombrar target Xcode `Tandas` → `Ruul`** (consistent with
    V1 / Onboarding V1).

---

## 13. Riesgos identificados

### 13.1 RSVPStateView upgrade
The DS V1 ships `RSVPStateView` as a stub pattern (per onboarding V1
plan §6 patterns). The Event Layer needs a real implementation with 4
distinct visual states + `.matchedGeometryEffect` glass-morph. **Risk**:
extending a "stub" pattern in the DS to be real is exactly the kind of
DS modification the prompt forbids. **Mitigation**: I'll either (a) ship
a small DS PR upgrading the stub to real (like the V1.1 primitives for
onboarding) BEFORE event layer, or (b) fork into
`Features/Events/Subviews/RSVPStateView.swift` and keep the DS stub
unchanged. **Recommendation: (a) — proper DS upgrade**. Confirm.

### 13.2 Camera permission UX in simulator
Simulator can't actually access camera. `CheckInScannerView` shows
black screen + console warning in simulator. Snapshot tests will need
to mock the AVCaptureSession layer.

### 13.3 LocationSearchService behind privacy alerts
First search triggers `NSLocationWhenInUseUsageDescription` prompt.
Even though the search itself doesn't strictly need location auth
(MKLocalSearchCompleter works without it), iOS may prompt. Document.

### 13.4 EventStatus rename collisions
Existing Phase 1 SQL uses `'scheduled'`. UI says "Próximo / Cerrado".
Mapping is clean via CodingKeys but anyone reading raw Postgres rows
will see "scheduled" not "upcoming". Document.

### 13.5 Recurrence edge cases
Monthly recurrence on day 31 → February has no day 31. EventScheduler
falls back to last day of month. Test coverage for this is critical.

### 13.6 QR signing secret distribution
The shared secret is in `Tandas.local.xcconfig` (gitignored). On a
fresh machine you have to set it manually. Document in README.

### 13.7 Auto-generation race condition
If 2 hosts close 2 events simultaneously and both trigger generation,
we could create duplicate "next" events. Mitigation: idempotency check
via `parent_event_id` (existing column from migration 00004) — the
RPC `roll_event_series` already does this. Reuse the pattern in
client-side trigger.

---

## 14. DoD del PR final

- [ ] `make -C ios test` pasa (incluyendo ~30 nuevos tests).
- [ ] `make -C ios build` sin warnings nuevos (Swift 6 strict).
- [ ] `supabase db push` aplica `00012_event_layer_v1.sql` sin errores.
- [ ] Edge functions `auto-close-events` desplegada (otras stubeadas).
- [ ] Cada vista tiene `#Preview` bloque.
- [ ] Info.plist incluye `NSCameraUsageDescription` +
      `NSLocationWhenInUseUsageDescription`.
- [ ] `Tandas.local.xcconfig` template incluye `RUUL_QR_SECRET=`
      (vacío, debe ser set manualmente).
- [ ] AuthGate enruta usuarios autenticados a MainTabView.
- [ ] HappyPathTests sigue disabled (otra rewrite pending).

---

## 15. Lo que viene después

- **Prompt 4 — Rule engine + multas**: extiende `close_event_no_fines`
  → `close_event_with_fines` que llama `evaluate_event_rules`. UI de
  multas en `RuleCardStub` real, MultasView, apelaciones.
- **Prompt 5 — Balance + pagos**: `pay_fine` RPC, balance per member,
  payment methods.
- **V1.x infra**: APNs cert + remote notifications real, Wallet cert +
  `.pkpass` real, AASA deploy, anonymous Supabase auth.

---

**Espero tu review antes de implementar.** Confirmá las 12 decisiones
de §12 (especialmente: APNs/Wallet stubs OK, recurrence client-trigger
strategy, RSVPStateView upgrade approach) y arrancamos.
