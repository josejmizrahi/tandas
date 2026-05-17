# Level 15 Notifications — Pass 1 + Pass 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development.

**Goal:** Devices list + 4 deeplink schemes + per-type notification preferences.

**Architecture:** Pass 1 extends `NotificationTokenRepository` with multi-device methods, adds `NotificationDeepLink` enum catalog, and wires `DevicesView` from a new NOTIFICACIONES section in `MyProfileView`. Pass 2 adds `notification_preferences` BE table + RPC + repo + UI.

**Tech Stack:** SwiftUI iOS 26+, Swift 6, Supabase RPC.

**Source spec:** `docs/superpowers/specs/2026-05-16-level-15-notifications.md`.

---

## Verified facts

- `NotificationTokenRepository` has `registerToken(_:)`, `revokeToken(_:)` (token-string based). We add `listMyDevices()`, `revoke(deviceId:)`.
- Latest mig: `00231`. Next: `00232` for notification_preferences.
- `AppState.handleIncomingURL` + `handleIncomingNotification` exist; currently support `event` + `ruleChange` deeplinks via separate types.
- `EventDeepLink`, `RuleChangeDeepLink` Swift structs already exist at `RuulCore/Services/Notifications/`.
- `MyProfileView` has sections IDENTIDAD, PREFERENCIAS, TU ACTIVIDAD, AJUSTES, APARIENCIA — no NOTIFICACIONES yet.
- `app.notificationTokenRepo` exists.

---

## Pass 1 — Devices + deeplinks (4 tasks)

### Task 1: NotificationTokenRepository extension + NotificationDevice model

**Files:**
- Modify: `ios/Packages/RuulCore/Sources/RuulCore/Repositories/NotificationTokenRepository.swift`
- Create: `ios/Packages/RuulCore/Sources/RuulCore/PlatformModels/NotificationDevice.swift`

Create the model:

```swift
import Foundation

/// One row from `notification_tokens` projected as a user-facing device.
public struct NotificationDevice: Identifiable, Sendable, Hashable, Codable {
    public let id: UUID
    public let userId: UUID
    public let token: String
    public let platform: String
    public let createdAt: Date
    public let updatedAt: Date

    public enum CodingKeys: String, CodingKey {
        case id, token, platform
        case userId    = "user_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    /// Masked representation for display (first 8 + last 4).
    public var tokenMasked: String {
        guard token.count > 12 else { return "•••" }
        return "\(token.prefix(8))…\(token.suffix(4))"
    }
}
```

Extend repository protocol:

```swift
public protocol NotificationTokenRepository: Actor {
    func registerToken(_ token: String) async throws
    func revokeToken(_ token: String) async throws
    // NEW
    func listMyDevices() async throws -> [NotificationDevice]
    func revoke(deviceId: UUID) async throws
}
```

Live impl:

```swift
public func listMyDevices() async throws -> [NotificationDevice] {
    let userId = try await client.auth.session.user.id
    return try await client
        .from("notification_tokens")
        .select()
        .eq("user_id", value: userId.uuidString.lowercased())
        .order("updated_at", ascending: false)
        .execute()
        .value
}

public func revoke(deviceId: UUID) async throws {
    try await client
        .from("notification_tokens")
        .delete()
        .eq("id", value: deviceId.uuidString.lowercased())
        .execute()
}
```

Mock impl: return seed `[NotificationDevice]` + delete by id.

Build + commit.

### Task 2: NotificationDeepLink enum catalog

Create `ios/Packages/RuulCore/Sources/RuulCore/Services/Notifications/NotificationDeepLink.swift`:

```swift
import Foundation

/// Unified deeplink catalog for push payloads. Server emits `deep_link`
/// with scheme `ruul://[kind]/[id]` (optional query params).
///
/// Replaces the per-type structs (EventDeepLink, RuleChangeDeepLink) for
/// new sites — existing structs can keep working for back-compat.
public enum NotificationDeepLink: Sendable, Hashable {
    case event(UUID)
    case vote(UUID)
    case fine(UUID)
    case ruleChange(ruleId: UUID, proposedAmount: Int?)

