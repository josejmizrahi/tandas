import SwiftUI
import RuulUI
import RuulCore

public struct HomeView: View {
    @Bindable var coordinator: HomeCoordinator
    @Environment(AppState.self) private var app
    /// Fase 4b: Inbox content vive embebido en Home como sección "Pendientes".
    /// `nil` durante bootstrap (igual que homeCoordinator). El callback
    /// dispatch al `handleInboxAction` del padre — mismo handler que antes.
    public var inboxCoordinator: InboxCoordinator?
    public var onInboxActionTap: (UserAction) async -> Void = { _ in }
    public let userId: UUID
    public var onCreateEvent: () -> Void
    public var onOpenEvent: (Event) -> Void
    public var onOpenPastEvents: () -> Void
    public var onInvitePeople: (() -> Void)? = nil
    /// Tap del GroupSwitcher pill — abre `GroupSwitcherSheet` desde Home.
    /// Per AppShell.md: el switcher es chrome persistente en Home/Inbox/Activity.
    public var onSwitchGroup: () -> Void = {}
    /// Bumped by the parent (MainTabView) after the wizard creates a
    /// resource — drives the non-event-resources re-fetch via .task(id:).
    public var resourceRefreshToken: UUID

    public init(coordinator: HomeCoordinator, inboxCoordinator: InboxCoordinator?, onInboxActionTap: @escaping (UserAction) async -> Void = { _ in }, userId: UUID, onCreateEvent: @escaping () -> Void, onOpenEvent: @escaping (Event) -> Void, onOpenPastEvents: @escaping () -> Void, onInvitePeople: (() -> Void)? = nil, onSwitchGroup: @escaping () -> Void = {}, resourceRefreshToken: UUID = UUID()) {
        self.coordinator = coordinator
        self.inboxCoordinator = inboxCoordinator
        self.onInboxActionTap = onInboxActionTap
        self.userId = userId
        self.onCreateEvent = onCreateEvent
        self.onOpenEvent = onOpenEvent
        self.onOpenPastEvents = onOpenPastEvents
        self.onInvitePeople = onInvitePeople
        self.onSwitchGroup = onSwitchGroup
        self.resourceRefreshToken = resourceRefreshToken
    }

    @State private var showSettings: Bool = false

