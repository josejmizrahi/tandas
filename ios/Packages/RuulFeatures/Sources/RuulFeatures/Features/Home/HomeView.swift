import SwiftUI
import RuulUI
import RuulCore

/// Tab "Inicio" — daily landing for a social-coordination app per
/// Wave 3 doctrine (Apple Mail / WhatsApp social-feed pattern).
///
/// **Layout** (compact, glance-able in one screen):
///   - `topBarLeading` scope switcher (Menu native) — picks `.all`
///     (Apple Mail "All Inboxes" pattern) or a specific group filter.
///   - **Tus recursos** — horizontal tile cluster of non-time
///     resources (funds / assets / spaces / slots). Inside ONE List
///     section row, full-width. Apple Music "Featured" pattern.
///   - **Tu día** — actionable pendings (ActionCard). Max 4 + overflow.
///   - **Pronto** — upcoming events (time-anchored). Max 5 + overflow.
///   - Empty hero collapses everything when fully empty.
///
/// Anti-infinite-scroll constraints (founder 2026-05-20):
///   - 2 vertical sections max (3 counting the tile cluster row)
///   - Each section caps at 3-5 items + "Ver todos" overflow
///   - Empty sections vanish entirely (no "Sin nada" placeholders)
///   - "Hace poco" goes to History / Group home, not here
///
/// Drops vs PR #6 (HomeView 3-section): hacePocoSection, the 4-section
/// stack, group-locked toolbar avatar. The toolbar now hosts an
/// explicit scope switcher (Menu) — user controls cross-group vs
/// single-group lens directly.
public struct HomeView: View {
    @Bindable var coordinator: HomeCoordinator
    @Environment(AppState.self) private var app
    @Environment(RootRouter.self) private var router
    /// Inbox content embebido en Inicio como "Tu día". `nil` durante
    /// bootstrap (igual que homeCoordinator).
    public var inboxCoordinator: InboxCoordinator?
    public var onInboxActionTap: (UserAction) async -> Void = { _ in }
    public let userId: UUID
    public var onCreateEvent: () -> Void
    public var onOpenEvent: (Event) -> Void
    public var onOpenPastEvents: () -> Void
    /// Kept for API compatibility with `HomeTab` wiring; no longer
    /// routed inside this view (History moved to Group home).
    public var onOpenGroupHistory: () -> Void = {}
    public var onInvitePeople: (() -> Void)? = nil
    /// Legacy callback — superseded by the inline switcher menu.
    /// Wiring stays in place for sheet-based overflow flows.
    public var onSwitchGroup: () -> Void = {}
    /// Bumped by `MainTabView` after the wizard creates a resource —
    /// drives the resources re-fetch via `.task(id:)`.
    public var resourceRefreshToken: UUID

    public init(
        coordinator: HomeCoordinator,
        inboxCoordinator: InboxCoordinator?,
        onInboxActionTap: @escaping (UserAction) async -> Void = { _ in },
        userId: UUID,
        onCreateEvent: @escaping () -> Void,
        onOpenEvent: @escaping (Event) -> Void,
        onOpenPastEvents: @escaping () -> Void,
        onOpenGroupHistory: @escaping () -> Void = {},
        onInvitePeople: (() -> Void)? = nil,
        onSwitchGroup: @escaping () -> Void = {},
        resourceRefreshToken: UUID = UUID()
    ) {
        self.coordinator = coordinator
        self.inboxCoordinator = inboxCoordinator
        self.onInboxActionTap = onInboxActionTap
        self.userId = userId
        self.onCreateEvent = onCreateEvent
        self.onOpenEvent = onOpenEvent
        self.onOpenPastEvents = onOpenPastEvents
        self.onOpenGroupHistory = onOpenGroupHistory
        self.onInvitePeople = onInvitePeople
        self.onSwitchGroup = onSwitchGroup
        self.resourceRefreshToken = resourceRefreshToken
    }

    @State private var openedResource: ResourceRow?

