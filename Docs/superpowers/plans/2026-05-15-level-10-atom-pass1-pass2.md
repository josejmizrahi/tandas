# Level 10 Atom Visibility — Pass 1 + Pass 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development.

**Goal:** Add cross-group `MyTimelineView` + bring `ActivitySectionView` to event-type parity with `ActivityView`.

**Architecture:** Pass 1 introduces a new SQL view `my_activity_v1` (union of 4 atom tables), `MyActivityRepository`, and `MyTimelineView` wired from `MyProfileView`. Pass 2 refactors `ActivitySectionView` to reuse `HistoryItemPresentation` (the same catalog `ActivityView` uses), eliminating the 24-vs-60 event drift.

**Tech Stack:** SwiftUI iOS 26+, Swift 6, Supabase SQL view.

**Source spec:** `docs/superpowers/specs/2026-05-15-level-10-atom-visibility.md`.

---

## Verified facts

- Latest migration `00222`. Next is `00223`.
- `HistoryItemPresentation(event: SystemEvent, memberName: String? = nil)` exists with `.icon`, `.title`, `.subtitle`, `.timestamp`, `.tone`.
- `MyActivityRepository` does NOT exist.
- `MyLedgerView` is the closest existing cross-group user view (only money).
- `MyProfileView` already has slot "Mi línea de tiempo" comment per L0 wireframe (verify with grep).
- `ActivitySectionView` at `Features/Resources/Detail/Sections/ActivitySectionView.swift` uses private `iconFor(_:)` + `labelFor(_:)`.
- Modal policy: `.fullScreenCover`.
- `app.session?.user.id`, `app.groups` available in AppState.

---

## Pass 1 — MyTimelineView cross-group (4 tasks)

### Task 1: BE migration `my_activity_v1` view

Create `supabase/migrations/00223_my_activity_view.sql`:

```sql
-- Mig 00223: my_activity_v1 — cross-group user-scoped atom feed.
-- Unions 4 atom sources (rsvp_actions, check_in_actions, vote_casts,
-- ledger_entries) into a single chronological view. RLS inherited
-- from each source table — view is transport convenience only.

create or replace view public.my_activity_v1 as
  select 'rsvp'::text as kind,
         ra.id,
         ra.resource_id,
         gm.user_id,
         gm.group_id,
         jsonb_build_object('status', ra.status) as payload,
         ra.recorded_at as occurred_at
  from public.rsvp_actions ra
  join public.group_members gm on gm.id = ra.member_id

  union all

  select 'check_in',
         ca.id,
         ca.resource_id,
         gm.user_id,
         gm.group_id,
         jsonb_build_object('method', ca.metadata->>'check_in_method'),
         ca.recorded_at
  from public.check_in_actions ca
  join public.group_members gm on gm.id = ca.member_id

  union all

  select 'vote_cast',
         vc.id,
         vc.vote_id::uuid,
         gm.user_id,
         gm.group_id,
         jsonb_build_object('choice', vc.choice, 'vote_id', vc.vote_id::text),
         coalesce(vc.cast_at, vc.created_at)
  from public.vote_casts vc
  join public.group_members gm on gm.id = vc.member_id
  where vc.cast_at is not null and vc.choice <> 'pending'

  union all

  select 'ledger',
         le.id,
         le.resource_id,
         gmf.user_id,
         le.group_id,
         jsonb_build_object(
           'type', le.type,
           'amount_cents', le.amount_cents,
           'currency', le.currency
         ),
         le.occurred_at
  from public.ledger_entries le
  join public.group_members gmf on gmf.id = le.from_member_id
  where gmf.user_id is not null;

grant select on public.my_activity_v1 to authenticated;
```

Apply via MCP `mcp__supabase__apply_migration` (or local CLI). Commit the file.

### Task 2: MyActivityRepository

Create `ios/Packages/RuulCore/Sources/RuulCore/Repositories/MyActivityRepository.swift`:

```swift
import Foundation
import Supabase

public struct MyActivityItem: Identifiable, Sendable, Hashable {
    public let id: UUID
    public let kind: Kind
    public let resourceId: UUID?
    public let groupId: UUID
    public let payload: JSONConfig
    public let occurredAt: Date

    public enum Kind: String, Sendable, Codable {
        case rsvp, checkIn = "check_in", voteCast = "vote_cast", ledger
    }
}

public protocol MyActivityRepository: Actor {
    func loadRecent(limit: Int) async throws -> [MyActivityItem]
}

public actor MockMyActivityRepository: MyActivityRepository {
    public var items: [MyActivityItem]
    public init(seed: [MyActivityItem] = []) { self.items = seed }
    public func loadRecent(limit: Int) async throws -> [MyActivityItem] {
        Array(items.prefix(limit))
    }
}

public actor LiveMyActivityRepository: MyActivityRepository {
    private let client: SupabaseClient
    public init(client: SupabaseClient) { self.client = client }

    private struct Row: Decodable {
        let kind: String
        let id: UUID
        let resource_id: UUID?
        let user_id: UUID
        let group_id: UUID
        let payload: JSONConfig
        let occurred_at: Date
    }

    public func loadRecent(limit: Int) async throws -> [MyActivityItem] {
        let userId = try await client.auth.session.user.id
        let rows: [Row] = try await client
            .from("my_activity_v1")
            .select("kind, id, resource_id, user_id, group_id, payload, occurred_at")
            .eq("user_id", value: userId.uuidString.lowercased())
            .order("occurred_at", ascending: false)
            .limit(limit)
            .execute()
            .value
        return rows.compactMap { row in
            guard let kind = MyActivityItem.Kind(rawValue: row.kind) else { return nil }
            return MyActivityItem(
                id: row.id,
                kind: kind,
                resourceId: row.resource_id,
                groupId: row.group_id,
                payload: row.payload,
                occurredAt: row.occurred_at
            )
        }
    }
}
```

