import SwiftUI

struct EventDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var coordinator: EventDetailCoordinator
    let memberLookup: (UUID) -> (name: String, avatarURL: URL?)
    var onScannerOpen: () -> Void

    @State private var qrSheetPresented = false
    @State private var cancelEventSheet = false
    @State private var cancelAttendanceSheet = false
    @State private var remindSheet = false
    @State private var closeSheet = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RuulSpacing.s5) {
                heroSection
                rsvpSection
                attendeesSection
                checkInSectionView
                if coordinator.viewerRole == .host {
                    EventHostActionsSection(
                        event: coordinator.event,
                        group: coordinator.group,
                        totalConfirmed: coordinator.rsvps.filter { $0.status == .going }.count,
                        totalMembers: coordinator.rsvps.count,
                        onSendReminders: { remindSheet = true },
                        onEdit: { /* present EditEventView — wired by parent */ },
                        onOpenScanner: onScannerOpen,
                        onCancelEvent: { cancelEventSheet = true },
                        onCloseEvent: { closeSheet = true },
                        onToggleAutoGenerate: { enabled in
                            Task { await coordinator.toggleAutoGenerate(enabled) }
                        }
                    )
                }
                if coordinator.viewerRole == .guestRole, coordinator.myRSVP?.status == .going {
                    cancelAttendanceLink
                }
            }
            .padding(.horizontal, RuulSpacing.s5)
            .padding(.bottom, RuulSpacing.s7)
        }
        .background(Color.ruulBackgroundCanvas)
        .toolbar(.hidden, for: .navigationBar)
        .overlay(alignment: .topTrailing) { dismissButton }
        .task { await coordinator.refresh() }
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
                Task {
                    await coordinator.closeEvent(
                        autoGenerateEnabled: false   // group flag fetched server-side
                    )
                }
            }
        }
    }

    // MARK: - Hero

    private var heroSection: some View {
        ZStack(alignment: .bottomLeading) {
            cover
                .frame(height: 260)
                .clipShape(RoundedRectangle(cornerRadius: RuulRadius.xl, style: .continuous))
            LinearGradient(
                colors: [Color.black.opacity(0), Color.black.opacity(0.55)],
                startPoint: .top,
                endPoint: .bottom
            )
            .clipShape(RoundedRectangle(cornerRadius: RuulRadius.xl, style: .continuous))
            VStack(alignment: .leading, spacing: RuulSpacing.s2) {
                if coordinator.event.status != .upcoming {
                    statusBadge
                }
                Text(coordinator.event.title)
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(Color.white)
                    .lineLimit(2)
                Label(coordinator.event.startsAt.ruulFullDateTime, systemImage: "calendar")
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.white.opacity(0.92))
                if let loc = coordinator.event.locationName {
                    Label(loc, systemImage: "mappin.and.ellipse")
                        .ruulTextStyle(RuulTypography.body)
                        .foregroundStyle(Color.white.opacity(0.92))
                }
                if coordinator.event.isRecurringGenerated {
                    Text("Recurrente")
                        .ruulTextStyle(RuulTypography.caption)
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, RuulSpacing.s2)
                        .padding(.vertical, 2)
                        .background(Color.white.opacity(0.20), in: Capsule())
                }
            }
            .padding(RuulSpacing.s5)
        }
    }

    private var cover: some View {
        let cover = RuulCoverCatalog.cover(named: coordinator.event.coverImageName)
        return RuulCoverView(cover)
    }

    @ViewBuilder
    private var statusBadge: some View {
        let (text, color): (String, Color) = {
            switch coordinator.event.status {
            case .inProgress: return ("Pasando ahora", .ruulSemanticSuccess)
            case .closed:     return ("Cerrado", .ruulTextSecondary)
            case .cancelled:  return ("Cancelado", .ruulSemanticError)
            case .upcoming:   return ("", .clear)
            }
        }()
        if !text.isEmpty {
            Text(text)
                .ruulTextStyle(RuulTypography.caption)
                .foregroundStyle(Color.white)
                .padding(.horizontal, RuulSpacing.s3)
                .padding(.vertical, 4)
                .background(color, in: Capsule())
        }
    }

    private var dismissButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 28))
                .foregroundStyle(.white, .black.opacity(0.4))
        }
        .buttonStyle(.plain)
        .padding(RuulSpacing.s4)
    }

    // MARK: - RSVP

    private var rsvpSection: some View {
        EventRSVPStateView(
            status: coordinator.myRSVP?.status ?? .pending,
            event: coordinator.event,
            walletAvailable: coordinator.walletService.isAvailable,
            onChange: { newStatus in
                Task { await coordinator.setRSVP(newStatus, reason: nil) }
            },
            onAddToWallet: {
                Task { _ = await coordinator.generateWalletPass() }
            },
            onShowQR: { qrSheetPresented = true }
        )
    }

    private var attendeesSection: some View {
        AttendeesListSection(
            rsvps: coordinator.rsvps,
            memberLookup: memberLookup
        )
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
    }

    private var cancelAttendanceLink: some View {
        Button {
            cancelAttendanceSheet = true
        } label: {
            Text("No voy a poder ir")
                .ruulTextStyle(RuulTypography.callout)
                .foregroundStyle(Color.ruulTextSecondary)
                .padding(.vertical, RuulSpacing.s3)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    private var isAfterRSVPDeadline: Bool {
        guard let deadline = coordinator.event.rsvpDeadline else { return false }
        return Date.now > deadline
    }
}
