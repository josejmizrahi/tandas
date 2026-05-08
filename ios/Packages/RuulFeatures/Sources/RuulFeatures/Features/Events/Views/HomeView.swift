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

    public init(coordinator: HomeCoordinator, inboxCoordinator: InboxCoordinator?, onInboxActionTap: @escaping (UserAction) async -> Void = { _ in }, userId: UUID, onCreateEvent: @escaping () -> Void, onOpenEvent: @escaping (Event) -> Void, onOpenPastEvents: @escaping () -> Void, onInvitePeople: (() -> Void)? = nil) {
        self.coordinator = coordinator
        self.inboxCoordinator = inboxCoordinator
        self.onInboxActionTap = onInboxActionTap
        self.userId = userId
        self.onCreateEvent = onCreateEvent
        self.onOpenEvent = onOpenEvent
        self.onOpenPastEvents = onOpenPastEvents
        self.onInvitePeople = onInvitePeople
    }

    @State private var showSettings: Bool = false

    public var body: some View {
        ZStack {
            Color.ruulBackground.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: RuulSpacing.s8) {
                    header
                    nextEventSection
                    pendingsSection
                    upcomingListSection
                    pastEventsLink
                }
                .padding(.horizontal, RuulSpacing.lg)
                .padding(.top, RuulSpacing.xs)
                .padding(.bottom, RuulSpacing.s12)
            }
            .scrollIndicators(.hidden)
            .refreshable { await coordinator.refresh(force: true) }
            .overlay(alignment: .bottomTrailing) { fab }
        }
        .task { await coordinator.refresh() }
        .sheet(isPresented: $showSettings) {
            SettingsSheet()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    // MARK: - Header — Apple Sports style: tiny tracking-uppercase meta +
    // huge group name in display weight + settings button (top-right).

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(greeting)
                    .ruulTextStyle(RuulTypography.sectionLabelLg)
                    .foregroundStyle(Color.ruulTextSecondary)
                Text("Inicio")
                    .ruulTextStyle(RuulTypography.displayMedium)
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
        .padding(.top, RuulSpacing.md)
    }

    private func headerIconButton(
        systemName: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .medium))
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

    private func heroTile(_ event: Event) -> some View {
        Button { onOpenEvent(event) } label: {
            ZStack(alignment: .bottomLeading) {
                cover(for: event)
                    .aspectRatio(4/5, contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .clipped()

                LinearGradient(
                    stops: [
                        .init(color: .clear,                    location: 0.00),
                        .init(color: .clear,                    location: 0.35),
                        .init(color: Color.ruulImageVignetteMid.opacity(1.0), location: 0.65),
                        .init(color: Color.ruulImageVignetteDeep.opacity(1.0), location: 1.00)
                    ],
                    startPoint: .top, endPoint: .bottom
                )

                heroTopBadges(event)
                heroBottomBlock(event)
            }
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: RuulRadius.extraLarge, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.extraLarge, style: .continuous)
                    .stroke(Color.ruulSeparator, lineWidth: 0.5)
            )
        }
        .buttonStyle(.ruulPress)
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
                    .font(.system(size: 14, weight: .bold))
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
                .font(.system(size: 12, weight: .bold))
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

    private var emptyHero: some View {
        VStack(spacing: RuulSpacing.lg) {
            ZStack {
                Circle()
                    .fill(Color.ruulSurface)
                    .frame(width: 80, height: 80)
                Image(systemName: "calendar.badge.plus")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(Color.ruulTextPrimary)
                    .accessibilityHidden(true)
            }
            VStack(spacing: RuulSpacing.xs) {
                Text("Aún no hay eventos")
                    .ruulTextStyle(RuulTypography.titleLarge)
                    .foregroundStyle(Color.ruulTextPrimary)
                Text("Crea el primero — tu grupo lo verá en segundos.")
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextSecondary)
                    .multilineTextAlignment(.center)
            }
            RuulButton("Crear evento", systemImage: "plus", style: .primary, size: .large, action: onCreateEvent)
        }
        .frame(maxWidth: .infinity)
        .padding(RuulSpacing.xxl)
        .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.extraLarge, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.extraLarge, style: .continuous)
                .stroke(Color.ruulSeparator, lineWidth: 0.5)
        )
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

    // MARK: - Past events link — Apple Sports style: subtle row, no chrome.

    @ViewBuilder
    private var pastEventsLink: some View {
        if !coordinator.upcomingEvents.isEmpty {
            Button(action: onOpenPastEvents) {
                HStack(spacing: RuulSpacing.xs) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 14, weight: .semibold))
                        .accessibilityHidden(true)
                    Text("Ver historial")
                        .ruulTextStyle(RuulTypography.headline)
                    Spacer()
                    Image(systemName: "arrow.right")
                        .font(.system(size: 12, weight: .bold))
                        .accessibilityHidden(true)
                }
                .foregroundStyle(Color.ruulTextSecondary)
                .padding(.vertical, RuulSpacing.md)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - FAB — Apple Sports has no brand-color FABs: solid black on white,
    // monochrome chrome with shadow.

    private var fab: some View {
        Button(action: onCreateEvent) {
            Image(systemName: "plus")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Color.ruulTextInverse)
                .frame(width: 60, height: 60)
                .background(Color.ruulTextPrimary, in: Circle())
                .ruulElevation(.lg)
                .accessibilityHidden(true)
        }
        .buttonStyle(.ruulPress)
        .padding(RuulSpacing.lg)
        .accessibilityLabel("Crear evento")
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
                .font(.system(size: 10, weight: .bold))
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
