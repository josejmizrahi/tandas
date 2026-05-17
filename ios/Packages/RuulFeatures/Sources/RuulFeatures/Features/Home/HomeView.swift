import SwiftUI
import RuulUI
import RuulCore

public struct HomeView: View {
    @Bindable var coordinator: HomeCoordinator
    @Environment(AppState.self) private var app
    @Environment(RootRouter.self) private var router
    /// Fase 4b: Inbox content vive embebido en Home como sección "Pendientes".
    /// `nil` durante bootstrap (igual que homeCoordinator). El callback
    /// dispatch al `handleInboxAction` del padre — mismo handler que antes.
    public var inboxCoordinator: InboxCoordinator?
    public var onInboxActionTap: (UserAction) async -> Void = { _ in }
    public let userId: UUID
    public var onCreateEvent: () -> Void
    public var onOpenEvent: (Event) -> Void
    public var onOpenPastEvents: () -> Void
    /// MEMORIA DEL GRUPO "decisiones tomadas" tile tap. Abre la historia
    /// completa (sin filtro — desde ahí el usuario filtra a "Votos"
    /// con el chip). Default no-op para callsites pre-P1.
    public var onOpenGroupHistory: () -> Void = {}
    public var onInvitePeople: (() -> Void)? = nil
    /// Tap del GroupSwitcher pill — abre `GroupSwitcherSheet` desde Home.
    /// Per AppShell.md: el switcher es chrome persistente en Home/Inbox/Activity.
    public var onSwitchGroup: () -> Void = {}
    /// Bumped by the parent (MainTabView) after the wizard creates a
    /// resource — drives the non-event-resources re-fetch via .task(id:).
    public var resourceRefreshToken: UUID