    @State private var nonEventResources: [ResourceRow] = []
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
                header
                nextEventSection
                pendingsSection
                resourcesSection
                upcomingListSection
                groupMemorySection
                pastEventsLink
            }
            .padding(.horizontal, RuulSpacing.lg)
            .padding(.top, RuulSpacing.xs)
            .padding(.bottom, RuulSpacing.s12)
        }
        .scrollIndicators(.hidden)
        .contentMargins(RuulSpacing.md, for: .scrollIndicators)
        .scrollEdgeEffectStyle(.soft, for: .vertical)
        .refreshable {
            async let h: Void = coordinator.refresh(force: true)
            async let i: Void? = inboxCoordinator?.refresh()
            async let r: Void = loadNonEventResources()
            async let m: Void = loadGroupMemory()
            _ = await (h, i, r, m)
        }
        .ruulAmbientScreen(palette: app.activeGroup?.ambientPalette)
        .task {
            async let h: Void = coordinator.refresh()
            async let i: Void? = inboxCoordinator?.refresh()
            _ = await (h, i)
        }
        .task(id: resourceRefreshToken) {
            await loadNonEventResources()
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
            await loadNonEventResources()
            await loadGroupMemory()
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet()
                .ruulSheetChrome(detents: [.medium, .large])
        }
        .sheet(item: $openedResource) { row in
            ResourceDetailSheet(resource: row)
                .ruulSheetChrome(detents: [.medium, .large])
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

    @MainActor
    private func loadNonEventResources() async {
        guard let groupId = app.activeGroup?.id else { return }
        let types: [ResourceType] = [.asset, .slot, .fund, .space, .right]
        do {
            let rows = try await app.resourceRepo.list(
                in: groupId,
                types: types,
                statuses: nil,
                limit: 50
            )
            nonEventResources = rows
        } catch {
            // Silent — section just stays empty.
        }
    }

    // MARK: - Header — Apple Sports style: tiny tracking-uppercase meta +
    // huge group name in display weight + settings button (top-right).

    private var header: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            HStack(alignment: .center) {
                if let group = app.activeGroup {
                    RuulGroupSwitcher(activeGroup: group, onTap: onSwitchGroup)
                } else {
                    Text("Inicio")
                        .ruulTextStyle(RuulTypography.title)
                        .foregroundStyle(Color.ruulTextPrimary)
                }
                Spacer()
                HStack(spacing: RuulSpacing.xs) {
                    if let onInvitePeople {
                        headerIconButton(
                            systemName: "person.badge.plus",
                            accessibilityLabel: "Invitar gente",
                            action: onInvitePeople
                        )
                    }
                    headerIconButton(
                        systemName: "gearshape",
                        accessibilityLabel: "Ajustes"
                    ) {
                        showSettings = true
                    }
                }
            }
            Text(greeting)
                .ruulTextStyle(RuulTypography.sectionLabelLg)
                .foregroundStyle(Color.ruulTextSecondary)
        }
        .padding(.top, RuulSpacing.md)
    }

    private func headerIconButton(
        systemName: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .ruulTextStyle(RuulTypography.headlineMedium)
                .foregroundStyle(Color.ruulTextPrimary)
                .frame(width: 40, height: 40)
                .background(Color.ruulSurface, in: Circle())
                .overlay(Circle().stroke(Color.ruulSeparator, lineWidth: 0.5))
                .accessibilityHidden(true)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: .now)
        switch hour {
        case 5..<12:  return "BUENOS DÍAS"
        case 12..<19: return "BUENAS TARDES"
        default:      return "BUENAS NOCHES"
        }
    }

    // MARK: - Next event hero — Apple Sports tile: full-bleed cover +
    // overlay content. Same DNA as EventCard but bigger aspect.

    @ViewBuilder
    private var nextEventSection: some View {
        SwiftUI.Group {
            if let error = coordinator.error, coordinator.nextEvent == nil {
                ErrorStateView(error: error, retry: { Task { await coordinator.refresh(force: true) } })
                    .frame(minHeight: 360, alignment: .top)
                    .transition(.opacity)
            } else if coordinator.isLoading && coordinator.nextEvent == nil {
                RuulLoadingState()
                    .frame(minHeight: 360, alignment: .top)
                    .transition(.opacity)
            } else if let next = coordinator.nextEvent {
                VStack(alignment: .leading, spacing: RuulSpacing.xs) {
                    Text("PRÓXIMO")
                        .ruulTextStyle(RuulTypography.sectionLabel)
                        .foregroundStyle(Color.ruulTextTertiary)
                    heroTile(next)
                }
                .transition(.opacity)
            } else {
                emptyHero
                    .transition(.opacity)
            }
        }
        .animation(.linear(duration: RuulDuration.fast), value: coordinator.error)
        .animation(.linear(duration: RuulDuration.fast), value: coordinator.isLoading)
        .animation(.linear(duration: RuulDuration.fast), value: coordinator.nextEvent?.id)
    }

    /// Compact list-row replacement for the previous full-poster hero —
    /// cover thumbnail + date / title / location stacked vertically +
    /// chevron, all wrapped in a glass card. Tap opens the event detail.
    /// Designed to stay ~100pt tall so the home doesn't get dominated by
    /// the next-event preview the way Apple Sports / Luma never do.
    private func heroTile(_ event: Event) -> some View {
        Button { onOpenEvent(event) } label: {
            HStack(alignment: .center, spacing: RuulSpacing.md) {
                cover(for: event)
                    .frame(width: 84, height: 84)
                    .clipShape(RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(heroDateLine(event))
                        .ruulTextStyle(RuulTypography.sectionLabel)
                        .foregroundStyle(Color.ruulTextTertiary)
                    Text(event.title)
                        .ruulTextStyle(RuulTypography.headline)
                        .foregroundStyle(Color.ruulTextPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    heroSubMeta(event)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .ruulTextStyle(RuulTypography.calloutBold)
                    .foregroundStyle(Color.ruulTextTertiary)
            }
            .padding(RuulSpacing.md)
            .ruulCardSurface(.glass, radius: RuulRadius.large)
        }
        .buttonStyle(.ruulPress)
    }

    /// One-line meta under the title. Priority: hosting-you badge,
    /// then recurrence badge, then location. EmptyView when none apply
    /// so the row collapses to date + title without dead space.
    @ViewBuilder
    private func heroSubMeta(_ event: Event) -> some View {
        if event.hostId == userId {
            inlineMetaBadge(icon: "star.fill", text: "Hosteas tú")
        } else if event.isRecurringGenerated {
            inlineMetaBadge(icon: "arrow.triangle.2.circlepath", text: "Recurrente")
        } else if let location = event.locationName, !location.isEmpty {
            Label(location, systemImage: "mappin.and.ellipse")
                .ruulTextStyle(RuulTypography.caption)
                .foregroundStyle(Color.ruulTextSecondary)
                .lineLimit(1)
        } else {
            EmptyView()
        }
    }

    private func inlineMetaBadge(icon: String, text: String) -> some View {
        HStack(spacing: RuulSpacing.xxs) {
            Image(systemName: icon)
                .ruulTextStyle(RuulTypography.caption)
            Text(text)
                .ruulTextStyle(RuulTypography.caption)
        }
        .foregroundStyle(Color.ruulTextSecondary)
        .padding(.horizontal, RuulSpacing.xs)
        .padding(.vertical, 2)
        .background(Color.ruulFillGlass, in: Capsule())
    }

    private func heroTopBadges(_ event: Event) -> some View {
        VStack {
            HStack(spacing: RuulSpacing.xs) {
                if event.hostId == userId {
                    overlayBadge(icon: "star.fill", text: "Hosteas tú", tint: Color.ruulImageBadge)
                }
                Spacer()
                if event.isRecurringGenerated {
                    overlayBadge(icon: "arrow.triangle.2.circlepath", text: "Recurrente", tint: Color.ruulImageBadge)
                }
            }
            .padding(RuulSpacing.md)
            Spacer()
        }
    }

    private func heroBottomBlock(_ event: Event) -> some View {
        VStack(alignment: .leading, spacing: RuulSpacing.md) {
            VStack(alignment: .leading, spacing: RuulSpacing.xs) {
                if coordinator.isCrossGroupsMode,
                   let origin = coordinator.group(for: event) {
                    RuulOriginTag(group: origin)
                }
                Text(heroDateLine(event))
                    .ruulTextStyle(RuulTypography.sectionLabelLg)
                    .foregroundStyle(Color.ruulOnImageSecondary)

                Text(event.title)
                    .ruulTextStyle(RuulTypography.displayMedium)
                    .foregroundStyle(Color.ruulOnImage)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .shadow(color: Color.ruulImageTextShadow, radius: 4, x: 0, y: 2)
            }

            if let location = event.locationName, !location.isEmpty {
                Label(location, systemImage: "mappin.and.ellipse")
                    .ruulTextStyle(RuulTypography.callout)
                    .foregroundStyle(Color.ruulOnImageSecondary)
            }

            // RSVP CTA — Apple Sports doesn't have inline CTAs, but for ruul
            // it makes the next-action obvious. Keep it white outline-style
            // so the cover stays the visual anchor.
            if let myRSVP = coordinator.myRSVPs[event.id] {
                if myRSVP.status == .pending {
                    inlineCTAButton(for: event)
                } else {
                    rsvpStatusOverlay(for: myRSVP.status)
                }
            } else {
                inlineCTAButton(for: event)
            }
        }
        .padding(RuulSpacing.lg)
    }

    private func heroDateLine(_ event: Event) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(event.startsAt) {
            return "HOY · \(event.startsAt.ruulShortTime)"
        }
        if calendar.isDateInTomorrow(event.startsAt) {
            return "MAÑANA · \(event.startsAt.ruulShortTime)"
        }
        let interval = event.startsAt.timeIntervalSince(.now)
        let days = Int(interval / 86_400)
        if days < 7 {
            return "EN \(days) DÍAS · \(event.startsAt.ruulShortTime)"
        }
        return "\(event.startsAt.ruulShortDate.uppercased()) · \(event.startsAt.ruulShortTime)"
    }

    private func inlineCTAButton(for event: Event) -> some View {
        Button { onOpenEvent(event) } label: {
            HStack {
                Text("Ver evento")
                    .ruulTextStyle(RuulTypography.headline)
                Spacer()
                Image(systemName: "arrow.right")
                    .ruulTextStyle(RuulTypography.calloutBold)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(Color.ruulOnImageInverse)
            .padding(RuulSpacing.md)
            .background(Color.ruulOnImage, in: RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous))
        }
        .buttonStyle(.ruulPress)
        .padding(.top, RuulSpacing.xs)
    }

    private func rsvpStatusOverlay(for status: RSVPStatus) -> some View {
        let (dotColor, text): (Color, String) = {
            switch status {
            case .going:      return (.ruulPositive, "Vas")
            case .maybe:      return (.ruulWarning, "Estás considerando")
            case .declined:   return (.ruulNegative,   "No vas")
            case .waitlisted: return (.ruulWarning, "En lista de espera")
            case .pending:    return (.ruulTextTertiary,    "Pendiente")
            }
        }()
        return HStack(spacing: RuulSpacing.xs) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
            Text(text)
                .ruulTextStyle(RuulTypography.body)
                .foregroundStyle(Color.ruulOnImage)
            Spacer()
            Image(systemName: "chevron.right")
                .ruulTextStyle(RuulTypography.captionBold)
                .foregroundStyle(Color.ruulOnImageSecondary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, RuulSpacing.sm)
        .padding(.horizontal, RuulSpacing.md)
        .background(Color.ruulImagePill, in: RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                .stroke(Color.ruulImagePillBorder, lineWidth: 0.5)
        )
        .padding(.top, RuulSpacing.xs)
    }

    // MARK: - Empty state

    @ViewBuilder
    private var resourcesSection: some View {
        if !nonEventResources.isEmpty {
            VStack(alignment: .leading, spacing: RuulSpacing.sm) {
                HStack(alignment: .firstTextBaseline) {
                    Text("LO QUE ESTÁN ORGANIZANDO")
                        .ruulTextStyle(RuulTypography.sectionLabel)
                        .foregroundStyle(Color.ruulTextTertiary)
                    Spacer()
                    Text("\(nonEventResources.count)")
                        .ruulTextStyle(RuulTypography.statSmall)
                        .foregroundStyle(Color.ruulTextTertiary)
                }
                VStack(spacing: RuulSpacing.xs) {
                    ForEach(nonEventResources) { row in
                        resourceCard(row)
                    }
                }
            }
        }
    }

    private func resourceCard(_ row: ResourceRow) -> some View {
        Button {
            openedResource = row
        } label: {
            HStack(spacing: RuulSpacing.sm) {
                ZStack {
                    Circle()
                        .fill(Color.ruulSurface)
                        .frame(width: 40, height: 40)
                    Image(systemName: ResourceTypeChrome.resolve(row.resourceType).symbol)
                        .ruulTextStyle(RuulTypography.bodyLarge)
                        .foregroundStyle(Color.ruulTextPrimary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayNameFor(row))
                        .ruulTextStyle(RuulTypography.body)
                        .foregroundStyle(Color.ruulTextPrimary)
                    Text(row.resourceType.humanLabel)
                        .ruulTextStyle(RuulTypography.caption)
                        .foregroundStyle(Color.ruulTextSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .ruulTextStyle(RuulTypography.labelSemibold)
                    .foregroundStyle(Color.ruulTextTertiary)
            }
            .padding(RuulSpacing.md)
            .ruulCardSurface(.glass, radius: RuulRadius.medium)
        }
        .buttonStyle(.plain)
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
                HStack(alignment: .firstTextBaseline) {
                    Text("PENDIENTES")
                        .ruulTextStyle(RuulTypography.sectionLabel)
                        .foregroundStyle(Color.ruulTextTertiary)
                    Spacer()
                    Text("\(coord.actions.count)")
                        .ruulTextStyle(RuulTypography.statSmall)
                        .foregroundStyle(Color.ruulTextTertiary)
                }
                VStack(spacing: RuulSpacing.xs) {
                    ForEach(coord.actions.prefix(3)) { action in
                        ActionCard(
                            icon: pendingIcon(for: action.actionType),
                            meta: pendingMeta(for: action, coordinator: coord),
                            title: action.title,
                            subtitle: action.body,
                            priority: pendingPriority(for: action.priority),
                            timeRemaining: nil,
                            onTap: {
                                Task { await onInboxActionTap(action) }
                            }
                        )
                    }
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

    // MARK: - Upcoming list — section header + tile cards.

    @ViewBuilder
    private var upcomingListSection: some View {
        let rest = Array(coordinator.upcomingEvents.dropFirst())
        if !rest.isEmpty {
            VStack(alignment: .leading, spacing: RuulSpacing.md) {
                HStack(alignment: .firstTextBaseline) {
                    Text("PRÓXIMOS")
                        .ruulTextStyle(RuulTypography.sectionLabel)
                        .foregroundStyle(Color.ruulTextTertiary)
                    Spacer()
                    Text("\(rest.count)")
                        .ruulTextStyle(RuulTypography.statSmall)
                        .foregroundStyle(Color.ruulTextTertiary)
                }
                // Apple Invites pattern: hero anchors the eye, rest are
                // compact rows so the screen breathes. Heavy EventCards
                // here would compete with the hero for attention.
                VStack(spacing: RuulSpacing.xs) {
                    ForEach(rest) { event in
                        EventRow(
                            event: event,
                            originGroup: coordinator.isCrossGroupsMode
                                ? coordinator.group(for: event)
                                : nil,
                            myStatus: coordinator.myRSVPs[event.id]?.status
                        ) {
                            onOpenEvent(event)
                        }
                    }
                }
            }
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
                            icon: "calendar.badge.checkmark"
                        )
                    }
                    if groupMemory.resolvedVotesCount > 0 {
                        memoryStatCard(
                            value: memoryCountLabel(groupMemory.resolvedVotesCount, cap: 200),
                            caption: "decisiones tomadas",
                            icon: "checkmark.seal"
                        )
                    }
                }
            }
        }
    }

    private func memoryCountLabel(_ count: Int, cap: Int) -> String {
        count >= cap ? "\(cap)+" : "\(count)"
    }

    private func memoryStatCard(
        value: String,
        caption: String,
        icon: String
    ) -> some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
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

    // MARK: - Cover + badge helpers

    @ViewBuilder
    private func cover(for event: Event) -> some View {
        if let url = event.coverImageURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img): img.resizable().scaledToFill()
                default:                fallbackCover(for: event)
                }
            }
        } else {
            fallbackCover(for: event)
        }
    }

    private func fallbackCover(for event: Event) -> some View {
        let cover = RuulCoverCatalog.cover(named: event.coverImageName)
        return RuulCoverView(cover)
    }

    private func overlayBadge(icon: String, text: String, tint: Color) -> some View {
        HStack(spacing: RuulSpacing.xxs) {
            Image(systemName: icon)
                .ruulTextStyle(RuulTypography.microBold)
                .accessibilityHidden(true)
            Text(text)
                .ruulTextStyle(RuulTypography.sectionLabel)
        }
        .foregroundStyle(Color.ruulOnImage)
        .padding(.horizontal, RuulSpacing.xs)
        .padding(.vertical, RuulSpacing.xxs + 1)
        .background(tint, in: Capsule())
    }
}
