import SwiftUI
import RuulUI
import RuulCore

/// Tab "Inicio" — the user's daily landing per Wave 3 doctrine.
///
/// Three canonical sections (Ruul Canonical UX Doctrine §4, §7):
///   1. **Necesitan ti** — pendings sourced from `inboxCoordinator`
///      (cross-group capable). Top 3 ActionCard rows.
///   2. **Próximamente** — resource-driven feed of items with a real
///      future temporal anchor. V1 only Event exposes `startsAt`;
///      other resource types contribute their own "next happens at"
///      as they ship temporal semantics (slot rotation, asset
///      booking, fund deadline, right expiration). Top 5 rows.
///   3. **Hace poco** — recently closed/cancelled resources
///      (polymorphic). Top 5 rows + overflow → history.
///
/// LargeTitle "Inicio" (Apple Reminders / Calendar convention).
/// Drops the previous capability-aware emptyHero variant, the
/// counter-card "Historial del grupo" tiles, and the dedicated
/// "Ver historial" footer link — those reduce to native rows within
/// the three canonical sections.
public struct HomeView: View {
    @Bindable var coordinator: HomeCoordinator
    @Environment(AppState.self) private var app
    @Environment(RootRouter.self) private var router
    /// Fase 4b: Inbox content vive embebido en Home como sección
    /// "Necesitan ti". `nil` durante bootstrap (igual que
    /// homeCoordinator). El callback dispatch al `handleInboxAction`
    /// del padre — mismo handler que antes.
    public var inboxCoordinator: InboxCoordinator?
    public var onInboxActionTap: (UserAction) async -> Void = { _ in }
    public let userId: UUID
    public var onCreateEvent: () -> Void
    public var onOpenEvent: (Event) -> Void
    public var onOpenPastEvents: () -> Void
    /// "Hace poco" tile tap. Default no-op para callsites pre-P1.
    public var onOpenGroupHistory: () -> Void = {}
    public var onInvitePeople: (() -> Void)? = nil
    /// Tap del GroupSwitcher pill — abre `GroupSwitcherSheet` desde Home.
    /// Per AppShell.md: el switcher es chrome persistente en Home/Inbox/Activity.
    public var onSwitchGroup: () -> Void = {}
    /// Bumped by the parent (MainTabView) after the wizard creates a
    /// resource — drives the past-events re-fetch via .task(id:).
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
    /// Recent past resources (status: completed / cancelled) for
    /// "Hace poco". Polymorphic `ResourceRow` lets us render any
    /// closed resource type with the same chrome; tap opens
    /// `ResourceDetailSheet` like every other row in Home.
    @State private var recentPastResources: [ResourceRow] = []

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RuulSpacing.xxl) {
                necesitanTiSection
                proximamenteSection
                hacePocoSection
                if isFullyEmpty {
                    emptyHero
                }
            }
            .padding(.horizontal, RuulSpacing.lg)
            .padding(.top, RuulSpacing.md)
            .padding(.bottom, RuulSpacing.s12)
        }
        .scrollIndicators(.hidden)
        .scrollEdgeEffectStyle(.soft, for: .vertical)
        .refreshable {
            async let h: Void = coordinator.refresh(force: true)
            async let i: Void? = inboxCoordinator?.refresh()
            async let r: Void = loadRecentPastResources()
            _ = await (h, i, r)
        }
        .navigationTitle("Inicio")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            if let group = app.activeGroup {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: onSwitchGroup) {
                        RuulGroupAvatar(group: group, size: .lg)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Cambiar grupo. Actual: \(group.name).")
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let onInvitePeople {
                    Button(action: onInvitePeople) {
                        Image(systemName: "person.badge.plus")
                    }
                    .accessibilityLabel("Invitar gente")
                }
                // Primary "+" action lives in Home's toolbar (Apple
                // pattern — Reminders / Calendar / Mail all do this).
                // `.glassProminent` per Ruul Glass Doctrine "floating
                // action → ligero" (iOS 26 native).
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
            await loadRecentPastResources()
        }
        // Group switch (active group changes via the switcher) doesn't
        // bump resourceRefreshToken, so without this second .task the
        // @State stays bound to whatever group was active when the view
        // first appeared.
        .task(id: app.activeGroup?.id) {
            await loadRecentPastResources()
        }
        .fullScreenCover(item: $openedResource) { row in
            ResourceDetailSheet(resource: row)
                .environment(app)
                .environment(router)
        }
    }

    /// Loads the active group's recent past events for the "Hace poco"
    /// section. Polymorphic resource repo filtered to `.event` rows
    /// with terminal statuses. Failures collapse the section silently;
    /// best-effort by design.
    @MainActor
    private func loadRecentPastResources() async {
        guard let groupId = app.activeGroup?.id else {
            recentPastResources = []
            return
        }
        // Pull past resources polymorphically. V1 fetches `.event`
        // rows (closed/cancelled) — when other types adopt terminal
        // statuses they can be added to the filter without touching
        // the view chrome.
        let rows = (try? await app.resourceRepo.list(
            in: groupId,
            types: [.event],
            statuses: ["completed", "cancelled"],
            limit: 20
        )) ?? []
        recentPastResources = rows.sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: - Section 1: Necesitan ti (pendings)

    @ViewBuilder
    private var necesitanTiSection: some View {
        if let coord = inboxCoordinator, !coord.actions.isEmpty {
            sectionContainer(
                title: "Necesitan ti",
                count: coord.actions.count,
                overflow: nil
            ) {
                RuulSeparatedRows(items: Array(coord.actions.prefix(3))) { action in
                    ActionCard(
                        icon: pendingIcon(for: action.actionType),
                        meta: pendingMeta(for: action, coordinator: coord),
                        title: action.title,
                        subtitle: action.body,
                        priority: pendingPriority(for: action.priority),
                        timeRemaining: UserActionExpiry.remainingDescription(for: action),
                        onTap: {
                            Task { await onInboxActionTap(action) }
                        }
                    )
                }
            }
        }
    }

    // MARK: - Section 2: Próximamente

    @ViewBuilder
    private var proximamenteSection: some View {
        let items = Array(upcomingFeed.prefix(5))
        if !items.isEmpty {
            sectionContainer(
                title: "Próximamente",
                count: upcomingFeed.count,
                overflow: nil
            ) {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                        if idx > 0 { rowDivider }
                        activityRow(item)
                    }
                }
            }
        }
    }

    // MARK: - Section 3: Hace poco

    @ViewBuilder
    private var hacePocoSection: some View {
        let items = Array(recentPastResources.prefix(5))
        if !items.isEmpty {
            sectionContainer(
                title: "Hace poco",
                count: recentPastResources.count,
                overflow: OverflowLink(label: "Ver historial", action: onOpenPastEvents)
            ) {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { idx, row in
                        if idx > 0 { rowDivider }
                        pastResourceRow(row)
                    }
                }
            }
        }
    }

    // MARK: - Section helpers

    private struct OverflowLink {
        let label: String
        let action: () -> Void
    }

    @ViewBuilder
    private func sectionContainer<Content: View>(
        title: String,
        count: Int?,
        overflow: OverflowLink?,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: RuulSpacing.md) {
            HStack(alignment: .firstTextBaseline, spacing: RuulSpacing.xs) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.primary)
                if let count, count > 0 {
                    Text("\(count)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(Color(.tertiaryLabel))
                }
                Spacer()
                if let overflow {
                    Button(action: overflow.action) {
                        Text(overflow.label)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                }
            }
            content()
        }
    }

    private var rowDivider: some View {
        Divider()
            .background(Color(.separator))
            .padding(.leading, RuulSpacing.s12)
    }

    // MARK: - Upcoming feed (resource-driven, time-anchored)

    /// "Próximamente" is a **resource-driven** feed of items with a
    /// real future temporal anchor. Per Ruul Canonical UX Doctrine §9
    /// (Resource Experience): every resource type uses the same
    /// structural layout, including how it participates in the
    /// timeline. The semantic is "next happens at" per resource
    /// type — events use `startsAt`; future non-event types will
    /// contribute their own anchors as they ship temporal semantics:
    ///
    ///   - slot → next assigned date / rotation turn
    ///   - asset → next booking / maintenance due
    ///   - fund → next contribution deadline / scheduled payout
    ///   - right → next exercise window / expiration
    ///   - space → next reservation
    ///
    /// **V1 reality**: only `Event` exposes a temporal anchor today,
    /// so the feed is sourced from `coordinator.upcomingEvents`.
    /// Non-event resources without a "next happens at" projection
    /// stay out of this section — they live in Group home / detail
    /// surfaces. Sorting them by `createdAt` next to scheduled events
    /// read as misleading on device (founder feedback 2026-05-20).
    ///
    /// TODO: introduce a polymorphic `ResourceTimelineProvider` /
    /// `ResourceRow.nextHappensAt: Date?` projection once any
    /// non-event type ships real schedule semantics. The feed
    /// collapses every resource with a non-nil anchor chronologically
    /// at that point — no special-casing here.
    private var upcomingFeed: [UpcomingFeedItem] {
        coordinator.upcomingEvents
            .map { UpcomingFeedItem(id: $0.id, event: $0) }
            .sorted { $0.sortDate < $1.sortDate }
    }

    private struct UpcomingFeedItem: Identifiable {
        let id: UUID
        let event: Event
        var sortDate: Date { event.startsAt }
    }

    @ViewBuilder
    private func activityRow(_ item: UpcomingFeedItem) -> some View {
        let event = item.event
        let status = coordinator.myRSVPs[event.id]?.status
        unifiedRow(
            icon: ResourceTypeChrome.resolve(.event).symbol,
            title: event.title,
            meta: eventMetaLine(event),
            trailing: rsvpTrailing(for: event, status: status),
            onTap: { onOpenEvent(event) }
        )
    }

    /// Past resource row — same chrome as upcoming. `meta` reads
    /// "Cerrado · hace 3 días" / "Cancelado · hace 1 día" for events;
    /// the type label for other types (when they ship terminal
    /// statuses). Tap opens `ResourceDetailSheet` polymorphically.
    @ViewBuilder
    private func pastResourceRow(_ row: ResourceRow) -> some View {
        unifiedRow(
            icon: ResourceTypeChrome.resolve(row.resourceType).symbol,
            title: displayNameFor(row),
            meta: pastResourceMetaLine(row),
            trailing: nil,
            onTap: { openedResource = row }
        )
    }

    // MARK: - Row primitive

    private func unifiedRow(
        icon: String,
        title: String,
        meta: String?,
        trailing: AnyView?,
        onTap: @escaping () -> Void
    ) -> some View {
        Button(action: onTap) {
            HStack(spacing: RuulSpacing.md) {
                ZStack {
                    Circle()
                        .fill(Color.ruulSurface)
                        .frame(width: 40, height: 40)
                    Image(systemName: icon)
                        .font(.body)
                        .foregroundStyle(Color.primary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline)
                        .foregroundStyle(Color.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let meta {
                        Text(meta)
                            .font(.caption)
                            .foregroundStyle(Color.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if let trailing {
                    trailing
                }
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color(.tertiaryLabel))
                    .accessibilityHidden(true)
            }
            .padding(.vertical, RuulSpacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Meta line helpers

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

    /// Past resource meta — "Cerrado · hace 3 días" / "Cancelado ·
    /// hace 1 día" for events. Falls back to the bare type label for
    /// non-event resources (until they ship terminal statuses with
    /// richer copy).
    private func pastResourceMetaLine(_ row: ResourceRow) -> String {
        let status = row.status.lowercased()
        let prefix: String = status == "cancelled" ? "Cancelado" : "Cerrado"
        return "\(prefix) · \(row.createdAt.ruulRelativeDescription)"
    }

    private func rsvpTrailing(for event: Event, status: RSVPStatus?) -> AnyView? {
        if event.status == .inProgress {
            return AnyView(
                HStack(spacing: 4) {
                    Circle().fill(Color.red).frame(width: 6, height: 6)
                    Text("En vivo")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.red)
                }
            )
        }
        guard let status, status != .pending else { return nil }
        let color: Color
        let label: String
        switch status {
        case .going:      color = .green;     label = "Vas"
        case .maybe:      color = .orange;    label = "Tal vez"
        case .declined:   color = Color(.tertiaryLabel); label = "No vas"
        case .waitlisted: color = .orange;    label = "Lista"
        case .pending:    return nil
        }
        return AnyView(
            Text(label)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(color)
        )
    }

    private func displayNameFor(_ row: ResourceRow) -> String {
        if case let .string(name) = row.metadata["name"] { return name }
        if case let .string(title) = row.metadata["title"] { return title }
        return row.resourceType.humanLabel
    }

    // MARK: - Pendings helpers

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

    private func pendingPriority(for raw: ActionPriority) -> ActionCard.Priority {
        switch raw {
        case .low:    return .low
        case .medium: return .medium
        case .high:   return .high
        case .urgent: return .urgent
        }
    }

    // MARK: - Empty state

    private var isFullyEmpty: Bool {
        let pendingsEmpty = inboxCoordinator?.actions.isEmpty ?? true
        let upcomingEmpty = upcomingFeed.isEmpty
        let pastEmpty = recentPastResources.isEmpty
        return pendingsEmpty && upcomingEmpty && pastEmpty
    }

    /// Canonical empty per Fase1HumanLayerRules §3: title names what
    /// the area IS, description reduces anxiety, single CTA. Replaces
    /// the previous capability-aware variants — the active group's
    /// modules are not visible at the empty-state point of decision.
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
}
