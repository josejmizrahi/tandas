import SwiftUI
import RuulUI
import RuulCore

/// Shell view that owns every piece of event-specific state needed to
/// render the polymorphic `UniversalResourceDetailView` for an event:
///
///   - `EventDetailCoordinator` — domain state + mutations, exposed as
///     `EventInteractor` to capability sections via SwiftUI environment.
///   - Sheet bindings (Share / QR / Cancel / Remind / Close / Manual fine
///     / Ledger / Rules / Member detail) so the sections call presenter
///     closures and the sheets present at this layer.
///   - Async loads: capability set from `public.resource_capabilities`,
///     governance check for manual-fine authorization.
///
/// The wider app shell (MainTabView) only has to pass in the `Event`,
/// the parent `Group`, a snapshot of the member directory, and a handful
/// of route-tear-down callbacks. Everything else is handled here. Phase
/// 11 deletes the legacy `EventDetailView` once this is the sole entry.
public struct EventDetailHost: View {
    @Environment(AppState.self) private var app

    public let event: Event
    public let group: RuulCore.Group
    public let currentUserId: UUID
    public let memberDirectory: [UUID: MemberWithProfile]
    public let calendarService: CalendarExportService?
    public let onClose: () -> Void
    public let onEditEvent: (Event) -> Void
    public let onScannerOpen: (EventDetailCoordinator) -> Void

    public init(
        event: Event,
        group: RuulCore.Group,
        currentUserId: UUID,
        memberDirectory: [UUID: MemberWithProfile],
        calendarService: CalendarExportService?,
        onClose: @escaping () -> Void,
        onEditEvent: @escaping (Event) -> Void,
        onScannerOpen: @escaping (EventDetailCoordinator) -> Void
    ) {
        self.event = event
        self.group = group
        self.currentUserId = currentUserId
        self.memberDirectory = memberDirectory
        self.calendarService = calendarService
        self.onClose = onClose
        self.onEditEvent = onEditEvent
        self.onScannerOpen = onScannerOpen
    }

    // MARK: - State

    @State private var coordinator: EventDetailCoordinator?
    @State private var enabledCapabilities: Set<String> = []
    @State private var canIssueManualFine: Bool = false
    @State private var attentionActions: [UserAction] = []
    @State private var attendeeRoute: MemberWithProfile?
    @State private var ledgerCoordinator: ResourceLedgerCoordinator?
    @State private var rulesCoordinator: ResourceRulesCoordinator?
    @State private var manualFineCoordinator: AddManualFineCoordinator?

    // One @State enum so individual bools don't pollute the storage map.
    @State private var sheet: Sheet?

    private enum Sheet: Identifiable, Hashable {
        case share, qr, cancelEvent, cancelAttendance, remindAttendees, closeEvent, manualFine, ledger, rules, attendees
        var id: Self { self }
    }

    // MARK: - Body

    public var body: some View {
        Group {
            if let coordinator {
                hosted(coordinator: coordinator)
            } else {
                bootView
            }
        }
        .task {
            guard coordinator == nil else { return }
            let bootstrap = EventDetailBootstrap(
                app: app,
                event: event,
                group: group,
                currentUserId: currentUserId,
                memberDirectory: memberDirectory
            )
            let result = await bootstrap.run()
            coordinator = result.coordinator
            enabledCapabilities = result.enabledCapabilities
            attentionActions = result.attentionActions
            canIssueManualFine = result.canIssueManualFine
        }
    }

    private var bootView: some View {
        ZStack {
            Color.ruulBackground.ignoresSafeArea()
            RuulLoadingState()
        }
    }

