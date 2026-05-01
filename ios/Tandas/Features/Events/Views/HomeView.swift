import SwiftUI

struct HomeView: View {
    @Bindable var coordinator: HomeCoordinator
    let userId: UUID
    var onCreateEvent: () -> Void
    var onOpenEvent: (Event) -> Void
    var onOpenPastEvents: () -> Void

    var body: some View {
        ZStack {
            Color.ruulBackgroundCanvas.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: RuulSpacing.s7) {
                    header
                    nextEventSection
                    upcomingListSection
                    pastEventsLink
                }
                .padding(.horizontal, RuulSpacing.s5)
                .padding(.top, RuulSpacing.s4)
                .padding(.bottom, RuulSpacing.s10)
            }
            .refreshable { await coordinator.refresh(force: true) }
            .overlay(alignment: .bottomTrailing) { fab }
        }
        .task { await coordinator.refresh() }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .center) {
            Text("ruul")
                .font(.system(size: 28, weight: .bold))
                .tracking(-0.5)
                .foregroundStyle(
                    LinearGradient(
                        colors: [.ruulAccentPrimary, .ruulAccentSecondary],
                        startPoint: .leading, endPoint: .trailing
                    )
                )
            Spacer()
            Text(coordinator.group.name)
                .ruulTextStyle(RuulTypography.callout)
                .foregroundStyle(Color.ruulTextSecondary)
        }
    }

    @ViewBuilder
    private var nextEventSection: some View {
        if coordinator.isLoading && coordinator.nextEvent == nil {
            LoadingStateView(.detail)
        } else if let next = coordinator.nextEvent {
            VStack(alignment: .leading, spacing: RuulSpacing.s3) {
                Text("Próximo")
                    .ruulTextStyle(RuulTypography.footnote)
                    .foregroundStyle(Color.ruulTextSecondary)
                Button { onOpenEvent(next) } label: {
                    nextEventCard(next)
                }
                .buttonStyle(.ruulPress)
            }
        } else {
            EmptyStateView(
                systemImage: "calendar",
                title: "No hay eventos programados",
                message: "Crea el primero para empezar.",
                primaryAction: ("Crear evento", onCreateEvent)
            )
        }
    }

    private func nextEventCard(_ event: Event) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            cover(for: event)
                .frame(height: 180)
                .clipShape(
                    UnevenRoundedRectangle(
                        topLeadingRadius: RuulRadius.lg,
                        topTrailingRadius: RuulRadius.lg
                    )
                )
            VStack(alignment: .leading, spacing: RuulSpacing.s3) {
                HStack(spacing: RuulSpacing.s2) {
                    if event.hostId == userId {
                        Text("Hosteas")
                            .ruulTextStyle(RuulTypography.caption)
                            .foregroundStyle(Color.ruulAccentPrimary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.ruulAccentSubtle, in: Capsule())
                    }
                    Spacer()
                }
                Text(event.title)
                    .ruulTextStyle(RuulTypography.title)
                    .foregroundStyle(Color.ruulTextPrimary)
                Label(event.startsAt.ruulRelativeDescription, systemImage: "clock")
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextSecondary)
                if let location = event.locationName {
                    Label(location, systemImage: "mappin")
                        .ruulTextStyle(RuulTypography.body)
                        .foregroundStyle(Color.ruulTextSecondary)
                }
                if let myStatus = coordinator.myRSVPs[event.id]?.status, myStatus != .pending {
                    Divider().padding(.vertical, RuulSpacing.s1)
                    HStack(spacing: RuulSpacing.s2) {
                        Image(systemName: rsvpIcon(myStatus))
                            .foregroundStyle(rsvpColor(myStatus))
                        Text(myStatus.displayName)
                            .ruulTextStyle(RuulTypography.callout)
                            .foregroundStyle(Color.ruulTextPrimary)
                    }
                }
            }
            .padding(RuulSpacing.s5)
            .background(Color.ruulBackgroundElevated)
            .clipShape(
                UnevenRoundedRectangle(
                    bottomLeadingRadius: RuulRadius.lg,
                    bottomTrailingRadius: RuulRadius.lg
                )
            )
        }
        .ruulElevation(.md)
    }

    private func cover(for event: Event) -> some View {
        let cover = RuulCoverCatalog.cover(named: event.coverImageName)
        return RuulCoverView(cover)
    }

    @ViewBuilder
    private var upcomingListSection: some View {
        let rest = Array(coordinator.upcomingEvents.dropFirst())
        if !rest.isEmpty {
            VStack(alignment: .leading, spacing: RuulSpacing.s3) {
                Text("Próximos")
                    .ruulTextStyle(RuulTypography.footnote)
                    .foregroundStyle(Color.ruulTextSecondary)
                ForEach(rest) { event in
                    EventCard(
                        event: event,
                        myStatus: coordinator.myRSVPs[event.id]?.status,
                        isHostedByMe: event.hostId == userId
                    ) {
                        onOpenEvent(event)
                    }
                }
            }
        }
    }

    private var pastEventsLink: some View {
        Button(action: onOpenPastEvents) {
            HStack {
                Text("Ver historial")
                    .ruulTextStyle(RuulTypography.callout)
                    .foregroundStyle(Color.ruulAccentPrimary)
                Image(systemName: "arrow.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.ruulAccentPrimary)
            }
        }
        .buttonStyle(.plain)
    }

    private var fab: some View {
        Button(action: onCreateEvent) {
            Image(systemName: "plus")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(Color.ruulTextInverse)
                .frame(width: 60, height: 60)
                .background(Color.ruulAccentPrimary, in: Circle())
                .ruulElevation(.lg)
        }
        .buttonStyle(.ruulPress)
        .padding(RuulSpacing.s5)
    }

    // MARK: - Helpers

    private func rsvpIcon(_ status: RSVPStatus) -> String {
        switch status {
        case .going:    return "checkmark.circle.fill"
        case .maybe:    return "questionmark.circle.fill"
        case .declined: return "xmark.circle.fill"
        case .pending:  return "clock"
        }
    }

    private func rsvpColor(_ status: RSVPStatus) -> Color {
        switch status {
        case .going:    return .ruulSemanticSuccess
        case .maybe:    return .ruulSemanticWarning
        case .declined: return .ruulSemanticError
        case .pending:  return .ruulTextTertiary
        }
    }
}