    public init?(url: URL) {
        guard let host = url.host?.lowercased() else { return nil }
        let path = url.pathComponents.dropFirst()  // skip "/"
        guard let firstPath = path.first, let id = UUID(uuidString: firstPath) else { return nil }
        switch host {
        case "event":
            self = .event(id)
        case "vote":
            self = .vote(id)
        case "fine":
            self = .fine(id)
        case "rule":
            // Optional query: ?proposedAmount=N
            var amount: Int?
            if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let val = comps.queryItems?.first(where: { $0.name == "proposedAmount" })?.value {
                amount = Int(val)
            }
            self = .ruleChange(ruleId: id, proposedAmount: amount)
        default:
            return nil
        }
    }

    public init?(userInfo: [AnyHashable: Any]) {
        // Look for "deep_link" string in APNs payload.
        guard let linkStr = userInfo["deep_link"] as? String,
              let url = URL(string: linkStr) else { return nil }
        self.init(url: url)
    }

    public var id: UUID {
        switch self {
        case .event(let id), .vote(let id), .fine(let id):
            return id
        case .ruleChange(let id, _):
            return id
        }
    }
}
```

Build + commit.

### Task 3: DevicesView

Create `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Profile/Subscreens/DevicesView.swift`:

```swift
import SwiftUI
import RuulUI
import RuulCore

@MainActor
public struct DevicesView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var devices: [NotificationDevice] = []
    @State private var isLoading = true
    @State private var error: String?
    @State private var currentDeviceToken: String?

    public init() {}

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: RuulSpacing.xl) {
                    if isLoading {
                        ProgressView().padding(RuulSpacing.lg)
                    } else if devices.isEmpty {
                        Text("Aún no hay dispositivos registrados.")
                            .ruulTextStyle(RuulTypography.body)
                            .foregroundStyle(Color.ruulTextTertiary)
                            .padding(RuulSpacing.lg)
                    } else {
                        if let current = currentDevice {
                            section(title: "ESTA SESIÓN") { row(current, isCurrent: true) }
                        }
                        let others = devices.filter { $0.id != currentDevice?.id }
                        if !others.isEmpty {
                            section(title: "OTRAS SESIONES") {
                                VStack(spacing: 0) {
                                    ForEach(others) { device in
                                        row(device, isCurrent: false)
                                        if device.id != others.last?.id {
                                            Divider().background(Color.ruulSeparator).padding(.leading, 56)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    if let error {
                        Text(error)
                            .ruulTextStyle(RuulTypography.footnote)
                            .foregroundStyle(Color.ruulNegative)
                            .padding(.horizontal, RuulSpacing.lg)
                    }
                }
                .padding(RuulSpacing.lg)
            }
            .background(Color.ruulBackground.ignoresSafeArea())
            .navigationTitle("Dispositivos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Cerrar") { dismiss() } } }
            .task { await load() }
        }
    }

    private var currentDevice: NotificationDevice? {
        guard let tok = currentDeviceToken else { return nil }
        return devices.first(where: { $0.token == tok })
    }

    @ViewBuilder
    private func section<Content: View>(title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text(title)
                .ruulTextStyle(RuulTypography.sectionLabel)
                .foregroundStyle(Color.ruulTextTertiary)
                .padding(.leading, RuulSpacing.xxs)
            content()
                .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.lg))
                .overlay(RoundedRectangle(cornerRadius: RuulRadius.lg).stroke(Color.ruulSeparator, lineWidth: 0.5))
        }
    }

    private func row(_ device: NotificationDevice, isCurrent: Bool) -> some View {
        HStack(spacing: RuulSpacing.md) {
            Image(systemName: device.platform == "ios" ? "iphone" : "questionmark.circle")
                .foregroundStyle(Color.ruulAccent)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(device.platform.capitalized)
                        .ruulTextStyle(RuulTypography.body)
                        .foregroundStyle(Color.ruulTextPrimary)
                    if isCurrent {
                        Text("(este)")
                            .ruulTextStyle(RuulTypography.caption)
                            .foregroundStyle(Color.ruulTextSecondary)
                    }
                }
                Text("Último uso: \(relativeTime(device.updatedAt))")
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextSecondary)
            }
            Spacer()
            if !isCurrent {
                Button("Revocar", role: .destructive) {
                    Task { await revoke(device.id) }
                }
                .ruulTextStyle(RuulTypography.captionBold)
            }
        }
        .padding(RuulSpacing.md)
    }

    private func relativeTime(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        f.locale = Locale(identifier: app.profile?.locale ?? "es-MX")
        return f.localizedString(for: date, relativeTo: .now)
    }

    private func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            devices = try await app.notificationTokenRepo.listMyDevices()
            // currentDeviceToken: cache from UserDefaults (registered at app launch)
            currentDeviceToken = UserDefaults.standard.string(forKey: "ruul.apns.current_token")
        } catch {
            self.error = "No pudimos cargar tus dispositivos."
        }
    }

    private func revoke(_ deviceId: UUID) async {
        do {
            try await app.notificationTokenRepo.revoke(deviceId: deviceId)
            await load()
        } catch {
            self.error = "No pudimos revocar el dispositivo."
        }
    }
}
```

Build + commit.

### Task 4: Wire NOTIFICACIONES section in MyProfileView + extend deeplink routing + tag

Modify `Features/Profile/Views/MyProfileView.swift`:

Add 2 new optional callbacks:
```swift
public var onOpenNotificationPreferences: (() -> Void)?
public var onOpenDevices: (() -> Void)?
```

Add section between PREFERENCIAS and AJUSTES (or wherever fits):

```swift
private var notificationsSection: some View {
    sectionContainer(title: "NOTIFICACIONES") {
        navRow(
            icon: "bell.badge",
            label: "Preferencias",
            action: { onOpenNotificationPreferences?() }
        )
        divider
        navRow(
            icon: "iphone.and.arrow.forward",
            label: "Dispositivos",
            action: { onOpenDevices?() }
        )
    }
}
```

Insert `notificationsSection` in body between `preferencesSection` and `settingsSection`.

Update init to accept the 2 new callbacks (nil default).

Wire from `ProfileTab.swift`:

```swift
@State private var showDevices = false
// preferences sheet wired in Pass 2 Task 7

