import SwiftUI
import MapKit

/// Full-bleed event detail. Cover scrolls under a transparent nav that
/// fades to a glass bar as the user scrolls past the cover. Title sits in
/// the safe area below, magazine-style. Sticky CTA at the bottom.
struct EventDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var coordinator: EventDetailCoordinator
    let memberLookup: (UUID) -> (name: String, avatarURL: URL?)
    var onScannerOpen: () -> Void

    @State private var qrSheetPresented = false
    @State private var shareSheetPresented = false
    @State private var cancelEventSheet = false
    @State private var cancelAttendanceSheet = false
    @State private var remindSheet = false
    @State private var closeSheet = false
    @State private var scrollOffset: CGFloat = 0
    @State private var pendingPlusOnes: Int = 0
    var calendarService: CalendarExportService?

    private let coverHeight: CGFloat = 380

    var body: some View {
        ZStack(alignment: .top) {
            Color.ruulBackgroundCanvas.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    parallaxHero
                    contentSection
                }
            }
            .scrollIndicators(.hidden)
            .background(scrollOffsetReader)

            // Top nav — transparent over the cover, glass after scrolling.
            topNav

            // Sticky bottom CTA bar (cancel link or close button when host).
            stickyBottomBar
        }
        .toolbar(.hidden, for: .navigationBar)
        .ignoresSafeArea(edges: .top)
        .task { await coordinator.refresh() }
        .task { await coordinator.startRealtime() }
        .onDisappear { coordinator.stopRealtime() }
        .onChange(of: coordinator.myRSVP?.plusOnes) { _, newValue in
            // Sync the local stepper state with whatever the server returned
            // (e.g. a re-confirmation that downgraded plusOnes due to capacity).
            pendingPlusOnes = newValue ?? 0
        }
        .ruulSheet(isPresented: $shareSheetPresented) {
            ShareEventSheet(
                isPresented: $shareSheetPresented,
                event: coordinator.event,
                groupVocabulary: coordinator.group.eventVocabulary,
                hostName: nil,
                onAddToCalendar: addToCalendar
            )
        }
        .ruulSheet(isPresented: $qrSheetPresented) {
            MemberQRSheet(
                isPresented: $qrSheetPresented,
                eventId: coordinator.event.id,
                memberId: coordinator.myRSVP?.userId ?? UUID(),
                eventTitle: coordinator.event.title
            )
        }
        .ruulSheet(isPresented: $cancelEventSheet) {
            CancelEventSheet(isPresented: $cancelEventSheet) { reason in
                Task { await coordinator.cancelEvent(reason: reason) }
            }
        }
        .ruulSheet(isPresented: $cancelAttendanceSheet) {
            CancelAttendanceSheet(
                isPresented: $cancelAttendanceSheet,
                isAfterDeadline: isAfterRSVPDeadline
            ) { reason in
                Task { await coordinator.setRSVP(.declined, reason: reason) }
            }
        }
        .ruulSheet(isPresented: $remindSheet) {
            RemindAttendeesSheet(
                isPresented: $remindSheet,
                pendingCount: coordinator.rsvps.filter { $0.status == .pending }.count,
                eventTitle: coordinator.event.title,
                vocabulary: coordinator.group.eventVocabulary
            ) {
                Task { _ = await coordinator.sendHostReminders() }
            }
        }
        .ruulSheet(isPresented: $closeSheet) {
            CloseEventSheet(
                isPresented: $closeSheet,
                vocabulary: coordinator.group.eventVocabulary
            ) {
                Task { await coordinator.closeEvent(autoGenerateEnabled: false) }
            }
        }
    }

    // MARK: - Parallax cover

    private var parallaxHero: some View {
        GeometryReader { geo in
            let offset = geo.frame(in: .global).minY
            let stretch = max(0, offset)
            let parallax = max(0, -offset / 2)
            ZStack(alignment: .bottom) {
                cover
                    .frame(width: geo.size.width, height: coverHeight + stretch)
                    .clipped()
                    .offset(y: -stretch + parallax)

                // Bottom gradient ensures status pills + title legibility on
                // bright covers, regardless of theme.
                LinearGradient(
                    colors: [.clear, Color.ruulImageBadge],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 180)
                .offset(y: -stretch + parallax)
            }
        }
        .frame(height: coverHeight)
    }

    @ViewBuilder
    private var cover: some View {
        if let url = coordinator.event.coverImageURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img): img.resizable().scaledToFill()
                default:                fallbackCover
                }
            }
        } else {
            fallbackCover
        }
    }

    private var fallbackCover: some View {
        let cover = RuulCoverCatalog.cover(named: coordinator.event.coverImageName)
        return RuulCoverView(cover)
    }

    // MARK: - Content

    private var contentSection: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.s7) {
            titleBlock
            EventRSVPStateView(
                status: coordinator.myRSVP?.status ?? .pending,
                event: coordinator.event,
                walletAvailable: coordinator.walletService.isAvailable,
                isAtCapacity: isAtCapacity,
                plusOnes: $pendingPlusOnes,
                onChange: { newStatus in
                    Task { await coordinator.setRSVP(newStatus, plusOnes: pendingPlusOnes, reason: nil) }
                },
                onAddToWallet: {
                    Task { _ = await coordinator.generateWalletPass() }
                },
                onShowQR: { qrSheetPresented = true }
            )
            .padding(.horizontal, RuulSpacing.s5)
            attendeesSection
            checkInSectionView
            if coordinator.viewerRole == .host {
                EventHostActionsSection(
                    event: coordinator.event,
                    group: coordinator.group,
                    totalConfirmed: coordinator.rsvps.filter { $0.status == .going }.count,
                    totalMembers: coordinator.rsvps.count,
                    onSendReminders: { remindSheet = true },
                    onEdit: { /* wired by parent in V1.x */ },
                    onOpenScanner: onScannerOpen,
                    onCancelEvent: { cancelEventSheet = true },
                    onCloseEvent: { closeSheet = true },
                    onToggleAutoGenerate: { enabled in
                        Task { await coordinator.toggleAutoGenerate(enabled) }
                    }
                )
                .padding(.horizontal, RuulSpacing.s5)
            }
            descriptionSection
        }
        .padding(.top, RuulSpacing.s6)
        .padding(.bottom, RuulSpacing.s12)
        .background(
            UnevenRoundedRectangle(
                topLeadingRadius: RuulRadius.xl,
                topTrailingRadius: RuulRadius.xl,
                style: .continuous
            )
            .fill(Color.ruulBackgroundCanvas)
            .offset(y: -RuulRadius.xl)
        )
    }

    // MARK: - Title block (sits in canvas right below cover)

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.s3) {
            HStack(spacing: RuulSpacing.s2) {
                if coordinator.event.status == .inProgress {
                    livePill
                }
                if coordinator.event.status == .cancelled {
                    statusPill("Cancelado", icon: "xmark.circle.fill", tint: .ruulSemanticError)
                }
                if coordinator.event.status == .closed {
                    statusPill("Cerrado", icon: "checkmark.circle.fill", tint: .ruulTextSecondary)
                }
                if coordinator.event.isRecurringGenerated {
                    statusPill("Recurrente", icon: "arrow.triangle.2.circlepath", tint: .ruulAccentPrimary)
                }
            }

            Text(dateLine)
                .ruulTextStyle(RuulTypography.sectionLabelLg)
                .foregroundStyle(Color.ruulTextPrimary)

            Text(coordinator.event.title)
                .ruulTextStyle(RuulTypography.displayLarge)
                .foregroundStyle(Color.ruulTextPrimary)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)

            capacityBar

            if let location = coordinator.event.locationName, !location.isEmpty {
                Button {
                    openMaps()
                } label: {
                    HStack(spacing: RuulSpacing.s2) {
                        Image(systemName: "mappin.and.ellipse")
                            .font(.system(size: 16, weight: .semibold))
                        Text(location)
                            .ruulTextStyle(RuulTypography.body)
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.ruulTextTertiary)
                    }
                    .foregroundStyle(Color.ruulTextSecondary)
                    .padding(RuulSpacing.s4)
                    .background(Color.ruulBackgroundRecessed, in: RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, RuulSpacing.s5)
    }

    private var dateLine: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(coordinator.event.startsAt) {
            return "HOY · \(coordinator.event.startsAt.ruulShortTime)"
        }
        if calendar.isDateInTomorrow(coordinator.event.startsAt) {
            return "MAÑANA · \(coordinator.event.startsAt.ruulShortTime)"
        }
        return "\(coordinator.event.startsAt.ruulShortDate.uppercased()) · \(coordinator.event.startsAt.ruulShortTime)"
    }

    // MARK: - Capacity bar (visible when event has capacity_max)

    @ViewBuilder
    private var capacityBar: some View {
        if let capacityMax = coordinator.event.capacityMax {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    HStack(spacing: 4) {
                        Text("\(seatsTaken)")
                            .ruulTextStyle(RuulTypography.statMedium)
                            .foregroundStyle(Color.ruulTextPrimary)
                        Text("DE \(capacityMax)")
                            .ruulTextStyle(RuulTypography.sectionLabel)
                            .foregroundStyle(Color.ruulTextTertiary)
                    }
                    Spacer()
                    if seatsTaken >= capacityMax {
                        HStack(spacing: RuulSpacing.s2) {
                            Circle()
                                .fill(Color.ruulSemanticError)
                                .frame(width: 8, height: 8)
                            Text("LLENO")
                                .ruulTextStyle(RuulTypography.sectionLabel)
                                .foregroundStyle(Color.ruulTextPrimary)
                        }
                    }
                }
                RuulProgressBar(
                    value: min(1.0, Double(seatsTaken) / Double(capacityMax))
                )
            }
        }
    }

    // MARK: - Sections

    private var attendeesSection: some View {
        AttendeesListSection(
            rsvps: coordinator.rsvps,
            memberLookup: memberLookup
        )
        .padding(.horizontal, RuulSpacing.s5)
    }

    private var checkInSectionView: some View {
        CheckInSection(
            event: coordinator.event,
            myRSVP: coordinator.myRSVP,
            viewerIsHost: coordinator.viewerRole == .host,
            confirmedRSVPs: coordinator.rsvps.filter { $0.status == .going },
            memberLookup: memberLookup,
            onSelfCheckIn: {
                Task { await coordinator.selfCheckIn(locationVerified: false) }
            },
            onShowQR: { qrSheetPresented = true },
            onHostMarkCheckIn: { memberId in
                Task { await coordinator.hostMarkCheckIn(memberId: memberId) }
            }
        )
        .padding(.horizontal, RuulSpacing.s5)
    }

    @ViewBuilder
    private var descriptionSection: some View {
        if let description = coordinator.event.description, !description.isEmpty {
            VStack(alignment: .leading, spacing: RuulSpacing.s2) {
                Text("DESCRIPCIÓN")
                    .ruulTextStyle(RuulTypography.sectionLabel)
                    .foregroundStyle(Color.ruulTextTertiary)
                Text(description)
                    .ruulTextStyle(RuulTypography.bodyLarge)
                    .foregroundStyle(Color.ruulTextPrimary)
            }
            .padding(.horizontal, RuulSpacing.s5)
        }
    }

    // MARK: - Top nav (transparent → glass on scroll)

    private var topNav: some View {
        HStack(spacing: RuulSpacing.s2) {
            navCircleButton(icon: "xmark", label: "Cerrar") { dismiss() }
            Spacer()
            navCircleButton(icon: "square.and.arrow.up", label: "Compartir") {
                shareSheetPresented = true
            }
            if coordinator.viewerRole == .host {
                navCircleButton(icon: "pencil", label: "Editar") { onEdit() }
            }
        }
        .padding(.horizontal, RuulSpacing.s4)
        .padding(.top, statusBarTopPadding)
    }

    private func navCircleButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Color.ruulTextPrimary)
                .frame(width: 36, height: 36)
                .background(.regularMaterial, in: Circle())
                .ruulElevation(.sm)
        }
        .buttonStyle(.ruulPress)
        .accessibilityLabel(label)
    }

    /// Add the event to the user's default calendar via CalendarExportService.
    /// Surface failures via the coordinator's error channel.
    private func addToCalendar() {
        guard let calendarService else { return }
        Task {
            do {
                _ = try await calendarService.addToCalendar(
                    coordinator.event,
                    vocabulary: coordinator.group.eventVocabulary
                )
            } catch {
                // Fail silently — the user can retry from the Share sheet.
            }
        }
    }

    private var statusBarTopPadding: CGFloat {
        // Approximate dynamic island / status bar inset.
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }?
            .safeAreaInsets.top ?? 50
    }

    // MARK: - Sticky bottom bar

    @ViewBuilder
    private var stickyBottomBar: some View {
        if coordinator.viewerRole == .guestRole, coordinator.myRSVP?.status == .going {
            VStack {
                Spacer()
                Button {
                    cancelAttendanceSheet = true
                } label: {
                    Text("No voy a poder ir")
                        .ruulTextStyle(RuulTypography.callout)
                        .foregroundStyle(Color.ruulTextSecondary)
                        .padding(.vertical, RuulSpacing.s4)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .background(.regularMaterial)
            }
        }
        if coordinator.viewerRole == .host && isCloseable {
            VStack {
                Spacer()
                RuulButton("Cerrar evento", style: .primary, size: .large, fillsWidth: true) {
                    closeSheet = true
                }
                .padding(.horizontal, RuulSpacing.s5)
                .padding(.vertical, RuulSpacing.s3)
                .background(.regularMaterial)
            }
        }
    }

    // MARK: - Helpers

    private var scrollOffsetReader: some View {
        GeometryReader { geo in
            Color.clear.preference(
                key: ScrollOffsetKey.self,
                value: geo.frame(in: .named("detail-scroll")).minY
            )
        }
        .onPreferenceChange(ScrollOffsetKey.self) { value in
            scrollOffset = value
        }
    }

    private struct ScrollOffsetKey: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = nextValue()
        }
    }

    /// Sum of going seats (1 + plus_ones) currently confirmed.
    private var seatsTaken: Int {
        coordinator.rsvps
            .filter { $0.status == .going }
            .reduce(0) { $0 + 1 + $1.plusOnes }
    }

    private var isAtCapacity: Bool {
        guard let max = coordinator.event.capacityMax else { return false }
        // Current user's existing seats don't count against capacity if
        // they're re-confirming (server handles the check the same way).
        let myExisting = coordinator.myRSVP?.status == .going
            ? (1 + (coordinator.myRSVP?.plusOnes ?? 0))
            : 0
        return (seatsTaken - myExisting + 1 + pendingPlusOnes) > max
    }

    private var isAfterRSVPDeadline: Bool {
        guard let deadline = coordinator.event.rsvpDeadline else { return false }
        return Date.now > deadline
    }

    private var isCloseable: Bool {
        guard coordinator.event.status == .upcoming || coordinator.event.status == .inProgress else { return false }
        return Date.now > coordinator.event.startsAt.addingTimeInterval(TimeInterval(coordinator.event.durationMinutes * 60))
    }

    private func openMaps() {
        guard let lat = coordinator.event.locationLat,
              let lng = coordinator.event.locationLng else {
            // Fall back to a search query when we have a location name but
            // no coords (e.g. user typed it but didn't pick from autocomplete).
            if let name = coordinator.event.locationName,
               let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
               let url = URL(string: "https://maps.apple.com/?q=\(encoded)") {
                UIApplication.shared.open(url)
            }
            return
        }
        // Prefer MKMapItem so Apple Maps opens in directions mode with the
        // event title as the destination name.
        let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lng)
        let placemark = MKPlacemark(coordinate: coordinate)
        let mapItem = MKMapItem(placemark: placemark)
        mapItem.name = coordinator.event.locationName ?? coordinator.event.title
        mapItem.openInMaps(launchOptions: [
            MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving
        ])
    }

    // MARK: - Pills (Apple Sports / Luma flat: dot + uppercase label, no tint bg)

    private func statusPill(_ text: String, icon: String, tint: Color) -> some View {
        HStack(spacing: RuulSpacing.s2) {
            Circle()
                .fill(tint)
                .frame(width: 8, height: 8)
            Text(text)
                .ruulTextStyle(RuulTypography.sectionLabel)
                .foregroundStyle(Color.ruulTextPrimary)
        }
    }

    private var livePill: some View {
        HStack(spacing: RuulSpacing.s2) {
            Circle()
                .fill(Color.ruulSemanticError)
                .frame(width: 8, height: 8)
            Text("EN VIVO")
                .ruulTextStyle(RuulTypography.sectionLabel)
                .foregroundStyle(Color.ruulTextPrimary)
        }
    }
}