NOTE: confirm `JSONConfig` is `Decodable` directly from PostgREST jsonb — if not, use `[String: AnyJSON]` and convert in repo. Adapt date decoding if PostgREST returns string ISO.

Add to `AppState` if `myActivityRepo: any MyActivityRepository` doesn't exist — match pattern of other repos (Live vs Mock injection).

Build + commit.

### Task 3: MyTimelineView

Create `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Profile/Subscreens/MyTimelineView.swift`:

```swift
import SwiftUI
import RuulUI
import RuulCore

@MainActor
public struct MyTimelineView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var items: [MyActivityItem] = []
    @State private var isLoading = true
    @State private var error: String?

    public init() {}

    public var body: some View {
        NavigationStack {
            ScrollView {
                if isLoading && items.isEmpty {
                    ProgressView().padding(RuulSpacing.xl)
                } else if items.isEmpty {
                    Text("Aún no hay actividad")
                        .ruulTextStyle(RuulTypography.body)
                        .foregroundStyle(Color.ruulTextTertiary)
                        .padding(RuulSpacing.xl)
                } else {
                    LazyVStack(alignment: .leading, spacing: RuulSpacing.lg) {
                        ForEach(groupedByDay, id: \.day) { group in
                            section(day: group.day, items: group.items)
                        }
                    }
                    .padding(RuulSpacing.lg)
                }
                if let error {
                    Text(error)
                        .ruulTextStyle(RuulTypography.footnote)
                        .foregroundStyle(Color.ruulNegative)
                        .padding(.horizontal, RuulSpacing.lg)
                }
            }
            .background(Color.ruulBackground.ignoresSafeArea())
            .navigationTitle("Mi línea de tiempo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cerrar") { dismiss() }
                }
            }
            .refreshable { await load() }
            .task { await load() }
        }
    }

    private var groupedByDay: [(day: Date, items: [MyActivityItem])] {
        let cal = Calendar.current
        let groups = Dictionary(grouping: items) { item in
            cal.startOfDay(for: item.occurredAt)
        }
        return groups.keys.sorted(by: >).map { day in
            (day: day, items: groups[day]!.sorted { $0.occurredAt > $1.occurredAt })
        }
    }

    private func section(day: Date, items: [MyActivityItem]) -> some View {
        VStack(alignment: .leading, spacing: RuulSpacing.sm) {
            Text(dayLabel(day))
                .ruulTextStyle(RuulTypography.sectionLabel)
                .foregroundStyle(Color.ruulTextTertiary)
                .padding(.leading, RuulSpacing.xxs)
            VStack(spacing: 0) {
                ForEach(items) { item in
                    row(item)
                    if item.id != items.last?.id {
                        Divider().background(Color.ruulSeparator).padding(.leading, 56)
                    }
                }
            }
            .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.lg))
            .overlay(RoundedRectangle(cornerRadius: RuulRadius.lg).stroke(Color.ruulSeparator, lineWidth: 0.5))
        }
    }

    private func row(_ item: MyActivityItem) -> some View {
        HStack(spacing: RuulSpacing.md) {
            Image(systemName: iconFor(item))
                .ruulTextStyle(RuulTypography.subheadMedium)
                .foregroundStyle(colorFor(item))
                .frame(width: 32, height: 32)
                .background(colorFor(item).opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(titleFor(item))
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextPrimary)
                Text(originLabel(item))
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextSecondary)
            }
            Spacer()
            Text(relativeTime(item.occurredAt))
                .ruulTextStyle(RuulTypography.caption)
                .foregroundStyle(Color.ruulTextTertiary)
        }
        .padding(RuulSpacing.md)
    }

    private func iconFor(_ item: MyActivityItem) -> String {
        switch item.kind {
        case .rsvp:     return "checkmark.circle"
        case .checkIn:  return "location.fill"
        case .voteCast: return "hand.raised"
        case .ledger:   return "creditcard"
        }
    }

    private func colorFor(_ item: MyActivityItem) -> Color {
        switch item.kind {
        case .rsvp:     return Color.ruulPositive
        case .checkIn:  return Color.ruulAccent
        case .voteCast: return Color.ruulAccent
        case .ledger:   return Color.ruulWarning
        }
    }

    private func titleFor(_ item: MyActivityItem) -> String {
        switch item.kind {
        case .rsvp:
            if case .string(let s)? = item.payload["status"] {
                switch s {
                case "yes":   return "Confirmaste asistencia"
                case "no":    return "Declinaste asistencia"
                case "waitlist": return "Te uniste a lista de espera"
                default:      return "Cambiaste tu RSVP"
                }
            }
            return "Cambiaste tu RSVP"
        case .checkIn:  return "Hiciste check-in"
        case .voteCast:
            if case .string(let s)? = item.payload["choice"] {
                switch s {
                case "in_favor": return "Votaste a favor"
                case "against":  return "Votaste en contra"
                case "abstained": return "Te abstuviste en un voto"
                default:         return "Emitiste un voto"
                }
            }
            return "Emitiste un voto"
        case .ledger:
            if case .string(let s)? = item.payload["type"] {
                switch s {
                case "fine_paid":     return "Pagaste una multa"
                case "contribution":  return "Hiciste una aportación"
                case "expense":       return "Registraste un gasto"
                default:              return "Movimiento de dinero"
                }
            }
            return "Movimiento de dinero"
        }
    }

    private func originLabel(_ item: MyActivityItem) -> String {
        app.groups.first(where: { $0.id == item.groupId })?.name ?? "Grupo"
    }

    private func dayLabel(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "HOY" }
        if cal.isDateInYesterday(date) { return "AYER" }
        let f = DateFormatter()
        f.locale = Locale(identifier: app.profile?.locale ?? "es-MX")
        f.dateFormat = "EEEE d 'de' MMMM"
        return f.string(from: date).uppercased()
    }

    private func relativeTime(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        f.locale = Locale(identifier: app.profile?.locale ?? "es-MX")
        return f.localizedString(for: date, relativeTo: .now)
    }

    private func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            items = try await app.myActivityRepo.loadRecent(limit: 100)
        } catch {
            self.error = "No pudimos cargar tu actividad."
        }
    }
}
```

