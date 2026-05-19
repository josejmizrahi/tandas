import SwiftUI
import RuulUI
import RuulCore

// MARK: - Phase E: EventDetailHost rewired to UniversalResourceDetailView

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

    /// Optional sheet to auto-present once the coordinator finishes
    /// bootstrap. Used by post-create intents that want to land the
    /// user directly on an actionable surface (e.g. "Invitar gente"
    /// → .share to share the join link). Consumed exactly once on
    /// first appear so navigating back + forward doesn't re-trigger.
    public let initialSheet: Sheet?

    /// When true, auto-launches the QR scanner once the coordinator
    /// finishes bootstrap. Scanner needs the live coordinator (passed
    /// via onScannerOpen) and lives on its own RootShellState slot —
    /// can't be driven by the generic `Sheet` enum. Consumed exactly
    /// once like `initialSheet`.
    public let autoOpenScanner: Bool

    public init(
        event: Event,
        group: RuulCore.Group,
        currentUserId: UUID,
        memberDirectory: [UUID: MemberWithProfile],
        calendarService: CalendarExportService?,
        onClose: @escaping () -> Void,
        onEditEvent: @escaping (Event) -> Void,
        onScannerOpen: @escaping (EventDetailCoordinator) -> Void,
        initialSheet: Sheet? = nil,
        autoOpenScanner: Bool = false
    ) {
        self.event = event
        self.group = group
        self.currentUserId = currentUserId
        self.memberDirectory = memberDirectory
        self.calendarService = calendarService
        self.onClose = onClose
        self.onEditEvent = onEditEvent
        self.onScannerOpen = onScannerOpen
        self.initialSheet = initialSheet
        self.autoOpenScanner = autoOpenScanner
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

    // Phase E: block-tree state updated whenever the underlying entities mutate
    @State private var blocks: ResourceBlocks?
    @State private var rotationConfig: RotationSnapshotInput?

    // Phase E: deep management sheets driven by openDestinationId routes
    @State private var showRotationParticipants: Bool = false
    @State private var showLocationEditor: Bool = false

    // One @State enum so individual bools don't pollute the storage map.
    @State private var sheet: Sheet?

    /// Guard so `initialSheet` only fires once per Host lifecycle —
    /// otherwise re-renders after the user dismisses the sheet would
    /// re-trigger it.
    @State private var didFireInitialSheet: Bool = false

    public enum Sheet: Identifiable, Hashable {
        case share, qr, cancelEvent, cancelAttendance, remindAttendees, closeEvent, manualFine, ledger, rules, attendees
        public var id: Self { self }
    }

    // MARK: - Body

    public var body: some View {
        NavigationStack {
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

            // Fire the requested initial presentation once the
            // coordinator is ready. For the scanner we use the
            // dedicated onScannerOpen callback (the scanner has its
            // own state path on RootShellState — it can't be driven
            // by the generic Sheet enum). For everything else the
            // Sheet enum drives the local sheet binding.
            if !didFireInitialSheet {
                didFireInitialSheet = true
                if autoOpenScanner, let coordinator {
                    onScannerOpen(coordinator)
                } else if let pending = initialSheet {
                    sheet = pending
                }
            }
        }
    }

    private var bootView: some View {
        ZStack {
            Color.ruulBackgroundCanvas.ignoresSafeArea()
            RuulLoadingState()
        }
    }

    @ViewBuilder
    private func hosted(coordinator: EventDetailCoordinator) -> some View {
        Group {
            if let blocks {
                UniversalResourceDetailView(
                    blocks: blocks,
                    supportedOverflowActions: Self.supportedOverflowActions,
                    onPrimaryAction: { Task { await dispatchPrimary(blocks: blocks, coordinator: coordinator) } },
                    onOpenBlock: { id in openDestination(id, coordinator: coordinator) },
                    onTapRelation: { card in openRelation(card) },
                    onSeeMoreActivity: { /* TODO: dedicated activity history sheet */ },
                    onOverflowAction: { action in handleOverflow(action, coordinator: coordinator) }
                )
            } else {
                bootView
            }
        }
        .environment(\.eventInteractor, coordinator)
        .environment(\.eventDetailPresenter, presenter)
        .task { await coordinator.refresh() }
        .task { await coordinator.startRealtime() }
        .task { await rebuildBlocks(coordinator: coordinator) }
        .onDisappear { coordinator.stopRealtime() }
        .onChange(of: coordinator.event) { _, _ in Task { await rebuildBlocks(coordinator: coordinator) } }
        .onChange(of: coordinator.myRSVP) { _, _ in Task { await rebuildBlocks(coordinator: coordinator) } }
        .eventDetailSheets(EventDetailSheets.Bindings(
            coordinator: coordinator,
            group: group,
            currentUserId: currentUserId,
            memberDirectory: memberDirectory,
            calendarService: calendarService,
            sheet: $sheet,
            attendeeRoute: $attendeeRoute,
            manualFineCoordinator: manualFineCoordinator,
            ledgerCoordinator: ledgerCoordinator,
            rulesCoordinator: rulesCoordinator
        ))
        .onChange(of: sheet) { _, newValue in
            Task { await prepareCoordinator(for: newValue) }
        }
        // Phase E deep management sheets routed via openDestinationId
        .sheet(isPresented: $showRotationParticipants) {
            RotationParticipantsSheet(eventId: coordinator.event.id) {
                Task { await rebuildBlocks(coordinator: coordinator) }
            }
            .environment(app)
        }
        .sheet(isPresented: $showLocationEditor) {
            LocationEditorSheet(
                eventId: coordinator.event.id,
                initialLocationName: coordinator.event.locationName,
                viewerIsEventHost: coordinator.viewerIsHost,
                onSaved: { Task { await rebuildBlocks(coordinator: coordinator) } }
            )
            .environment(app)
        }
    }

    // MARK: - Phase E: Block building

    /// Assembles an EventDetailSnapshot from the current coordinator state
    /// and runs EventBlockBuilder to produce fresh ResourceBlocks.
    @MainActor
    private func rebuildBlocks(coordinator: EventDetailCoordinator) async {
        // Load rotation config if the event belongs to a series
        if let seriesId = coordinator.event.seriesId {
            if let series = try? await app.resourceSeriesRepo.fetchById(seriesId) {
                rotationConfig = RotationSnapshotInput.from(series: series)
            }
        } else {
            rotationConfig = nil
        }

        let snapshot = EventDetailSnapshot(
            event: coordinator.event,
            myRSVP: coordinator.myRSVP,
            rotationConfig: rotationConfig,
            cycleNumber: coordinator.event.cycleNumber,
            memberDirectory: memberDirectory,
            viewerIsHost: coordinator.viewerIsHost
        )

        let viewerCtx = BlockViewerContext(
            userId: currentUserId,
            permissions: viewerPermissions,
            activeModules: Set(group.effectiveActiveModules),
            memberId: memberDirectory[currentUserId]?.member.id
        )

        let built = EventBlockBuilder().build(
            source: snapshot,
            viewer: viewerCtx,
            now: Date()
        )

        // Phase E activity feed wiring (post-build augmentation) — uses
        // the shared ActivityFeedLoader so every host renders the same
        // shape and the limit+1 trick reports `hasMoreActivity` honestly.
        let feed = await ActivityFeedLoader.load(
            app: app,
            groupId: group.id,
            resourceId: coordinator.event.id
        )
        blocks = ResourceBlocks(
            identity: built.identity,
            state: built.state,
            properties: built.properties,
            capabilities: built.capabilities,
            relations: built.relations,
            activityHead: feed.entries,
            hasMoreActivity: feed.hasMore
        )
    }

    /// Permissions the viewer holds in this group (for BlockViewerContext).
    private var viewerPermissions: Set<Permission> {
        guard let me = memberDirectory[currentUserId]?.member else { return [] }
        let catalog = group.effectiveRoles
        var perms = Set<Permission>()
        for raw in me.rawRoles {
            if let def = catalog[raw] {
                for p in def.permissions { perms.insert(p) }
            }
        }
        return perms
    }

    // MARK: - Phase E: Primary action dispatch

    @MainActor
    private func dispatchPrimary(blocks: ResourceBlocks, coordinator: EventDetailCoordinator) async {
        guard let kind = blocks.state.primaryAction?.kind else { return }
        switch kind {
        case .rsvpConfirm:
            await coordinator.setRSVP(.going, plusOnes: 0, reason: nil)
        case .rsvpCancel:
            sheet = .cancelAttendance
        case .viewHostActions:
            sheet = .closeEvent
        case .none,
             .exerciseRight, .openContribute, .openBooking,
             .viewClosed, .payFine, .castVote:
            break  // not applicable for events
        }
    }

    // MARK: - Phase E: Block open-destination routing

    private func openDestination(_ id: String, coordinator: EventDetailCoordinator) {
        switch id {
        case "rotation.participants":
            showRotationParticipants = true
        case "location.editor":
            showLocationEditor = true
        case "rsvp.manager":
            sheet = .attendees
        case "event.activity":
            sheet = .attendees  // route to attendees/activity list
        default:
            break
        }
    }

    private func openRelation(_ card: RelationCard) {
        // Phase 2: resource_links deep navigation
    }

    // MARK: - Phase E: Overflow action routing

    private func handleOverflow(_ action: UniversalResourceDetailView.OverflowAction, coordinator: EventDetailCoordinator) {
        switch action {
        case .share:
            sheet = .share
        case .edit:
            onEditEvent(coordinator.event)
        case .addToCalendar:
            addToCalendarViaPresenter()
        case .walletPass:
            Task { _ = await coordinator.generateWalletPass() }
        case .archive:
            // TODO: archive_resource RPC — post-Beta-1
            break
        case .delete, .report:
            // Not exposed in Phase E — post-Beta-1
            break
        }
    }

    // MARK: - Legacy Context wiring (kept for eventDetailSheets modifier compatibility)

    private var presenter: EventDetailPresenter {
        EventDetailPresenter(
            onPresentShareSheet: { sheet = .share },
            onPresentMemberQR: { sheet = .qr },
            onAddToWallet: { Task { _ = await coordinator?.generateWalletPass() } },
            onAddToCalendar: addToCalendarViaPresenter,
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

    /// Wraps CalendarExportService.addToCalendar para que el dispatcher
    /// del top-nav menu pueda invocarlo directo (sin pasar por
    /// ShareEventSheet). EventKit solicita authorization la primera vez
    /// dentro de addToCalendar — best-effort fail-soft.
    private func addToCalendarViaPresenter() {
        guard let service = calendarService, let event = coordinator?.event ?? Optional(event) else { return }
        let vocabulary = group.eventVocabulary
        Task {
            _ = try? await service.addToCalendar(event, vocabulary: vocabulary)
        }
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
            // Mig 00262: admin separó de founder. canCreate de rules
            // requiere permission, no identity — usamos isAdmin que
            // cubre founders (vía backfill) y admins explícitos.
            let isAdmin = me?.isAdmin == true
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

    // MARK: - Overflow declaration

    /// Events support sharing, editing, calendar export, and wallet pass.
    /// Archive/delete/report are not surfaced — archive lands in a post-
    /// Beta-1 follow-up that wires the existing archive_resource RPC.
    private static let supportedOverflowActions: Set<UniversalResourceDetailView.OverflowAction> = [
        .share, .edit, .addToCalendar, .walletPass
    ]
}