// In MyProfileView(...) call:
onOpenNotificationPreferences: { /* Pass 2 */ },
onOpenDevices: { showDevices = true }

.fullScreenCover(isPresented: $showDevices) {
    DevicesView().environment(app)
}
```

Also extend deeplink routing in `AppState.handleIncomingURL` and `handleIncomingNotification`:

```swift
public func handleIncomingURL(_ url: URL) {
    if let link = NotificationDeepLink(url: url) {
        applyDeepLink(link)
        return
    }
    // ... existing invite/ruleChange/event handlers as fallback
}

private func applyDeepLink(_ link: NotificationDeepLink) {
    switch link {
    case .event(let id): pendingEventDeepLink = EventDeepLink(eventId: id)
    case .vote(let id): pendingVoteId = id  // add @Published if missing
    case .fine(let id): pendingFineId = id
    case .ruleChange(let id, let amount): pendingRuleChange = RuleChangeDeepLink(ruleId: id, proposedAmount: amount ?? 0)
    }
}
```

Add `@Published var pendingVoteId: UUID?` + `@Published var pendingFineId: UUID?` to AppState if absent. Consume them in RootShell to navigate post-auth.

Build + commit + tag:

```bash
git tag -a level15-pass1-complete -m "Level 15 — Pass 1 (devices + deeplink parity) complete"
```

---

## Pass 2 — Notification preferences (3 tasks)

### Task 5: BE migration `notification_preferences`

Create `supabase/migrations/00232_notification_preferences.sql` and apply via MCP:

```sql
-- Mig 00232: notification_preferences — per-user per-type opt-out.
create table public.notification_preferences (
    user_id           uuid not null references auth.users(id) on delete cascade,
    notification_type text not null,
    enabled           boolean not null default true,
    updated_at        timestamptz not null default now(),
    primary key (user_id, notification_type)
);

alter table public.notification_preferences enable row level security;

create policy "notification_preferences_self_read"
    on public.notification_preferences for select to authenticated
    using (user_id = auth.uid());