    @ViewBuilder
    private func hosted(coordinator: EventDetailCoordinator) -> some View {
        UniversalResourceDetailViewLegacy(context: detailContext(coordinator: coordinator))
            .environment(\.eventInteractor, coordinator)
            .environment(\.eventDetailPresenter, presenter)
            .task { await coordinator.refresh() }
            .task { await coordinator.startRealtime() }
            .onDisappear { coordinator.stopRealtime() }
            .ruulSheet(isPresented: bindingForSheet(.share)) {
                ShareEventSheet(
                    isPresented: bindingForSheet(.share),
                    event: coordinator.event,
                    groupVocabulary: group.eventVocabulary,
                    hostName: hostName(for: coordinator.event),
                    onAddToCalendar: { addToCalendar(event: coordinator.event) }
                )
            }
            .ruulSheet(isPresented: bindingForSheet(.qr)) {
                MemberQRSheet(
                    isPresented: bindingForSheet(.qr),
                    eventId: coordinator.event.id,
                    memberId: coordinator.myRSVP?.userId ?? currentUserId,
                    eventTitle: coordinator.event.title
                )
            }
            .ruulSheet(isPresented: bindingForSheet(.cancelEvent)) {
                CancelEventSheet(isPresented: bindingForSheet(.cancelEvent)) { reason in
                    Task { await coordinator.cancelEvent(reason: reason) }
                }
            }
            .ruulSheet(isPresented: bindingForSheet(.cancelAttendance)) {
                CancelAttendanceSheet(
                    isPresented: bindingForSheet(.cancelAttendance),
                    isAfterDeadline: isAfterRSVPDeadline(coordinator: coordinator)
                ) { reason in
                    Task { await coordinator.setRSVP(.declined, plusOnes: 0, reason: reason) }
                }
            }
            .ruulSheet(isPresented: bindingForSheet(.remindAttendees)) {
                RemindAttendeesSheet(
                    isPresented: bindingForSheet(.remindAttendees),
                    pendingCount: coordinator.rsvps.filter { $0.status == .pending }.count,
                    eventTitle: coordinator.event.title,
                    vocabulary: group.eventVocabulary
                ) {
                    Task { _ = await coordinator.sendHostReminders() }
                }
            }
            .ruulSheet(isPresented: bindingForSheet(.closeEvent)) {
                CloseEventSheet(
                    isPresented: bindingForSheet(.closeEvent),
                    vocabulary: group.eventVocabulary
                ) {
                    Task { await coordinator.closeEvent(autoGenerateEnabled: false) }
                }
            }
            .ruulSheet(isPresented: bindingForSheet(.manualFine)) {
                if let manualFineCoordinator {
                    AddManualFineSheet(
                        isPresented: bindingForSheet(.manualFine),
                        coordinator: manualFineCoordinator,
                        currentUserId: currentUserId
                    )
                }
            }
            .ruulSheet(isPresented: bindingForSheet(.ledger)) {
                if let ledgerCoordinator {
                    ResourceLedgerSheet(
                        isPresented: bindingForSheet(.ledger),
                        coordinator: ledgerCoordinator,
                        groupVocabulary: group.eventVocabulary
                    )
                }
            }
            .ruulSheet(isPresented: bindingForSheet(.rules)) {
                if let rulesCoordinator {
                    ResourceRulesSheet(
                        isPresented: bindingForSheet(.rules),
                        coordinator: rulesCoordinator
                    )
                }
            }
            .ruulSheet(isPresented: bindingForSheet(.attendees)) {
                AttendeesListSheet(
                    rsvps: coordinator.rsvps,
                    memberDirectory: memberDirectory
                ) { userId in
                    sheet = nil
                    if let mwp = memberDirectory[userId] {
                        attendeeRoute = mwp
                    }
                }
            }
            .sheet(item: $attendeeRoute) { mwp in
                NavigationStack {
                    MemberDetailView(
                        memberWithProfile: mwp,
                        group: group,
                        isCurrentUser: mwp.member.userId == currentUserId
                    )
                }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
            .onChange(of: sheet) { _, newValue in
                Task { await prepareCoordinator(for: newValue) }
            }
    }

    // MARK: - Context wiring

    private func detailContext(coordinator: EventDetailCoordinator) -> ResourceDetailContext {
        ResourceDetailContext(
            resource: ResourceRow.fromEvent(coordinator.event),
            group: group,
            currentUserId: currentUserId,
            enabledCapabilities: enabledCapabilities,
            memberDirectory: memberDirectory,
            displayName: coordinator.event.title,
            attentionActions: attentionActions,
            onPresentLedger: { sheet = .ledger },
            onPresentRules: { sheet = .rules },
            onPresentEditResource: { onEditEvent(coordinator.event) },
            // Events have their capability set hard-seeded by mig
            // 00109/00110 — surfacing "Activar capability" would be a
            // dead route. The top-nav menu filters this item out via
            // ResourceDetailContext.usesEventHero.
            onPresentEnableCapability: { },
            onOpenInboxAction: { action in
                await openInboxAction(action, coordinator: coordinator)
            },
            onSelectMember: { userId in
                if let mwp = memberDirectory[userId] { attendeeRoute = mwp }
            },
            onDismiss: onClose
        )
    }

    private var presenter: EventDetailPresenter {
        EventDetailPresenter(
            onPresentShareSheet: { sheet = .share },
            onPresentMemberQR: { sheet = .qr },
            onAddToWallet: { Task { _ = await coordinator?.generateWalletPass() } },
            onPresentScanner: {
                if let coordinator { onScannerOpen(coordinator) }
            },
            onPresentManualFineSheet: { sheet = .manualFine },
            onPresentRemindAttendeesSheet: { sheet = .remindAttendees },
            onPresentCancelEventSheet: { sheet = .cancelEvent },
            onPresentCloseEventSheet: { sheet = .closeEvent },
            onPresentCancelAttendanceSheet: { sheet = .cancelAttendance },
            onPresentEditEvent: { onEditEvent(coordinator?.event ?? event) },
            onPresentAttendeesList: { sheet = .attendees },
            canIssueManualFine: canIssueManualFine
        )
    }

    // MARK: - Bindings

    /// A two-way `Binding<Bool>` over a single sheet case so each sheet
    /// modifier can drive the shared `sheet` enum without exposing the
    /// rest of the cases. Setting false from a sheet just clears the
    /// route if it currently matches.
    private func bindingForSheet(_ kind: Sheet) -> Binding<Bool> {
        Binding(
            get: { sheet == kind },
            set: { newValue in
                if newValue {
                    sheet = kind
                } else if sheet == kind {
                    sheet = nil
                }
            }
        )
    }

    // MARK: - Async work

    /// Inbox handler — dispatches a tapped action to its natural route.
    /// RSVP-pending → focus the RSVP intent in place; fine-related →
    /// open the appropriate sheet; everything else falls back to a
    /// resolve mark-as-read so the action drops out of the list.
    @MainActor
    private func refreshAttentionActions() async {
        let pending = (try? await app.userActionRepo.pending(
            userId: currentUserId,
            groupId: group.id
        )) ?? []
        attentionActions = pending.filter { $0.referenceId == event.id && $0.resolvedAt == nil }
    }

    @MainActor
    private func openInboxAction(_ action: UserAction, coordinator: EventDetailCoordinator) async {
        switch action.actionType {
        case .rsvpPending:
            // Surface is already on screen — just resolve the prompt so
            // it stops nagging. The user RSVPs via the Primary Actions
            // CTA.
            try? await app.userActionRepo.resolve(actionId: action.id)
            await refreshAttentionActions()
        case .finePending, .fineVoided, .fineProposalReview, .appealVotePending:
            // Fines live in their own surface; resolve the inbox row so
            // it disappears, and let the user navigate via the host
            // actions or MyFines.
            try? await app.userActionRepo.resolve(actionId: action.id)
            await refreshAttentionActions()
        default:
            try? await app.userActionRepo.resolve(actionId: action.id)
            await refreshAttentionActions()
        }
    }

    /// Lazily build the sub-coordinator a sheet needs the first time it
    /// opens. Mirrors the original lifecycle pattern from `EventDetailView`:
    /// keeping coordinators stale-but-warm across open/close cycles so
    /// re-opening doesn't trigger redundant fetches.
    @MainActor
    private func prepareCoordinator(for kind: Sheet?) async {
        guard let kind, let coordinator else { return }
        switch kind {
        case .manualFine where manualFineCoordinator == nil:
            manualFineCoordinator = AddManualFineCoordinator(
                groupId: group.id,
                eventId: event.id,
                fineRepo: app.fineRepo,
                groupsRepo: app.groupsRepo
            )
        case .ledger where ledgerCoordinator == nil:
            let ctx = ResourceLedgerContext(
                groupId: event.groupId,
                resourceId: event.id,
                resourceType: "event",
                displayName: event.title,
                currentUserId: currentUserId
            )
            ledgerCoordinator = ResourceLedgerCoordinator(
                context: ctx,
                ledgerRepo: app.ledgerRepo,
                groupsRepo: app.groupsRepo,
                policyRepo: app.policyRepo
            )
        case .rules where rulesCoordinator == nil:
            let me = memberDirectory[currentUserId]?.member
            let isAdmin = me?.isFounder == true
            let isHost = coordinator.event.hostId == currentUserId
            let ctx = ResourceRuleContext(
                groupId: event.groupId,
                resourceId: event.id,
                resourceType: "event",
                displayName: event.title,
                canCreate: isAdmin || isHost
            )
            rulesCoordinator = ResourceRulesCoordinator(
                context: ctx,
                ruleRepo: app.ruleRepo,
                shapeRegistry: app.ruleShapeRegistry
            )
        default:
            break
        }
    }

    // MARK: - Helpers

    private func hostName(for event: Event) -> String? {
        guard let hostId = event.hostId else { return nil }
        return memberDirectory[hostId]?.displayName
    }

    private func isAfterRSVPDeadline(coordinator: EventDetailCoordinator) -> Bool {
        guard let deadline = coordinator.event.rsvpDeadline else { return false }
        return Date.now > deadline
    }

    private func addToCalendar(event: Event) {
        guard let calendarService else { return }
        Task {
            _ = try? await calendarService.addToCalendar(event, vocabulary: group.eventVocabulary)
        }
    }

}
