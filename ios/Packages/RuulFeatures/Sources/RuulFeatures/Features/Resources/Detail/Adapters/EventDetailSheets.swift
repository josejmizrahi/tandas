import SwiftUI
import RuulUI
import RuulCore

/// Centralizes the 10 sheet/cover modifiers EventDetailHost owns.
/// Apply via `.eventDetailSheets(bindings)` on the hosted view.
///
/// All bindings + callbacks come from EventDetailHost via the
/// `Bindings` value bundle, keeping this ViewModifier stateless.
public struct EventDetailSheets: ViewModifier {
    public struct Bindings {
        public let coordinator: EventDetailCoordinator
        public let group: RuulCore.Group
        public let currentUserId: UUID
        public let memberDirectory: [UUID: MemberWithProfile]
        public let calendarService: CalendarExportService?
        public let sheet: Binding<EventDetailHost.Sheet?>
        public let attendeeRoute: Binding<MemberWithProfile?>
        public let manualFineCoordinator: AddManualFineCoordinator?
        public let ledgerCoordinator: ResourceLedgerCoordinator?
        public let rulesCoordinator: ResourceRulesCoordinator?

        public init(
            coordinator: EventDetailCoordinator,
            group: RuulCore.Group,
            currentUserId: UUID,
            memberDirectory: [UUID: MemberWithProfile],
            calendarService: CalendarExportService?,
            sheet: Binding<EventDetailHost.Sheet?>,
            attendeeRoute: Binding<MemberWithProfile?>,
            manualFineCoordinator: AddManualFineCoordinator?,
            ledgerCoordinator: ResourceLedgerCoordinator?,
            rulesCoordinator: ResourceRulesCoordinator?
        ) {
            self.coordinator = coordinator
            self.group = group
            self.currentUserId = currentUserId
            self.memberDirectory = memberDirectory
            self.calendarService = calendarService
            self.sheet = sheet
            self.attendeeRoute = attendeeRoute
            self.manualFineCoordinator = manualFineCoordinator
            self.ledgerCoordinator = ledgerCoordinator
            self.rulesCoordinator = rulesCoordinator
        }
    }

    let b: Bindings

    public init(_ bindings: Bindings) {
        self.b = bindings
    }