    public init(coordinator: HomeCoordinator, inboxCoordinator: InboxCoordinator?, onInboxActionTap: @escaping (UserAction) async -> Void = { _ in }, userId: UUID, onCreateEvent: @escaping () -> Void, onOpenEvent: @escaping (Event) -> Void, onOpenPastEvents: @escaping () -> Void, onOpenGroupHistory: @escaping () -> Void = {}, onInvitePeople: (() -> Void)? = nil, onSwitchGroup: @escaping () -> Void = {}, resourceRefreshToken: UUID = UUID()) {
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

    @State private var groupMemory: GroupMemory = .empty

    /// Lightweight aggregate the home renders to give the group a sense
    /// of accumulated history — closes audit gap #10 (sin memoria/streaks/
    /// totales). Each counter is best-effort: failures collapse the
    /// section instead of surfacing an error, since the rest of the
    /// home still works without it.
    private struct GroupMemory: Equatable {
        var pastEventsCount: Int
        var resolvedVotesCount: Int

        var hasAnyContent: Bool { pastEventsCount > 0 || resolvedVotesCount > 0 }

        static let empty = GroupMemory(pastEventsCount: 0, resolvedVotesCount: 0)
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RuulSpacing.s8) {
                pendingsSection
                upcomingFeedSection
                groupMemorySection
                pastEventsLink
            }
            .padding(.horizontal, RuulSpacing.lg)
            .padding(.top, RuulSpacing.md)
            .padding(.bottom, RuulSpacing.s12)
        }
        .scrollIndicators(.hidden)
        .contentMargins(RuulSpacing.md, for: .scrollIndicators)
        .scrollEdgeEffectStyle(.soft, for: .vertical)
        .refreshable {
            async let h: Void = coordinator.refresh(force: true)
            async let i: Void? = inboxCoordinator?.refresh()
            async let m: Void = loadGroupMemory()
            _ = await (h, i, m)
        }
        .ruulAmbientScreen(palette: nil)
        .ruulAppToolbar()
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let onInvitePeople {
                    Button(action: onInvitePeople) {
                        Image(systemName: "person.badge.plus")
                    }
                    .accessibilityLabel("Invitar gente")
                }
                Button { router.selectTab(.profile) } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Ajustes")
            }
        }
        .task {
            async let h: Void = coordinator.refresh()
            async let i: Void? = inboxCoordinator?.refresh()
            _ = await (h, i)
        }
        .task(id: resourceRefreshToken) {
            await loadGroupMemory()
        }
        // Group switch (active group changes via the switcher) doesn't bump
        // resourceRefreshToken, so without this second .task the @State
        // stays bound to whatever group was active when the view first
        // appeared — past events + resolved votes from the prior group
        // bleed into the new one (or vanish if the prior group had none,
        // which is exactly what hides the Memoria section silently).
        .task(id: app.activeGroup?.id) {
            await loadGroupMemory()
        }
        .fullScreenCover(item: $openedResource) { row in
            ResourceDetailSheet(resource: row)

        }
    }

    /// Loads the lightweight aggregates that back the "Memoria del grupo"
    /// section. Two reads in parallel (past events + all votes), both
    /// capped at sensible limits — the section labels show "200+" if we
    /// hit the cap so users still get a useful signal for long-running
    /// groups. Failures collapse the section instead of surfacing.
    ///
    /// Past-event count uses `resourceRepo` (polymorphic) filtered to
    /// `.event` rows with terminal statuses ("completed" / "cancelled").
    /// Date-bound precision is not needed here — it's a heuristic counter.
    @MainActor
    private func loadGroupMemory() async {
        guard let groupId = app.activeGroup?.id else {
            groupMemory = .empty
            return
        }
        async let pastTask = (try? await app.resourceRepo.list(
            in: groupId,
            types: [.event],
            statuses: ["completed", "cancelled"],
            limit: 200
        )) ?? []
        async let votesTask = (try? await app.voteRepo.votes(for: groupId)) ?? []
        let past = await pastTask
        let votes = await votesTask
        groupMemory = GroupMemory(
            pastEventsCount: past.count,
            resolvedVotesCount: votes.filter { $0.status == .resolved }.count
        )
    }


    // MARK: - Polymorphic upcoming feed

    private struct UpcomingFeedItem: Identifiable {
        let id: UUID
        let kind: Kind
        let sortDate: Date
        enum Kind {
            case event(Event)
            case resource(ResourceRow)
        }
    }

    /// Cross-type feed: every upcoming event AND every other resource
    /// (fund, asset, space, slot, right) collapsed into one chronological
    /// stream. No special "next event" hero — events render with the same
    /// row chrome as every other resource so the home reads as a single
    /// activity list per the canonical "una página universal sin importar
    /// el resource type" doctrine.
    private var upcomingFeed: [UpcomingFeedItem] {
        let events = coordinator.upcomingEvents.map { event in
            UpcomingFeedItem(
                id: event.id,
                kind: .event(event),
                sortDate: event.startsAt
            )
        }
        let resources = coordinator.upcomingResources.map { row in
            UpcomingFeedItem(
                id: row.id,
                kind: .resource(row),
                sortDate: row.createdAt
            )
        }
        return (events + resources).sorted { $0.sortDate < $1.sortDate }
    }

    @ViewBuilder
    private var upcomingFeedSection: some View {
        if let error = coordinator.error, upcomingFeed.isEmpty {
            ErrorStateView(error: error, retry: { Task { await coordinator.refresh(force: true) } })
                .frame(minHeight: 240, alignment: .top)
        } else if coordinator.isLoading && upcomingFeed.isEmpty {
            RuulLoadingState()
                .frame(minHeight: 240, alignment: .top)
        } else if upcomingFeed.isEmpty {
            emptyHero
        } else {
            VStack(alignment: .leading, spacing: RuulSpacing.md) {
                RuulListSectionHeader("PRÓXIMO", count: upcomingFeed.count)
                RuulSeparatedRows(items: upcomingFeed) { item in
                    activityRow(item)
                }
            }
        }
    }

    /// Single row used for every feed entry — events and other resources
    /// share the same chrome (40×40 circle SF symbol + title + meta line
    /// + optional trailing pill + chevron). Per "no me gusta que event
    /// tenga un diseño diferente que todo lo demás en home": events stop
    /// drawing a cover thumbnail here; the icon comes from
    /// `ResourceTypeChrome` like every other type.
    @ViewBuilder
    private func activityRow(_ item: UpcomingFeedItem) -> some View {
        switch item.kind {
        case .event(let event):
            let status = coordinator.myRSVPs[event.id]?.status
            unifiedRow(
                icon: ResourceTypeChrome.resolve(.event).symbol,
                title: event.title,
                meta: eventMetaLine(event),
                trailing: rsvpTrailing(for: event, status: status),
                onTap: { onOpenEvent(event) }
            )
        case .resource(let row):
            unifiedRow(
                icon: ResourceTypeChrome.resolve(row.resourceType).symbol,
                title: displayNameFor(row),
                meta: subtitleFor(row),
                trailing: nil,
                onTap: { openedResource = row }
            )
        }
    }

    /// Per-type one-liner under the resource name. Falls back to the
    /// generic type label so a row is never bare. For assets specifically
    /// it surfaces whatever state the metadata shortcut carries (loaned
    /// out > current custodian > "Del grupo") so a glance at Home tells
    /// the user who has it right now without opening the detail sheet.
    private func subtitleFor(_ row: ResourceRow) -> String {
        let type = row.resourceType.humanLabel
        switch row.resourceType {
        case .asset:
            if let raw = row.metadata["checked_out_to"]?.stringValue, !raw.isEmpty {
                return "\(type) · Prestado"
            }
            if let raw = row.metadata["custodian_id"]?.stringValue, !raw.isEmpty {
                return "\(type) · En custodia"
            }
            return "\(type) · Del grupo"
        case .fund:
            if let raw = row.metadata["locked_at"]?.stringValue, !raw.isEmpty {
                return "\(type) · Bloqueado"
            }
            return type
        case .space:
            // Capacity is the most useful one-liner shortcut — location_name
            // is long-form and crowds the row. Falls back to the bare type
            // label when no capacity is set.
            if let cap = row.metadata["capacity"]?.intValue {
                return "\(type) · \(cap) cupos"
            }
            return type
        default:
            return type
        }
    }

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
                        .ruulTextStyle(RuulTypography.bodyLarge)
                        .foregroundStyle(Color.ruulTextPrimary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .ruulTextStyle(RuulTypography.body)
                        .foregroundStyle(Color.ruulTextPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let meta {
                        Text(meta)
                            .ruulTextStyle(RuulTypography.caption)
                            .foregroundStyle(Color.ruulTextSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if let trailing {
                    trailing
                }
                Image(systemName: "chevron.right")
                    .ruulTextStyle(RuulTypography.labelSemibold)
                    .foregroundStyle(Color.ruulTextTertiary)
            }
            .padding(.vertical, RuulSpacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Human meta for an event row. Same shape as a non-event row's type
    /// label ("Fondo", "Activo") — kept to one terse line so the feed
    /// rhythm stays even regardless of payload.
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

    /// Trailing RSVP indicator — a small dot + label that mirrors the
    /// status colors used on the detail page. Returns nil for `.pending`
    /// (the chevron alone carries the affordance) and for events that
    /// don't have a viewer RSVP yet.
    private func rsvpTrailing(for event: Event, status: RSVPStatus?) -> AnyView? {
        if event.status == .inProgress {
            return AnyView(
                HStack(spacing: 4) {
                    Circle().fill(Color.ruulNegative).frame(width: 6, height: 6)
                    Text("EN VIVO")
                        .ruulTextStyle(RuulTypography.sectionLabel)
                        .foregroundStyle(Color.ruulNegative)
                }
            )
        }
        guard let status, status != .pending else { return nil }
        let color: Color
        let label: String
        switch status {
        case .going:      color = .ruulPositive;     label = "Vas"
        case .maybe:      color = .ruulWarning;      label = "Tal vez"
        case .declined:   color = .ruulTextTertiary; label = "No vas"
        case .waitlisted: color = .ruulWarning;      label = "Lista"
        case .pending:    return nil
        }
        return AnyView(
            Text(label)
                .ruulTextStyle(RuulTypography.sectionLabel)
                .foregroundStyle(color)
        )
    }

    private func displayNameFor(_ row: ResourceRow) -> String {
        if case let .string(name) = row.metadata["name"] { return name }
        if case let .string(title) = row.metadata["title"] { return title }
        return row.resourceType.humanLabel
    }

    /// Capability-aware empty state per OpenPlatform S2. Reads the active
    /// group's modules and chooses copy + iconography that matches what
    /// the group is set up to do.
    private enum HomeEmptyVariant {
        case events      // rsvp/check_in/basic_fines stack — "crea tu primer evento"
        case asset       // slot/booking/asset stack — "agrega tu primer slot"
        case fund        // fund/contribution stack — "agrega tu primer fondo"
        case bare        // no modules — "personaliza el grupo"

        var icon: String {
            switch self {
            case .events: return "calendar.badge.plus"
            case .asset:  return "key.fill"
            case .fund:   return "banknote"
            case .bare:   return "square.dashed"
            }
        }

        var title: String {
            switch self {
            case .events: return "Aún no hay eventos"
            case .asset:  return "Aún no hay slots"
            case .fund:   return "Aún no hay aportaciones"
            case .bare:   return "Tu grupo está listo"
            }
        }

        var summary: String {
            switch self {
            case .events: return "Crea el primero — tu grupo lo verá en segundos."
            case .asset:  return "Agrega una ventana de uso y reserva tu primer turno."
            case .fund:   return "Define el fondo y empieza a recibir aportaciones."
            case .bare:   return "Crea tu primer recurso para empezar a usarlo."
            }
        }

        var ctaLabel: String {
            switch self {
            case .events: return "Crear evento"
            case .asset:  return "Crear slot"
            case .fund:   return "Crear fondo"
            case .bare:   return "Crear recurso"
            }
        }
    }

    private var emptyHeroVariant: HomeEmptyVariant {
        let modules = Set(app.activeGroup?.effectiveActiveModules ?? [])
        if modules.contains("rsvp") || modules.contains("check_in") || modules.contains("basic_fines") {
            return .events
        }
        if modules.contains("slot_assignment") {
            return .asset
        }
        if modules.contains("common_fund") {
            return .fund
        }
        return .bare
    }

    private var emptyHero: some View {
        let variant = emptyHeroVariant
        return VStack(spacing: RuulSpacing.lg) {
            ZStack {
                Circle()
                    .fill(Color.ruulSurface)
                    .frame(width: 80, height: 80)
                Image(systemName: variant.icon)
                    .ruulTextStyle(RuulTypography.displayMedium)
                    .foregroundStyle(Color.ruulTextPrimary)
                    .accessibilityHidden(true)
            }
            VStack(spacing: RuulSpacing.xs) {
                Text(variant.title)
                    .ruulTextStyle(RuulTypography.titleLarge)
                    .foregroundStyle(Color.ruulTextPrimary)
                Text(variant.summary)
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextSecondary)
                    .multilineTextAlignment(.center)
            }
            RuulButton(variant.ctaLabel, systemImage: "plus", style: .primary, size: .large, action: onCreateEvent)
        }
        .frame(maxWidth: .infinity)
        .padding(RuulSpacing.xxl)
        .ruulCardSurface(.glass, radius: RuulRadius.extraLarge)
        .transition(.asymmetric(
            insertion: .scale(scale: 0.95).combined(with: .opacity),
            removal: .opacity
        ))
    }

    // MARK: - Pendings — Fase 4b: Inbox content embedded como sección.
    //
    // Renders top 3 UserActions del `inboxCoordinator`. Tap dispatch al
    // `onInboxActionTap` del padre (MainTabView.handleInboxAction). Cuando
    // hay >3 pendings podemos agregar un "Ver todas" link en una iteración
    // posterior — V1 corta a 3 para no canibalizar el hero del próximo evento.

    @ViewBuilder
    private var pendingsSection: some View {
        if let coord = inboxCoordinator, !coord.actions.isEmpty {
            VStack(alignment: .leading, spacing: RuulSpacing.md) {
                RuulListSectionHeader("PENDIENTES", count: coord.actions.count)
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

    // MARK: - Memoria del grupo — accumulated aggregates that surface the
    // group's history (eventos cerrados, decisiones resueltas). Hidden
    // until at least one counter is non-zero, otherwise an empty group
    // would render a permanent placeholder. Cap-label ("200+") when we
    // hit the fetch limit so users see "more than we counted" instead
    // of a misleading flat number.

    @ViewBuilder
    private var groupMemorySection: some View {
        if groupMemory.hasAnyContent {
            VStack(alignment: .leading, spacing: RuulSpacing.sm) {
                Text("MEMORIA DEL GRUPO")
                    .ruulTextStyle(RuulTypography.sectionLabel)
                    .foregroundStyle(Color.ruulTextTertiary)

                HStack(spacing: RuulSpacing.sm) {
                    if groupMemory.pastEventsCount > 0 {
                        memoryStatCard(
                            value: memoryCountLabel(groupMemory.pastEventsCount, cap: 200),
                            caption: "eventos juntos",
                            icon: "calendar.badge.checkmark",
                            action: onOpenPastEvents
                        )
                    }
                    if groupMemory.resolvedVotesCount > 0 {
                        memoryStatCard(
                            value: memoryCountLabel(groupMemory.resolvedVotesCount, cap: 200),
                            caption: "decisiones tomadas",
                            icon: "checkmark.seal",
                            action: onOpenGroupHistory
                        )
                    }
                }
            }
        }
    }

    private func memoryCountLabel(_ count: Int, cap: Int) -> String {
        count >= cap ? "\(cap)+" : "\(count)"
    }

    /// Stat card. Tappeable cuando hay un destino — antes era display-only
    /// (UXJourney "MEMORIA tappeable"). Cards sin acción siguen rendering
    /// igual pero sin Button wrap para no leaky el press affordance.
    @ViewBuilder
    private func memoryStatCard(
        value: String,
        caption: String,
        icon: String,
        action: (() -> Void)? = nil
    ) -> some View {
        let content = VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            HStack(spacing: RuulSpacing.xs) {
                Image(systemName: icon)
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextSecondary)
                    .accessibilityHidden(true)
                Text(caption.uppercased())
                    .ruulTextStyle(RuulTypography.sectionLabel)
                    .foregroundStyle(Color.ruulTextSecondary)
                    .lineLimit(1)
            }
            Text(value)
                .ruulTextStyle(RuulTypography.displayMedium)
                .foregroundStyle(Color.ruulTextPrimary)
        }
        .padding(RuulSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ruulCardSurface(.glass, radius: RuulRadius.medium)

        if let action {
            Button(action: action) { content }
                .buttonStyle(.ruulPress)
        } else {
            content
        }
    }

    // MARK: - Past events link — Apple Sports style: subtle row, no chrome.

    @ViewBuilder
    private var pastEventsLink: some View {
        if !coordinator.upcomingEvents.isEmpty {
            Button(action: onOpenPastEvents) {
                HStack(spacing: RuulSpacing.xs) {
                    Image(systemName: "clock.arrow.circlepath")
                        .ruulTextStyle(RuulTypography.labelSemibold)
                        .accessibilityHidden(true)
                    Text("Ver historial")
                        .ruulTextStyle(RuulTypography.headline)
                    Spacer()
                    Image(systemName: "arrow.right")
                        .ruulTextStyle(RuulTypography.captionBold)
                        .accessibilityHidden(true)
                }
                .foregroundStyle(Color.ruulTextSecondary)
                .padding(.vertical, RuulSpacing.md)
            }
            .buttonStyle(.plain)
        }
    }

}