Build + commit.

### Task 4: Wire from MyProfileView + tag

Modify `Features/Profile/Views/MyProfileView.swift`. Add a navrow in the "TU ACTIVIDAD" section (already exists) before "Mis movimientos":

```swift
divider
navRow(
    icon: "clock.arrow.circlepath",
    label: "Mi línea de tiempo",
    trailing: { EmptyView() },
    action: { onOpenTimeline?() }
)
```

Add `public var onOpenTimeline: (() -> Void)?` to MyProfileView init.

Wire from `ProfileTab.swift` (per L0 Pass 2 task 10 pattern):

```swift
.fullScreenCover(isPresented: $showTimeline) {
    MyTimelineView().environment(app)
}

@State private var showTimeline = false

// In MyProfileView(...) call:
onOpenTimeline: { showTimeline = true },
```

Build + commit + tag:

```bash
git tag -a level10-pass1-complete -m "Level 10 — Pass 1 (MyTimelineView) complete"
```

---

## Pass 2 — ActivitySectionView parity (2 tasks)

### Task 5: Refactor ActivitySectionView to use HistoryItemPresentation

Modify `Features/Resources/Detail/Sections/ActivitySectionView.swift`:

1. Find the private `iconFor(_:)` + `labelFor(_:)` functions (24 cases hardcoded).
2. Remove them.
3. In the row rendering, replace with:
   ```swift
   let presentation = HistoryItemPresentation(event: atom, memberName: memberName(for: atom))
   // use presentation.icon, presentation.title, presentation.tone
   ```
4. `memberName(for:)` already exists in this view (or in context.memberDirectory) — adapt.

Build + commit.

### Task 6: Visual polish + tag

Same file — visual polish:
- Apply tone color via `presentation.tone` mapping to ruulPositive/ruulWarning/ruulNegative/ruulAccent/ruulTextSecondary.
- Keep compact layout (no subtitle/timestamp inline — that's ActivityView's job).

Build + commit + tag:

```bash
git tag -a level10-pass2-complete -m "Level 10 — Pass 2 (ActivitySection parity) complete"
```

---

## Done When

- 6 tasks committed.
- `my_activity_v1` view applied to DB.
- "Mi línea de tiempo" navrow visible in MyProfileView → opens MyTimelineView with cross-group feed.
- ActivitySectionView renders all 60+ event types via HistoryItemPresentation (no more "Actividad" fallback for mapped types).
- Build clean.
- Two tags: `level10-pass1-complete`, `level10-pass2-complete`.

---

## Out of Scope

- Pass 3 — member filter UI in ActivityView
- Audit UI for rule_evaluations / identity_atoms / capability_atoms
- CSV export
- Realtime updates via subscriptions
- "Borrar mi actividad" (GDPR)
- Type filters in MyTimelineView
