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
                .presentationBackground(.ultraThinMaterial)
            }
            .sheet(isPresented: bindingForSheet(.cancelEvent)) {
                CancelEventSheet(isPresented: bindingForSheet(.cancelEvent)) { reason in
                    Task { await b.coordinator.cancelEvent(reason: reason) }
                }
                .presentationDetents([.medium])
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
                .presentationBackground(.ultraThinMaterial)
            }
            .sheet(isPresented: bindingForSheet(.closeEvent)) {
                CloseEventSheet(
                    isPresented: bindingForSheet(.closeEvent),
                    vocabulary: b.group.eventVocabulary
                ) {
                    Task { await b.coordinator.closeEvent(autoGenerateEnabled: false) }
                }
                .presentationDetents([.medium])
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
                    .presentationBackground(.ultraThinMaterial)
                }
            }
            .sheet(isPresented: bindingForSheet(.ledger)) {
                if let lc = b.ledgerCoordinator {
                    ResourceLedgerSheet(
                        isPresented: bindingForSheet(.ledger),
                        coordinator: lc,
                        groupVocabulary: b.group.eventVocabulary
                    )
                    .presentationDetents([.large])
                    .presentationBackground(.ultraThinMaterial)
                }
            }
            .sheet(isPresented: bindingForSheet(.rules)) {
                if let rc = b.rulesCoordinator {
                    ResourceRulesSheet(
                        isPresented: bindingForSheet(.rules),
                        coordinator: rc
                    )
                    .presentationDetents([.large])
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