    public var body: some View {
        List {
            if !coordinator.upcomingResources.isEmpty {
                resourcesSection
            }
            if hasPendings {
                tuDiaSection
            }
            if !upcomingEventsFiltered.isEmpty {
                prontoSection
            }
            if isFullyEmpty {
                Section { emptyHero }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .listSectionSpacing(.compact)
        .refreshable {
            async let h: Void = coordinator.refresh(force: true)
            async let i: Void? = inboxCoordinator?.refresh()
            _ = await (h, i)
        }
        .navigationTitle("Inicio")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            // Luma "Ciudad de México ▾" pattern: tap the LargeTitle to
            // open the scope menu. iOS-canonical via .toolbarTitleMenu
            // (Apple Mail, Photos library, Music sources all do this).
            // Zero vertical chrome — the menu lives in the title bar.
            ToolbarTitleMenu {
                Button {
                    Task { await coordinator.setScope(.all) }
                } label: {
                    Label("Todos los grupos", systemImage: "square.grid.2x2")
                }
                if !app.groups.isEmpty {
                    Divider()
                    ForEach(app.groups, id: \.id) { group in
                        Button {
                            Task { await coordinator.setScope(.group(group.id)) }
                        } label: {
                            Label(group.name, systemImage: "person.3.fill")
                        }
                    }
                }
            }
            ToolbarItem(placement: .topBarLeading) {
                scopeSwitcherButton
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let onInvitePeople {
                    Button(action: onInvitePeople) {
                        Image(systemName: "person.badge.plus")
                    }
                    .accessibilityLabel("Invitar gente")
                }
                Button {
                    router.presentCreate(hasActiveGroup: app.activeGroup != nil)
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.glassProminent)
                .accessibilityLabel("Crear")
            }
        }
        .task {
            async let h: Void = coordinator.refresh()
            async let i: Void? = inboxCoordinator?.refresh()
            _ = await (h, i)
        }
        .task(id: resourceRefreshToken) {
            await coordinator.refresh(force: true)
        }
        .task(id: app.activeGroup?.id) {
            // No forced refresh here — `setActiveGroup` (called from
            // ProfileTab quick-switch) kicks its own background refresh.
        }
        .fullScreenCover(item: $openedResource) { row in
            ResourceDetailSheet(resource: row)
                .environment(app)
                .environment(router)
        }
    }

    // MARK: - Scope switcher (topBarLeading Menu — primary tap target)

    /// Tappable scope switcher in `topBarLeading`. The `ToolbarTitleMenu`
    /// fallback exists for collapsed inline title (Apple Mail canonical),
    /// but iOS doesn't render a visible chevron on the LargeTitle at
    /// rest — so users wouldn't know they can tap. This explicit pill
    /// guarantees discoverability whether the title is large or inline.
    private var scopeSwitcherButton: some View {
        Menu {
            Button {
                Task { await coordinator.setScope(.all) }
            } label: {
                Label("Todos los grupos", systemImage: "square.grid.2x2")
            }
            if !app.groups.isEmpty {
                Divider()
                ForEach(app.groups, id: \.id) { group in
                    Button {
                        Task { await coordinator.setScope(.group(group.id)) }
                    } label: {
                        Label(group.name, systemImage: "person.3.fill")
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                scopeAvatar
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color.secondary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Cambiar grupo. Actual: \(scopeLabel).")
    }

    /// Visual indicator of the current scope inside the switcher pill.
    @ViewBuilder
    private var scopeAvatar: some View {
        switch coordinator.scope {
        case .all:
            ZStack {
                Circle()
                    .fill(Color(.tertiarySystemFill))
                    .frame(width: 28, height: 28)
                Image(systemName: "square.grid.2x2")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.primary)
            }
        case .group(let id):
            if let group = app.groups.first(where: { $0.id == id }) {
                RuulGroupAvatar(group: group, size: .md)
            } else {
                Image(systemName: "person.3.fill")
                    .font(.subheadline.weight(.semibold))
            }
        }
    }

    private var scopeLabel: String {
        switch coordinator.scope {
        case .all: return "Todos los grupos"
        case .group(let id): return app.groups.first(where: { $0.id == id })?.name ?? "Grupo"
        }
    }

    /// True when the feed mixes events from multiple groups — drives
    /// whether each row renders an inline group tag (Luma "Layer 2,
    /// Le..." pattern). Single-group scope hides the tag (redundant
    /// with the surface itself).
    private var showGroupTag: Bool {
        coordinator.scope == .all && app.groups.count > 1
    }

    /// Inline group tag pill rendered above the title on event /
    /// pending rows when scope is `.all`. Tiny dot in the group's
    /// accent color + name in tertiary. Luma "Layer 2, Le..." pattern.
    @ViewBuilder
    private func groupTagPill(for groupId: UUID) -> some View {
        if let group = app.groups.first(where: { $0.id == groupId }) {
            HStack(spacing: 4) {
                Circle()
                    .fill(group.category.ramp.accent)
                    .frame(width: 6, height: 6)
                Text(group.name)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Section 1: Tus recursos (horizontal tile cluster)

    /// Non-time-anchored resources surfaced as a horizontal tile cluster
    /// inside ONE List row. Apple Music / App Store "Featured" pattern —
    /// N resources compressed into ~120pt of vertical space.
    private var resourcesSection: some View {
        Section("Tus recursos") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: RuulSpacing.sm) {
                    ForEach(coordinator.upcomingResources) { row in
                        resourcePill(row)
                    }
                }
                .padding(.horizontal, RuulSpacing.md)
                .padding(.vertical, 4)
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    /// Luma "Ciudades" pattern: 180pt-wide card with a tinted gradient
    /// header (resource-type accent) + bottom info (group tag + name +
    /// status). Visually richer than tiny 140pt pills; gives non-time
    /// resources real estate when they exist.
    private func resourcePill(_ row: ResourceRow) -> some View {
        Button { openedResource = row } label: {
            VStack(alignment: .leading, spacing: 0) {
                // Tinted header — type accent color, ~60pt tall
                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [Color.accentColor.opacity(0.25), Color.accentColor.opacity(0.10)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(height: 64)
                    Image(systemName: ResourceTypeChrome.resolve(row.resourceType).symbol)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(RuulSpacing.md)
                }
                // Body
                VStack(alignment: .leading, spacing: 4) {
                    if showGroupTag {
                        groupTagPill(for: row.groupId)
                    }
                    Text(displayNameFor(row))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(subtitleFor(row))
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                        .lineLimit(1)
                }
                .padding(RuulSpacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: 180, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color(.separator), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Section 2: Tu día (pendings)

    /// Pendings filtered by current scope. `.all` shows everything;
    /// `.group(id)` filters to that group's actions only so the switcher
    /// affects "Tu día" consistently with "Pronto" and "Tus recursos".
    private var scopedPendings: [UserAction] {
        guard let coord = inboxCoordinator else { return [] }
        switch coordinator.scope {
        case .all:
            return coord.actions
        case .group(let id):
            return coord.actions.filter { $0.groupId == id }
        }
    }

    private var hasPendings: Bool {
        !scopedPendings.isEmpty
    }

    @ViewBuilder
    private var tuDiaSection: some View {
        if let coord = inboxCoordinator, !scopedPendings.isEmpty {
            Section("Tu día") {
                ForEach(Array(scopedPendings.prefix(4)), id: \.id) { action in
                    pendingRow(action, coordinator: coord)
                }
            }
        }
    }

    /// Luma-style rich row: 48×48 tinted icon container + group tag
    /// pill (when scope=.all) + bold title (2 lines) + meta with small
    /// clock icon + trailing time-remaining. ~78pt height total.
    private func pendingRow(_ action: UserAction, coordinator: InboxCoordinator) -> some View {
        Button {
            Task { await onInboxActionTap(action) }
        } label: {
            HStack(alignment: .top, spacing: RuulSpacing.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(pendingTint(for: action.priority).opacity(0.15))
                        .frame(width: 48, height: 48)
                    Image(systemName: pendingIcon(for: action.actionType))
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(pendingTint(for: action.priority))
                }
                VStack(alignment: .leading, spacing: 4) {
                    if showGroupTag {
                        groupTagPill(for: action.groupId)
                    }
                    Text(action.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.caption2)
                            .foregroundStyle(Color.secondary)
                            .accessibilityHidden(true)
                        if let remaining = UserActionExpiry.remainingDescription(for: action) {
                            Text(remaining)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(Color.secondary)
                        } else if let meta = pendingMeta(for: action, coordinator: coordinator) {
                            Text(meta)
                                .font(.caption)
                                .foregroundStyle(Color.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Section 3: Pronto (upcoming events)

    /// Future events from `coordinator.upcomingEvents`. Coordinator
    /// already filters by scope (cross-group when `.all`, single-group
    /// when `.group(id)`) via the new `setScope` path.
    private var upcomingEventsFiltered: [Event] {
        coordinator.upcomingEvents.sorted { $0.startsAt < $1.startsAt }
    }

    @ViewBuilder
    private var prontoSection: some View {
        Section("Pronto") {
            ForEach(Array(upcomingEventsFiltered.prefix(5)), id: \.id) { event in
                eventRow(event)
            }
        }
    }

    /// Luma-style rich row: 48×48 tinted icon container + optional
    /// group tag pill (cross-group scope) + bold title + meta with
    /// clock icon + trailing RSVP chip. ~78pt height total.
    private func eventRow(_ event: Event) -> some View {
        Button { onOpenEvent(event) } label: {
            HStack(alignment: .top, spacing: RuulSpacing.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12))
                        .frame(width: 48, height: 48)
                    Image(systemName: ResourceTypeChrome.resolve(.event).symbol)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
                VStack(alignment: .leading, spacing: 4) {
                    if showGroupTag {
                        groupTagPill(for: event.groupId)
                    }
                    Text(event.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.caption2)
                            .foregroundStyle(Color.secondary)
                            .accessibilityHidden(true)
                        Text(eventMetaLine(event))
                            .font(.caption)
                            .foregroundStyle(Color.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                rsvpTrailing(for: event)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Empty state

    private var isFullyEmpty: Bool {
        let pendingsEmpty = scopedPendings.isEmpty
        let upcomingEmpty = upcomingEventsFiltered.isEmpty
        let resourcesEmpty = coordinator.upcomingResources.isEmpty
        return pendingsEmpty && upcomingEmpty && resourcesEmpty
    }

    private var emptyHero: some View {
        ContentUnavailableView {
            Label("Tu grupo está listo", systemImage: "sparkles")
        } description: {
            Text("Crea algo —un evento, un fondo, un activo— y aparece acá.")
        } actions: {
            Button("Crear") {
                router.presentCreate(hasActiveGroup: app.activeGroup != nil)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.top, RuulSpacing.s8)
    }

    // MARK: - Helpers (icons, meta, RSVP trailing, display name)

    private func eventMetaLine(_ event: Event) -> String {
        if event.status == .cancelled { return "Cancelado" }
        if event.status == .inProgress { return "En vivo" }
        let calendar = Calendar.current
        if calendar.isDateInToday(event.startsAt) {
            return "Hoy · \(event.startsAt.ruulShortTime)"
        }
        if calendar.isDateInTomorrow(event.startsAt) {
            return "Mañana · \(event.startsAt.ruulShortTime)"
        }
        return "\(event.startsAt.ruulShortDate) · \(event.startsAt.ruulShortTime)"
    }

    @ViewBuilder
    private func rsvpTrailing(for event: Event) -> some View {
        if event.status == .inProgress {
            HStack(spacing: 4) {
                Circle().fill(Color.red).frame(width: 6, height: 6)
                Text("En vivo")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.red)
            }
        } else if let status = coordinator.myRSVPs[event.id]?.status, status != .pending {
            let (color, label) = rsvpLabel(status)
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
        }
    }

    private func rsvpLabel(_ status: RSVPStatus) -> (Color, String) {
        switch status {
        case .going:      return (.green, "Vas")
        case .maybe:      return (.orange, "Tal vez")
        case .declined:   return (Color(.tertiaryLabel), "No vas")
        case .waitlisted: return (.orange, "Lista")
        case .pending:    return (.clear, "")
        }
    }

    private func subtitleFor(_ row: ResourceRow) -> String {
        let type = row.resourceType.humanLabel
        switch row.resourceType {
        case .asset:
            if let raw = row.metadata["checked_out_to"]?.stringValue, !raw.isEmpty {
                return "Prestado"
            }
            if let raw = row.metadata["custodian_id"]?.stringValue, !raw.isEmpty {
                return "En custodia"
            }
            return "Del grupo"
        case .fund:
            if let raw = row.metadata["locked_at"]?.stringValue, !raw.isEmpty {
                return "Bloqueado"
            }
            return type
        case .space:
            if let cap = row.metadata["capacity"]?.intValue {
                return "\(cap) cupos"
            }
            return type
        default:
            return type
        }
    }

    private func displayNameFor(_ row: ResourceRow) -> String {
        if case let .string(name) = row.metadata["name"] { return name }
        if case let .string(title) = row.metadata["title"] { return title }
        return row.resourceType.humanLabel
    }

    private func pendingIcon(for type: ActionType) -> String {
        switch type {
        case .finePending:             return "exclamationmark.triangle.fill"
        case .fineVoided:              return "xmark.circle"
        case .appealVotePending:       return "hand.raised.fill"
        case .rsvpPending:             return "checkmark.circle.fill"
        case .fineProposalReview:      return "doc.text.magnifyingglass"
        case .ruleChangeApplyPending:  return "list.bullet.clipboard.fill"
        case .hostAssigned:            return "person.crop.circle.badge.checkmark"
        case .slotPending:             return "ticket.fill"
        case .votePending:             return "hand.raised.fill"
        case .contributionDue:         return "banknote.fill"
        case .compensationDue:         return "arrow.up.right"
        case .assetActionApproval:     return "checkmark.shield.fill"
        }
    }

    private func pendingMeta(for action: UserAction, coordinator: InboxCoordinator) -> String? {
        switch action.actionType {
        case .ruleChangeApplyPending:
            return "Votado \(action.createdAt.ruulRelativeDescription)"
        default:
            return coordinator.groupName(for: action)
        }
    }

    private func pendingTint(for priority: ActionPriority) -> Color {
        switch priority {
        case .urgent: return .red
        case .high:   return .orange
        case .medium: return .accentColor
        case .low:    return Color.secondary
        }
    }
}
