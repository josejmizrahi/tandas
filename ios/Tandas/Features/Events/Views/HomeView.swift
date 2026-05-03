import SwiftUI

struct HomeView: View {
    @Bindable var coordinator: HomeCoordinator
    let userId: UUID
    var onCreateEvent: () -> Void
    var onOpenEvent: (Event) -> Void
    var onOpenPastEvents: () -> Void

    @State private var showSettings: Bool = false

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
                Text(coordinator.group.name)
                    .ruulTextStyle(RuulTypography.displayMedium)
                    .foregroundStyle(Color.ruulTextPrimary)
                    .lineLimit(2)
            }
            Spacer()
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Color.ruulTextPrimary)
                    .frame(width: 40, height: 40)
                    .background(Color.ruulBackgroundElevated, in: Circle())
                    .overlay(Circle().stroke(Color.ruulBorderSubtle, lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Ajustes")
        }
        .padding(.top, RuulSpacing.s4)
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
        if coordinator.isLoading && coordinator.nextEvent == nil {
            HStack { Spacer(); ProgressView().tint(Color.ruulAccentPrimary); Spacer() }
                .frame(height: 360)
        } else if let next = coordinator.nextEvent {
            VStack(alignment: .leading, spacing: RuulSpacing.s2) {
                Text("PRÓXIMO")
                    .ruulTextStyle(RuulTypography.sectionLabel)
                    .foregroundStyle(Color.ruulTextTertiary)
                heroTile(next)
            }
        } else {
            emptyHero
        }
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
            .clipShape(RoundedRectangle(cornerRadius: RuulRadius.xl, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.xl, style: .continuous)
                    .stroke(Color.ruulBorderSubtle, lineWidth: 0.5)
            )
        }
        .buttonStyle(.ruulPress)
    }

    private func heroTopBadges(_ event: Event) -> some View {
        VStack {
            HStack(spacing: RuulSpacing.s2) {
                if event.hostId == userId {
                    overlayBadge(icon: "star.fill", text: "Hosteas tú", tint: Color.ruulImageBadge)
                }
                Spacer()
                if event.isRecurringGenerated {
                    overlayBadge(icon: "arrow.triangle.2.circlepath", text: "Recurrente", tint: Color.ruulImageBadge)
                }
            }
            .padding(RuulSpacing.s4)
            Spacer()
        }
    }

    private func heroBottomBlock(_ event: Event) -> some View {
        VStack(alignment: .leading, spacing: RuulSpacing.s4) {
            VStack(alignment: .leading, spacing: RuulSpacing.s2) {
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
        .padding(RuulSpacing.s5)
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
            }
            .foregroundStyle(Color.ruulOnImageInverse)
            .padding(RuulSpacing.s4)
            .background(Color.ruulOnImage, in: RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous))
        }
        .buttonStyle(.ruulPress)
        .padding(.top, RuulSpacing.s2)
    }

    private func rsvpStatusOverlay(for status: RSVPStatus) -> some View {
        let (dotColor, text): (Color, String) = {
            switch status {
            case .going:      return (.ruulSemanticSuccess, "Vas")
            case .maybe:      return (.ruulSemanticWarning, "Estás considerando")
            case .declined:   return (.ruulSemanticError,   "No vas")
            case .waitlisted: return (.ruulSemanticWarning, "En lista de espera")
            case .pending:    return (.ruulTextTertiary,    "Pendiente")
            }
        }()
        return HStack(spacing: RuulSpacing.s2) {
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
        }
        .padding(.vertical, RuulSpacing.s3)
        .padding(.horizontal, RuulSpacing.s4)
        .background(Color.ruulImagePill, in: RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous)
                .stroke(Color.ruulImagePillBorder, lineWidth: 0.5)
        )
        .padding(.top, RuulSpacing.s2)
    }

    // MARK: - Empty state

    private var emptyHero: some View {
        VStack(spacing: RuulSpacing.s5) {
            ZStack {
                Circle()
                    .fill(Color.ruulBackgroundElevated)
                    .frame(width: 80, height: 80)
                Image(systemName: "calendar.badge.plus")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(Color.ruulTextPrimary)
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

    // MARK: - Upcoming list — section header + tile cards.

    @ViewBuilder
    private var upcomingListSection: some View {
        let rest = Array(coordinator.upcomingEvents.dropFirst())
        if !rest.isEmpty {
            VStack(alignment: .leading, spacing: RuulSpacing.s4) {
                HStack(alignment: .firstTextBaseline) {
                    Text("PRÓXIMOS")
                        .ruulTextStyle(RuulTypography.sectionLabel)
                        .foregroundStyle(Color.ruulTextTertiary)
                    Spacer()
                    Text("\(rest.count)")
                        .ruulTextStyle(RuulTypography.statSmall)
                        .foregroundStyle(Color.ruulTextTertiary)
                }
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

    // MARK: - Past events link — Apple Sports style: subtle row, no chrome.

    @ViewBuilder
    private var pastEventsLink: some View {
        if !coordinator.upcomingEvents.isEmpty {
            Button(action: onOpenPastEvents) {
                HStack(spacing: RuulSpacing.s2) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Ver historial")
                        .ruulTextStyle(RuulTypography.headline)
                    Spacer()
                    Image(systemName: "arrow.right")
                        .font(.system(size: 12, weight: .bold))
                }
                .foregroundStyle(Color.ruulTextSecondary)
                .padding(.vertical, RuulSpacing.s4)
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
        }
        .buttonStyle(.ruulPress)
        .padding(RuulSpacing.s5)
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
        HStack(spacing: RuulSpacing.s1) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
            Text(text)
                .ruulTextStyle(RuulTypography.sectionLabel)
        }
        .foregroundStyle(Color.ruulOnImage)
        .padding(.horizontal, RuulSpacing.s2)
        .padding(.vertical, RuulSpacing.s1 + 1)
        .background(tint, in: Capsule())
    }
}