create policy "notification_preferences_self_write"
    on public.notification_preferences for insert to authenticated
    with check (user_id = auth.uid());

create policy "notification_preferences_self_update"
    on public.notification_preferences for update to authenticated
    using (user_id = auth.uid())
    with check (user_id = auth.uid());

-- Helper: upsert + return effective row.
create or replace function public.set_notification_preference(
    p_type text,
    p_enabled boolean
) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
    insert into public.notification_preferences (user_id, notification_type, enabled, updated_at)
    values (auth.uid(), p_type, p_enabled, now())
    on conflict (user_id, notification_type)
    do update set enabled = excluded.enabled, updated_at = excluded.updated_at;
end;
$$;

grant execute on function public.set_notification_preference(text, boolean) to authenticated;

-- Touch updated_at on row update.
create or replace function public.notification_preferences_touch_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end;
$$;
create trigger notification_preferences_touch_updated_at_trg
    before update on public.notification_preferences
    for each row execute function public.notification_preferences_touch_updated_at();
```

Commit the SQL.

### Task 6: NotificationPreferenceRepository

Create `ios/Packages/RuulCore/Sources/RuulCore/Repositories/NotificationPreferenceRepository.swift`:

```swift
import Foundation
import Supabase

public struct NotificationPreference: Identifiable, Sendable, Hashable, Codable {
    public let userId: UUID
    public let notificationType: String
    public let enabled: Bool
    public let updatedAt: Date

    public var id: String { "\(userId.uuidString)|\(notificationType)" }

    public enum CodingKeys: String, CodingKey {
        case enabled
        case userId           = "user_id"
        case notificationType = "notification_type"
        case updatedAt        = "updated_at"
    }
}

public protocol NotificationPreferenceRepository: Actor {
    func loadMine() async throws -> [NotificationPreference]
    func set(type: String, enabled: Bool) async throws
}

public actor MockNotificationPreferenceRepository: NotificationPreferenceRepository {
    public var prefs: [NotificationPreference] = []
    public init(seed: [NotificationPreference] = []) { self.prefs = seed }
    public func loadMine() async throws -> [NotificationPreference] { prefs }
    public func set(type: String, enabled: Bool) async throws {
        prefs.removeAll(where: { $0.notificationType == type })
        prefs.append(NotificationPreference(userId: UUID(), notificationType: type, enabled: enabled, updatedAt: .now))
    }
}

public actor LiveNotificationPreferenceRepository: NotificationPreferenceRepository {
    private let client: SupabaseClient
    public init(client: SupabaseClient) { self.client = client }

    public func loadMine() async throws -> [NotificationPreference] {
        let userId = try await client.auth.session.user.id
        return try await client
            .from("notification_preferences")
            .select()
            .eq("user_id", value: userId.uuidString.lowercased())
            .execute()
            .value
    }

    public func set(type: String, enabled: Bool) async throws {
        try await client
            .rpc("set_notification_preference", params: [
                "p_type": AnyJSON.string(type),
                "p_enabled": AnyJSON.bool(enabled)
            ])
            .execute()
    }
}
```

Add to `AppState`: `public var notificationPreferenceRepo: (any NotificationPreferenceRepository)?` (optional post-init setter).

Wire in TandasApp: `state.notificationPreferenceRepo = LiveNotificationPreferenceRepository(client: client)`.

Build + commit.

### Task 7: NotificationPreferencesView + wire + tag

Create `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Profile/Subscreens/NotificationPreferencesView.swift`:

```swift
import SwiftUI
import RuulUI
import RuulCore

