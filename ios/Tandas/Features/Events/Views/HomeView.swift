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
                VStack(alignment: .leading, spacing: RuulSpacing.s8) {
                    header
                    nextEventSection
                    upcomingListSection
                    pastEventsLink
                }
                .padding(.horizontal, RuulSpacing.s5)
                .padding(.top, RuulSpacing.s2)
                .padding(.bottom, RuulSpacing.s12)
            }
            .scrollIndicators(.hidden)
            .refreshable { await coordinator.refresh(force: true) }
            .overlay(alignment: .bottomTrailing) { fab }
        }
        .task { await coordinator.refresh() }
    }

    // MARK: - Header (magazine-style: huge greeting + group context line)

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(greeting)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.ruulTextSecondary)
                .textCase(.uppercase)
                .tracking(0.6)
            Text(coordinator.group.name)
                .ruulTextStyle(RuulTypography.displayMedium)
                .foregroundStyle(Color.ruulTextPrimary)
                .lineLimit(2)
        }
        .padding(.top, RuulSpacing.s4)
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: .now)
        let prefix: String
        switch hour {
        case 5..<12:  prefix = "BUENOS DÍAS"
        case 12..<19: prefix = "BUENAS TARDES"
        default:      prefix = "BUENAS NOCHES"
        }
        return prefix
    }

    // MARK: - Next event hero (full-bleed cover, dramatic title, social proof)

    @ViewBuilder
    private var nextEventSection: some View {
        if coordinator.isLoading && coordinator.nextEvent == nil {
            HStack { Spacer(); ProgressView().tint(Color.ruulAccentPrimary); Spacer() }
                .frame(height: 360)
        } else if let next = coordinator.nextEvent {
            VStack(alignment: .leading, spacing: RuulSpacing.s2) {
                Text("PRÓXIMO")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.ruulAccentPrimary)
                    .tracking(0.8)
                heroNextEventCard(next)
            }
        } else {
            emptyHero
        }
    }

    private func heroNextEventCard(_ event: Event) -> some View {
        Button { onOpenEvent(event) } label: {
            VStack(spacing: 0) {
                heroCover(for: event)
                heroBody(for: event)
            }
            .background(Color.ruulBackgroundElevated)
            .clipShape(RoundedRectangle(cornerRadius: RuulRadius.xl, style: .continuous))
            .ruulElevation(.lg)
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.xl, style: .continuous)
                    .stroke(Color.ruulBorderSubtle, lineWidth: 0.5)
            )
        }
        .buttonStyle(.ruulPress)
    }

    private func heroCover(for event: Event) -> some View {
        ZStack(alignment: .topLeading) {
            cover(for: event)
                .aspectRatio(4/3, contentMode: .fill)
                .frame(maxWidth: .infinity)
                .clipped()

            LinearGradient(
                colors: [Color.black.opacity(0.40), .clear, .clear, Color.black.opacity(0.30)],
                startPoint: .top, endPoint: .bottom
            )

            HStack(spacing: RuulSpacing.s2) {
                if event.hostId == userId {
                    badge(icon: "star.fill", text: "Hosteas tú", tint: .ruulAccentPrimary)
                }
                if event.isRecurringGenerated {
                    badge(icon: "arrow.triangle.2.circlepath", text: "Recurrente", tint: Color.black.opacity(0.55))
                }
            }
            .padding(RuulSpacing.s4)
        }
    }

    private func heroBody(for event: Event) -> some View {
        VStack(alignment: .leading, spacing: RuulSpacing.s4) {
            VStack(alignment: .leading, spacing: 8) {
                Text(heroDateLine(event))
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.ruulAccentPrimary)
                    .textCase(.uppercase)
                    .tracking(0.6)

                Text(event.title)
                    .ruulTextStyle(RuulTypography.displayMedium)
                    .foregroundStyle(Color.ruulTextPrimary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let location = event.locationName, !location.isEmpty {
                Label(location, systemImage: "mappin.and.ellipse")
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextSecondary)
            }

            // RSVP CTA — primary call to action when pending; status pill if responded.
            if let myRSVP = coordinator.myRSVPs[event.id] {
                if myRSVP.status == .pending {
                    primaryCTAButton(for: event)
                } else {
                    rsvpStatusRow(for: myRSVP.status)
                }
            } else {
                primaryCTAButton(for: event)
            }
        }
        .padding(RuulSpacing.s6)
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

    private func primaryCTAButton(for event: Event) -> some View {
        RuulButton("Ver evento", style: .primary, size: .large, fillsWidth: true) {
            onOpenEvent(event)
        }
        .padding(.top, RuulSpacing.s2)
    }

    private func rsvpStatusRow(for status: RSVPStatus) -> some View {
        let (icon, color, text): (String, Color, String) = {
            switch status {
            case .going:    return ("checkmark.circle.fill", .ruulSemanticSuccess, "Vas")
            case .maybe:    return ("questionmark.circle.fill", .ruulSemanticWarning, "Estás considerando")
            case .declined: return ("xmark.circle.fill", .ruulSemanticError, "No vas")
            case .pending:  return ("clock", .ruulTextTertiary, "Pendiente")
            }
        }()
        return HStack(spacing: RuulSpacing.s2) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(color)
            Text(text)
                .ruulTextStyle(RuulTypography.headline)
                .foregroundStyle(Color.ruulTextPrimary)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.ruulTextTertiary)
        }
        .padding(.vertical, RuulSpacing.s3)
        .padding(.horizontal, RuulSpacing.s4)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous))
    }

    @ViewBuilder
    private var emptyHero: some View {
        VStack(spacing: RuulSpacing.s5) {
            ZStack {
                Circle()
                    .fill(Color.ruulAccentSubtle)
                    .frame(width: 80, height: 80)
                Image(systemName: "calendar.badge.plus")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(Color.ruulAccentPrimary)
            }
            VStack(spacing: RuulSpacing.s2) {
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
        .padding(RuulSpacing.s7)
        .background(Color.ruulBackgroundElevated, in: RoundedRectangle(cornerRadius: RuulRadius.xl, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.xl, style: .continuous)
                .stroke(Color.ruulBorderSubtle, lineWidth: 0.5)
        )
    }

    // MARK: - Upcoming list

    @ViewBuilder
    private var upcomingListSection: some View {
        let rest = Array(coordinator.upcomingEvents.dropFirst())
        if !rest.isEmpty {
            VStack(alignment: .leading, spacing: RuulSpacing.s3) {
                HStack {
                    Text("Próximos")
                        .ruulTextStyle(RuulTypography.titleLarge)
                        .foregroundStyle(Color.ruulTextPrimary)
                    Spacer()
                    Text("\(rest.count)")
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.ruulTextTertiary)
                }
                .padding(.bottom, RuulSpacing.s2)
                VStack(spacing: RuulSpacing.s4) {
                    ForEach(rest) { event in
                        EventCard(
                            event: event,
                            myStatus: coordinator.myRSVPs[event.id]?.status,
                            isHostedByMe: event.hostId == userId,
                            attendeeAvatars: [],
                            confirmedCount: 0
                        ) {
                            onOpenEvent(event)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Past events link

    @ViewBuilder
    private var pastEventsLink: some View {
        if !coordinator.upcomingEvents.isEmpty {
            Button(action: onOpenPastEvents) {
                HStack(spacing: RuulSpacing.s2) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Ver historial")
                        .ruulTextStyle(RuulTypography.callout)
                    Spacer()
                    Image(systemName: "arrow.right")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(Color.ruulAccentPrimary)
                .padding(.vertical, RuulSpacing.s4)
                .padding(.horizontal, RuulSpacing.s5)
                .background(Color.ruulAccentSubtle, in: RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - FAB

    private var fab: some View {
        Button(action: onCreateEvent) {
            Image(systemName: "plus")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Color.ruulTextInverse)
                .frame(width: 60, height: 60)
                .background(
                    LinearGradient(
                        colors: [.ruulAccentPrimary, .ruulAccentSecondary],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ),
                    in: Circle()
                )
                .ruulElevation(.lg)
        }
        .buttonStyle(.ruulPress)
        .padding(RuulSpacing.s5)
    }

    // MARK: - Cover helper

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

    // MARK: - Generic badge (matches EventCard's style)

    private func badge(icon: String, text: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.3)
        }
        .foregroundStyle(Color.ruulTextInverse)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(tint, in: Capsule())
    }
}