    public func body(content: Content) -> some View {
        content
            .sheet(isPresented: bindingForSheet(.share)) {
                ShareEventSheet(
                    isPresented: bindingForSheet(.share),
                    event: b.coordinator.event,
                    groupVocabulary: b.group.eventVocabulary,
                    hostName: hostName(for: b.coordinator.event),
                    onAddToCalendar: { addToCalendar(event: b.coordinator.event) }
                )
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
                .presentationBackground(.ultraThinMaterial)
            }
            .sheet(isPresented: bindingForSheet(.qr)) {
                MemberQRSheet(
                    isPresented: bindingForSheet(.qr),
                    eventId: b.coordinator.event.id,
                    memberId: b.coordinator.myRSVP?.userId ?? b.currentUserId,
                    eventTitle: b.coordinator.event.title
                )
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
                .presentationBackground(.ultraThinMaterial)
            }
            .sheet(isPresented: bindingForSheet(.cancelEvent)) {
                CancelEventSheet(
                    isPresented: bindingForSheet(.cancelEvent),
                    eventName: b.coordinator.event.title
                ) { reason in
                    // FASE 3 B.2: el sheet espera + reporta éxito/fail.
                    b.coordinator.clearError()
                    await b.coordinator.cancelEvent(reason: reason)
                    return b.coordinator.error == nil
                }
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
                .presentationBackground(.ultraThinMaterial)
            }
            .sheet(isPresented: bindingForSheet(.cancelAttendance)) {
                CancelAttendanceSheet(
                    isPresented: bindingForSheet(.cancelAttendance),
                    isAfterDeadline: isAfterRSVPDeadline(coordinator: b.coordinator)
                ) { reason in
                    Task { await b.coordinator.setRSVP(.declined, plusOnes: 0, reason: reason) }
                }
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
                .presentationBackground(.ultraThinMaterial)
            }
            .sheet(isPresented: bindingForSheet(.remindAttendees)) {
                RemindAttendeesSheet(
                    isPresented: bindingForSheet(.remindAttendees),
                    pendingCount: b.coordinator.rsvps.filter { $0.status == .pending }.count,
                    eventTitle: b.coordinator.event.title,
                    vocabulary: b.group.eventVocabulary
                ) {
                    Task { _ = await b.coordinator.sendHostReminders() }
                }
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
                .presentationBackground(.ultraThinMaterial)
            }
            .sheet(isPresented: bindingForSheet(.closeEvent)) {
                CloseEventSheet(
                    isPresented: bindingForSheet(.closeEvent),
                    vocabulary: b.group.eventVocabulary,
                    eventName: b.coordinator.event.title
                ) {
                    // FASE 3 B.2: el sheet ahora espera el await y nos
                    // pide reportar éxito/fallo para respirar la
                    // consecuencia con frase humana antes del dismiss.
                    // `clearError()` antes garantiza que el Bool refleja
                    // ESTA invocación, no errores residuales de ops previos.
                    b.coordinator.clearError()
                    await b.coordinator.closeEvent(autoGenerateEnabled: false)
                    return b.coordinator.error == nil
                }
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
                .presentationBackground(.ultraThinMaterial)
            }
            .sheet(isPresented: bindingForSheet(.manualFine)) {
                if let mf = b.manualFineCoordinator {
                    AddManualFineSheet(
                        isPresented: bindingForSheet(.manualFine),
                        coordinator: mf,
                        currentUserId: b.currentUserId
                    )
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(.ultraThinMaterial)
                }
            }
            // Money UX Consolidation PR-D (2026-05-24): `.ledger`
            // legacy entry redirects to the unified
            // `.movementPicker`. Coordinator still hydrates so any
            // secondary view that reads its entries keeps working.
            .onChange(of: b.sheet.wrappedValue) { _, current in
                if current == .ledger {
                    b.sheet.wrappedValue = .movementPicker
                }
            }
            .sheet(isPresented: bindingForSheet(.movementPicker)) {
                RegisterMovementSheet { kind in
                    switch kind {
                    case .contribution:  b.sheet.wrappedValue = .movementContribute
                    case .expense:       b.sheet.wrappedValue = .movementExpense
                    case .settlement:    b.sheet.wrappedValue = .movementSettle
                    case .reimbursement, .payout, .poolCharge, .vendorPayment:
                        b.sheet.wrappedValue = .movementExpense
                    }
                }
                .presentationBackground(.ultraThinMaterial)
            }
            .sheet(isPresented: bindingForSheet(.movementContribute)) {
                ContributeToSharedMoneySheet(
                    groupId: b.group.id,
                    currency: b.group.currency,
                    sourceResource: (id: b.coordinator.event.id, name: b.coordinator.event.title),
                    onDidContribute: {
                        Task { await b.coordinator.refresh() }
                    }
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(.ultraThinMaterial)
            }
            .sheet(isPresented: bindingForSheet(.movementExpense)) {
                RecordSharedExpenseSheet(
                    groupId: b.group.id,
                    currency: b.group.currency,
                    members: Array(b.memberDirectory.values),
                    sourceResource: (id: b.coordinator.event.id, name: b.coordinator.event.title),
                    onDidRecord: {
                        Task { await b.coordinator.refresh() }
                    }
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(.ultraThinMaterial)
            }
            .sheet(isPresented: bindingForSheet(.movementSettle)) {
                SettlementSheet(
                    groupId: b.group.id,
                    resourceId: b.coordinator.event.id,
                    currency: b.group.currency,
                    members: Array(b.memberDirectory.values),
                    suggestedToMemberId: nil,
                    onDidSettle: {
                        Task { await b.coordinator.refresh() }
                    }
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(.ultraThinMaterial)
            }
            .fullScreenCover(isPresented: bindingForSheet(.rules)) {
                if let rc = b.rulesCoordinator {
                    ResourceRulesSheet(
                        isPresented: bindingForSheet(.rules),
                        coordinator: rc
                    )
                    .presentationBackground(.ultraThinMaterial)
                }
            }
            .sheet(isPresented: bindingForSheet(.attendees)) {
                AttendeesListSheet(
                    rsvps: b.coordinator.rsvps,
                    memberDirectory: b.memberDirectory
                ) { userId in
                    b.sheet.wrappedValue = nil
                    if let mwp = b.memberDirectory[userId] {
                        b.attendeeRoute.wrappedValue = mwp
                    }
                }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(.ultraThinMaterial)
            }
            .fullScreenCover(item: b.attendeeRoute) { mwp in
                NavigationStack {
                    MemberDetailView(
                        memberWithProfile: mwp,
                        group: b.group,
                        isCurrentUser: mwp.member.userId == b.currentUserId
                    )
                }

            }
    }

    // MARK: - Helpers

    private func bindingForSheet(_ kind: EventDetailHost.Sheet) -> Binding<Bool> {
        Binding(
            get: { b.sheet.wrappedValue == kind },
            set: { newValue in
                if newValue {
                    b.sheet.wrappedValue = kind
                } else if b.sheet.wrappedValue == kind {
                    b.sheet.wrappedValue = nil
                }
            }
        )
    }

    private func hostName(for event: Event) -> String? {
        guard let hostId = event.hostId else { return nil }
        return b.memberDirectory[hostId]?.displayName
    }

    private func isAfterRSVPDeadline(coordinator: EventDetailCoordinator) -> Bool {
        guard let deadline = coordinator.event.rsvpDeadline else { return false }
        return Date.now > deadline
    }

    private func addToCalendar(event: Event) {
        guard let calendarService = b.calendarService else { return }
        Task {
            _ = try? await calendarService.addToCalendar(event, vocabulary: b.group.eventVocabulary)
        }
    }
}

public extension View {
    func eventDetailSheets(_ bindings: EventDetailSheets.Bindings) -> some View {
        modifier(EventDetailSheets(bindings))
    }
}
