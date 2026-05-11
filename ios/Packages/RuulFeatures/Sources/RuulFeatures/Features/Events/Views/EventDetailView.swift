import SwiftUI
import MapKit
import RuulUI
import RuulCore

/// Full-bleed event detail. Cover scrolls under a transparent nav that
/// fades to a glass bar as the user scrolls past the cover. Title sits in
/// the safe area below, magazine-style. Sticky CTA at the bottom.
public struct EventDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var coordinator: EventDetailCoordinator
    public let memberLookup: (UUID) -> (name: String, avatarURL: URL?)
    /// Optional rich lookup. Cuando set + un attendee row tap dispara, se
    /// resuelve el `MemberWithProfile` correspondiente y se presenta el
    /// `MemberDetailView` en sheet. Si nil, los taps son no-op (back-compat
    /// con call sites legacy / previews que solo tienen el lookup display).
    public var memberWithProfileLookup: ((UUID) -> MemberWithProfile?)? = nil
    public var onScannerOpen: () -> Void
    public var calendarService: CalendarExportService?
    public var onEdit: () -> Void = {}
    /// Async governance check. EventDetailView calls it once in `.task`
    /// and stores the result in `canIssueManualFine` @State. Fail-closed:
    /// any throw / non-allowed decision keeps the action card hidden.
    public let computeCanIssueManualFine: () async -> Bool
    /// Factory invoked when the sheet opens. Captures fineRepo + groupsRepo
    /// + groupId/eventId so the sheet's coordinator gets fresh state per open.
    public let makeAddManualFineCoordinator: () -> AddManualFineCoordinator
    /// Current user id, needed by the sheet to filter members.
    public let currentUserId: UUID
    /// Optional explicit close handler. Called by the X button BEFORE
    /// `dismiss()`. Lets the parent set `detailRoute = nil` directly so the
    /// dismissal doesn't rely on `@Environment(\.dismiss)` propagating through
    /// `AnyView` + `fullScreenCover` + nested sheets, which has been observed
    /// to no-op when a sheet binding was momentarily true earlier in the
    /// session (the dismiss target resolves to the sheet, not the cover).
    public var onClose: (() -> Void)? = nil

    public init(coordinator: EventDetailCoordinator, memberLookup: @escaping (UUID) -> (name: String, avatarURL: URL?), memberWithProfileLookup: ((UUID) -> MemberWithProfile?)? = nil, onScannerOpen: @escaping () -> Void, calendarService: CalendarExportService?, onEdit: @escaping () -> Void = {}, computeCanIssueManualFine: @escaping () async -> Bool, makeAddManualFineCoordinator: @escaping () -> AddManualFineCoordinator, currentUserId: UUID, onClose: (() -> Void)? = nil) {
        self.coordinator = coordinator
        self.memberLookup = memberLookup
        self.memberWithProfileLookup = memberWithProfileLookup
        self.onScannerOpen = onScannerOpen
        self.calendarService = calendarService
        self.onEdit = onEdit
        self.computeCanIssueManualFine = computeCanIssueManualFine
        self.makeAddManualFineCoordinator = makeAddManualFineCoordinator
        self.currentUserId = currentUserId
        self.onClose = onClose
    }

    @State private var qrSheetPresented = false
    @State private var shareSheetPresented = false
    @State private var cancelEventSheet = false
    @State private var cancelAttendanceSheet = false
    @State private var remindSheet = false
    @State private var closeSheet = false
    @State private var addManualFinePresented = false
    @State private var canIssueManualFine: Bool = false
    @State private var scrollOffset: CGFloat = 0
    @State private var pendingPlusOnes: Int = 0
    /// Sheet route — set cuando un attendee row es tapped y el rich lookup
    /// resuelve un MemberWithProfile. Sheet binding usa `.sheet(item:)` para
    /// que el push desde dentro del fullScreenCover funcione sin requerir
    /// NavigationStack outer.
    @State private var attendeeMemberRoute: MemberWithProfile?
    @State private var eventRuleSheetPresented = false
    @State private var eventLedgerSheetPresented = false

    private let coverHeight: CGFloat = 380

    public var body: some View {
        ZStack(alignment: .top) {
            Color.ruulBackground.ignoresSafeArea()

            if coordinator.hasInitialLoadError, let error = coordinator.error {
                ErrorStateView(error: error, retry: { Task { await coordinator.refresh() } })
                    .padding(.horizontal, RuulSpacing.lg)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        parallaxHero
                        contentSection
                    }
                }
                .scrollIndicators(.hidden)
                .background(scrollOffsetReader)

                // Sticky bottom CTA bar (cancel link or close button when host).
                stickyBottomBar
            }

            // Top nav — transparent over the cover, glass after scrolling.
            // Always visible (even on initial-load error) so the user can dismiss.
            topNav
        }
        .animation(.linear(duration: RuulDuration.fast), value: coordinator.hasInitialLoadError)
        .toolbar(.hidden, for: .navigationBar)
        .ignoresSafeArea(edges: .top)
        .task { await coordinator.refresh() }
        .task { await coordinator.startRealtime() }
        .task {
            canIssueManualFine = await computeCanIssueManualFine()
        }
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
        .ruulSheet(isPresented: $addManualFinePresented) {
            // Fresh coordinator per open: makeAddManualFineCoordinator() runs
            // each time the binding flips false→true. Deliberate — avoids
            // leaking partially-filled form state from cancelled sessions.
            AddManualFineSheet(
                isPresented: $addManualFinePresented,
                coordinator: makeAddManualFineCoordinator(),
                currentUserId: currentUserId
            )
        }
        .sheet(item: $attendeeMemberRoute) { mwp in
            NavigationStack {
                MemberDetailView(
                    memberWithProfile: mwp,
                    group: coordinator.group,
                    isCurrentUser: mwp.member.userId == currentUserId
                )
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $eventRuleSheetPresented) {
            EventCapabilityPlaceholderSheet(
                icon: "list.bullet.clipboard.fill",
                title: "Reglas del evento",
                summary: "Pronto podrás agregar reglas que sólo apliquen a esta cena: late fee custom, no-show fine override, etc.",
                comingFromPhase: "Phase 4 (in-event rule creation)"
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $eventLedgerSheetPresented) {
            EventCapabilityPlaceholderSheet(
                icon: "arrow.left.arrow.right",
                title: "Movimientos del evento",
                summary: "Pronto podrás registrar gastos, IOUs y aportaciones tied to this event. El sistema calculará automáticamente quién debe a quién al cerrar el evento.",
                comingFromPhase: "Phase 3 (Money capability)"
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
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
        VStack(alignment: .leading, spacing: RuulSpacing.xxl) {
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
            .padding(.horizontal, RuulSpacing.lg)
            attendeesSection
            checkInSectionView
            if coordinator.viewerRole == .host {
                EventHostActionsSection(
                    event: coordinator.event,
                    group: coordinator.group,
                    totalConfirmed: coordinator.rsvps.filter { $0.status == .going }.count,
                    totalMembers: coordinator.rsvps.count,
                    onSendReminders: { remindSheet = true },
                    onEdit: onEdit,
                    onOpenScanner: onScannerOpen,
                    onCancelEvent: { cancelEventSheet = true },
                    onCloseEvent: { closeSheet = true },
                    onToggleAutoGenerate: { enabled in
                        Task { await coordinator.toggleAutoGenerate(enabled) }
                    },
                    canIssueManualFine: canIssueManualFine,
                    onIssueManualFine: { addManualFinePresented = true }
                )
                .padding(.horizontal, RuulSpacing.lg)
            }
            descriptionSection
            eventCapabilitiesSection
        }
        .padding(.top, RuulSpacing.xl)
        .padding(.bottom, RuulSpacing.s12)
        .background(
            UnevenRoundedRectangle(
                topLeadingRadius: RuulRadius.extraLarge,
                topTrailingRadius: RuulRadius.extraLarge,
                style: .continuous
            )
            .fill(Color.ruulBackground)
            .offset(y: -RuulRadius.extraLarge)
        )
    }

    // MARK: - Title block (sits in canvas right below cover)

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.sm) {
            HStack(spacing: RuulSpacing.xs) {
                if coordinator.event.status == .inProgress {
                    livePill
                }
                if coordinator.event.status == .cancelled {
                    statusPill("Cancelado", icon: "xmark.circle.fill", tint: .ruulNegative)
                }
                if coordinator.event.status == .closed {
                    statusPill("Cerrado", icon: "checkmark.circle.fill", tint: .ruulTextSecondary)
                }
                if coordinator.event.isRecurringGenerated {
                    statusPill("Recurrente", icon: "arrow.triangle.2.circlepath", tint: .ruulAccent)
                }
            }

            countdownLine

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
                EventLocationCard(
                    locationName: location,
                    coordinate: locationCoordinate,
                    onOpenMaps: openMaps
                )
            }
        }
        .padding(.horizontal, RuulSpacing.lg)
    }

    /// Apple Invites signature: prominent countdown ("EMPIEZA EN 2 DÍAS") shown
    /// for upcoming events <7 days out. Hidden once the event starts or for
    /// long-horizon dates (would feel like noise).
    @ViewBuilder
    private var countdownLine: some View {
        if let countdown = countdownText {
            HStack(spacing: RuulSpacing.xs) {
                Image(systemName: "clock.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.ruulWarning)
                    .accessibilityHidden(true)
                Text(countdown)
                    .ruulTextStyle(RuulTypography.sectionLabelLg)
                    .foregroundStyle(Color.ruulTextPrimary)
            }
        }
    }

    private var countdownText: String? {
        guard coordinator.event.status == .upcoming else { return nil }
        let interval = coordinator.event.startsAt.timeIntervalSince(.now)
        guard interval > 0 else { return nil }
        let days = Int(interval / 86_400)
        let hours = Int(interval / 3600)
        let minutes = Int(interval / 60)
        if interval < 3600 {
            return "EMPIEZA EN \(max(1, minutes)) MIN"
        }
        if interval < 86_400 {
            return "EMPIEZA EN \(hours) H"
        }
        if days < 7 {
            return days == 1 ? "EMPIEZA MAÑANA" : "EMPIEZA EN \(days) DÍAS"
        }
        return nil
    }

    private var locationCoordinate: CLLocationCoordinate2D? {
        guard let lat = coordinator.event.locationLat,
              let lng = coordinator.event.locationLng else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lng)
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
                        HStack(spacing: RuulSpacing.xs) {
                            Circle()
                                .fill(Color.ruulNegative)
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
            memberLookup: memberLookup,
            onSelectAttendee: memberWithProfileLookup.map { lookup in
                { userId in
                    if let mwp = lookup(userId) {
                        attendeeMemberRoute = mwp
                    }
                }
            }
        )
        .padding(.horizontal, RuulSpacing.lg)
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
        .padding(.horizontal, RuulSpacing.lg)
    }

    @ViewBuilder
    private var descriptionSection: some View {
        if let description = coordinator.event.description, !description.isEmpty {
            VStack(alignment: .leading, spacing: RuulSpacing.xs) {
                Text("DESCRIPCIÓN")
                    .ruulTextStyle(RuulTypography.sectionLabel)
                    .foregroundStyle(Color.ruulTextTertiary)
                Text(description)
                    .ruulTextStyle(RuulTypography.bodyLarge)
                    .foregroundStyle(Color.ruulTextPrimary)
            }
            .padding(.horizontal, RuulSpacing.lg)
        }
    }

    // MARK: - Event-scoped capability surfaces (Reglas + Movimientos)
    //
    // Two cards inside the event detail: lets the user add rules
    // scoped to THIS event, or record IOU-style transactions tied to it.
    // Both surface "Agregar" CTAs that open placeholder sheets — actual
    // creation flows land in Phase 3 (Money) and Phase 4 (in-event rule
    // creation) but the UX surface is here so the user sees the platform.

    @ViewBuilder
    private var eventCapabilitiesSection: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.lg) {
            eventRulesCard
            eventLedgerCard
        }
        .padding(.horizontal, RuulSpacing.lg)
    }

    private var eventRulesCard: some View {
        capabilityCard(
            icon: "list.bullet.clipboard.fill",
            title: "Reglas de este evento",
            summary: "Agrega reglas que sólo apliquen a este evento (override del grupo).",
            ctaLabel: "Agregar regla",
            onTap: { eventRuleSheetPresented = true }
        )
    }

    private var eventLedgerCard: some View {
        capabilityCard(
            icon: "arrow.left.arrow.right",
            title: "Movimientos",
            summary: "Registra gastos, IOUs y aportaciones de este evento.",
            ctaLabel: "Registrar movimiento",
            onTap: { eventLedgerSheetPresented = true }
        )
    }

    private func capabilityCard(
        icon: String,
        title: String,
        summary: String,
        ctaLabel: String,
        onTap: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: RuulSpacing.sm) {
            HStack(spacing: RuulSpacing.sm) {
                ZStack {
                    Circle()
                        .fill(Color.ruulAccent.opacity(0.15))
                        .frame(width: 36, height: 36)
                    Image(systemName: icon)
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(Color.ruulAccent)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .ruulTextStyle(RuulTypography.headline)
                        .foregroundStyle(Color.ruulTextPrimary)
                    Text(summary)
                        .ruulTextStyle(RuulTypography.caption)
                        .foregroundStyle(Color.ruulTextSecondary)
                }
            }
            Button(action: onTap) {
                HStack {
                    Image(systemName: "plus")
                    Text(ctaLabel)
                }
                .ruulTextStyle(RuulTypography.body)
                .foregroundStyle(Color.ruulAccent)
                .padding(.vertical, RuulSpacing.xs)
                .padding(.horizontal, RuulSpacing.sm)
                .background(Color.ruulAccent.opacity(0.08), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(RuulSpacing.lg)
        .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.large))
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.large)
                .stroke(Color.ruulSeparator, lineWidth: 0.5)
        )
    }

    // MARK: - Top nav (transparent → glass on scroll)

    private var topNav: some View {
        HStack(spacing: RuulSpacing.xs) {
            navCircleButton(icon: "xmark", label: "Cerrar") {
                if let onClose {
                    onClose()
                } else {
                    dismiss()
                }
            }
            Spacer()
            navCircleButton(icon: "square.and.arrow.up", label: "Compartir") {
                shareSheetPresented = true
            }
            if coordinator.viewerRole == .host {
                navCircleButton(icon: "pencil", label: "Editar") { onEdit() }
            }
        }
        .padding(.horizontal, RuulSpacing.md)
        .padding(.top, statusBarTopPadding)
    }

    private func navCircleButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                // Tap target ≥44pt (HIG). Apple's `glassEffect(_:in:)` with
                // `interactive: true` was observed to swallow taps inside the
                // circle on iOS 26.x — keeping the visual circle at 36pt but
                // the actual hit area at 44pt with `contentShape` ensures the
                // button receives the touch before the glass modifier.
                Circle()
                    .fill(.clear)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Color.ruulTextPrimary)
                    .frame(width: 36, height: 36)
                    // DS v3 §13: pill nav chrome — Liquid Glass real, sin
                    // `interactive` para no interferir con el hit test del
                    // Button (la deformación al press la da `.ruulPress`).
                    .ruulGlass(Circle(), material: .regular)
                    .ruulElevation(.sm)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
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
                        .padding(.vertical, RuulSpacing.md)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                // DS v3 §13: bottom action chrome — Liquid Glass real.
                .ruulGlass(Rectangle(), material: .regular)
            }
        }
        if coordinator.viewerRole == .host && isCloseable {
            VStack {
                Spacer()
                RuulButton("Cerrar evento", style: .primary, size: .large, fillsWidth: true) {
                    closeSheet = true
                }
                .padding(.horizontal, RuulSpacing.lg)
                .padding(.vertical, RuulSpacing.sm)
                // DS v3 §13: sticky CTA chrome — Liquid Glass real.
                .ruulGlass(Rectangle(), material: .regular)
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
        HStack(spacing: RuulSpacing.xs) {
            Circle()
                .fill(tint)
                .frame(width: 8, height: 8)
            Text(text)
                .ruulTextStyle(RuulTypography.sectionLabel)
                .foregroundStyle(Color.ruulTextPrimary)
        }
    }

    private var livePill: some View {
        HStack(spacing: RuulSpacing.xs) {
            Circle()
                .fill(Color.ruulNegative)
                .frame(width: 8, height: 8)
            Text("EN VIVO")
                .ruulTextStyle(RuulTypography.sectionLabel)
                .foregroundStyle(Color.ruulTextPrimary)
        }
    }
}