@MainActor
public struct NotificationPreferencesView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var prefs: [String: Bool] = [:]
    @State private var isLoading = true
    @State private var error: String?

    public init() {}

    /// Beta-1 notification types (matches BE emit list).
    private static let types: [(key: String, label: String, icon: String)] = [
        ("voteOpened", "Votaciones abiertas", "hand.raised"),
        ("voteResolved", "Resultados de voto", "checkmark.seal"),
        ("fineOfficialized", "Multas nuevas", "creditcard"),
        ("eventCreated", "Eventos nuevos", "calendar.badge.plus"),
        ("rsvpDeadlinePassed", "Recordatorios de RSVP", "clock"),
        ("expenseReversed", "Gastos reversados", "arrow.uturn.backward.circle")
    ]

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: RuulSpacing.lg) {
                    Text("Activa o desactiva tipos de aviso. Tu dispositivo recibirá solo los tipos activos.")
                        .ruulTextStyle(RuulTypography.body)
                        .foregroundStyle(Color.ruulTextSecondary)
                    if isLoading {
                        ProgressView()
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Self.types, id: \.key) { entry in
                                row(entry)
                                if entry.key != Self.types.last?.key {
                                    Divider().background(Color.ruulSeparator).padding(.leading, 56)
                                }
                            }
                        }
                        .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.lg))
                        .overlay(RoundedRectangle(cornerRadius: RuulRadius.lg).stroke(Color.ruulSeparator, lineWidth: 0.5))
                    }
                    if let error {
                        Text(error).ruulTextStyle(RuulTypography.footnote).foregroundStyle(Color.ruulNegative)
                    }
                }
                .padding(RuulSpacing.lg)
            }
            .background(Color.ruulBackground.ignoresSafeArea())
            .navigationTitle("Notificaciones")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Cerrar") { dismiss() } } }
            .task { await load() }
        }
    }

    private func row(_ entry: (key: String, label: String, icon: String)) -> some View {
        let isOn = prefs[entry.key] ?? true  // default ON
        return HStack {
            Image(systemName: entry.icon)
                .foregroundStyle(Color.ruulTextSecondary)
                .frame(width: 28)
            Text(entry.label)
                .ruulTextStyle(RuulTypography.body)
                .foregroundStyle(Color.ruulTextPrimary)
            Spacer()
            Toggle("", isOn: Binding(
                get: { isOn },
                set: { newVal in Task { await set(entry.key, enabled: newVal) } }
            ))
            .labelsHidden()
        }
        .padding(RuulSpacing.md)
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            guard let repo = app.notificationPreferenceRepo else {
                // Repo not wired in this build (mock mode); use defaults.
                prefs = Dictionary(uniqueKeysWithValues: Self.types.map { ($0.key, true) })
                return
            }
            let stored = try await repo.loadMine()
            var map: [String: Bool] = Dictionary(uniqueKeysWithValues: Self.types.map { ($0.key, true) })
            for p in stored { map[p.notificationType] = p.enabled }
            prefs = map
        } catch {
            self.error = "No pudimos cargar tus preferencias."
        }
    }

    private func set(_ type: String, enabled: Bool) async {
        prefs[type] = enabled
        do {
            try await app.notificationPreferenceRepo?.set(type: type, enabled: enabled)
        } catch {
            self.error = "No pudimos guardar el cambio."
            prefs[type] = !enabled  // revert
        }
    }
}
```

Wire from `ProfileTab.swift`:

```swift
@State private var showNotificationPreferences = false

// In MyProfileView(...) call:
onOpenNotificationPreferences: { showNotificationPreferences = true }

.fullScreenCover(isPresented: $showNotificationPreferences) {
    NotificationPreferencesView().environment(app)
}
```

Build + commit + tag:

```bash
git tag -a level15-pass2-complete -m "Level 15 — Pass 2 (notification preferences) complete"
```

---

## Done When

- 7 tasks committed.
- BE mig `notification_preferences` deployed.
- "NOTIFICACIONES" section visible in MyProfileView with 2 navrows.
- DevicesView lista tokens del usuario + revoke funciona.
- NotificationPreferencesView toggle ON/OFF persiste.
- `NotificationDeepLink` parsea event/vote/fine/rule schemes.
- Build clean.
- Two tags: `level15-pass1-complete`, `level15-pass2-complete`.

---

## Out of Scope

- Quiet hours / DnD
- Failed notification visibility
- Apple Wallet integration
- Group-level mute
- WebPush / Android tokens
- Notification preview / test push
- Smart grouping / collapse
- Multi-channel fallback (email/SMS)
- Updating `dispatch-notifications` cron to respect preferences (separate Pass 3 — cron query change requires careful staging)
