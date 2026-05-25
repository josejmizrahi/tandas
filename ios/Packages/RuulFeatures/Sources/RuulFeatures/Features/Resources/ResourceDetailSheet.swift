import SwiftUI
import RuulUI
import RuulCore

/// Polymorphic resource detail sheet. Post the universal-detail rewrite
/// this view does just three things:
///   1. Load the resource's enabled capabilities from
///      `public.resource_capabilities`.
///   2. Resolve the parent Group + cache the member directory.
///   3. Build a `ResourceDetailContext` and hand it to
///      `UniversalResourceDetailView`, which composes the page out of
///      the catalog-registered capability sections.
///
/// Ledger + rules tap routes go through the polymorphic
/// `ResourceLedgerCoordinator` / `ResourceRulesCoordinator`, opening
/// `ResourceLedgerSheet` / `ResourceRulesSheet` on demand. Coordinator
/// instances are built lazily on first present so we don't pay for
/// them when the user doesn't tap.
public struct ResourceDetailSheet: View {
    @Environment(AppState.self) private var app
    @Environment(RootRouter.self) private var router
    @Environment(\.dismiss) private var dismiss

    public let resource: ResourceRow

    /// Live snapshot of the polymorphic row. Initially nil and falls back
    /// to the prop, gets populated after the first re-fetch (e.g. after
    /// an asset RPC that mutated `resources.metadata`). The context built
    /// for child views reads `liveResource ?? resource`, so the initial
    /// render uses the value the caller already had — no extra latency on
    /// open — and subsequent mutations bubble back via `onResourceMutated`.
    @State private var liveResource: ResourceRow?
    @State private var capabilities: [ResourceCapability] = []
    @State private var memberDirectory: [UUID: MemberWithProfile] = [:]
    @State private var resourceActions: [UserAction] = []
    @State private var ledgerSheetPresented: Bool = false
    @State private var ledgerCoordinator: ResourceLedgerCoordinator?
    @State private var rulesSheetPresented: Bool = false
    @State private var rulesCoordinator: ResourceRulesCoordinator?
    /// "Ver más" tap on the Activity layer.
    @State private var activityHistoryPresented: Bool = false

    // MARK: - Type-specific projections loaded on first appear

    /// Fund balance snapshot. Lives here (not on Resource) because the
    /// rich `.fund(_:)` factory in `ResourceDetailView` needs
    /// `balanceCents` / `inCents` / `outCents` / `currency` — all of which
    /// come from `fund_balance_view`, not the polymorphic `resources` row.
    @State private var fundProjection: Fund?
    /// Last 50 ledger entries for this resource. Renders in the
    /// "Movimientos" section of funds; we map each to an `ActivityItem`
    /// at config-build time.
    @State private var ledgerEntries: [LedgerEntry] = []
    /// All bookings for a slot/space resource. Powers `nextBookingTime`
    /// and `bookingsThisMonth` on `SpaceInput`.
    @State private var bookings: [Booking] = []
    /// Slots that belong to the space (resource_type=slot, assetId=space.id).
    /// V1 derives bookings this month + next booking time from this list
    /// without joining `public.bookings` — a slot with `bookingId != nil`
    /// is considered an active reservation.
    @State private var spaceSlots: [Slot] = []

    // Space-specific sheet bindings — wire the 3 V1 actions (Reservar /
    // Calendario / Editar) to dedicated sheets in
    // `Resources/Sheets/Space/`. State lives here so the new universal
    // detail's inline action handlers can flip a single binding.
    @State private var spaceReservePresented: Bool = false
    @State private var spaceCalendarPresented: Bool = false
    @State private var spaceEditPresented: Bool = false
    @State private var fundEditPresented: Bool = false

    // Asset action sheets (2026-05-24 wire). The sheets themselves
    // live in `AssetSupport.swift` and call `AssetLifecycleRepository`
    // directly; this view only owns the presentation bindings + the
    // toolbar menu that opens them. Surfaces only when
    // `resource.resourceType == .asset`.
    @State private var logMaintenancePresented: Bool = false
    @State private var reportDamagePresented: Bool = false
    @State private var checkOutAssetPresented: Bool = false
    @State private var recordValuationPresented: Bool = false

    public init(resource: ResourceRow) { self.resource = resource }

    public var body: some View {
        NavigationStack {
            content
                .ruulSheetToolbar(displayName, onClose: { dismiss() })
                .toolbar { assetActionsToolbar }
        }
        .task { await load() }
        .task { await redirectIfEvent() }
        // Founder doctrine 2026-05-20 (reframe): detail = complete +
        // opaque; primary CTA opens a transparent form sheet directly.
        // No intermediate "Movimientos" cover — the activity feed
        // already lives inline on the detail via the block builders.
        .sheet(isPresented: $ledgerSheetPresented) {
            if let ledgerCoordinator {
                NavigationStack {
                    AddLedgerEntryDestination(coordinator: ledgerCoordinator)
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(.regularMaterial)
            }
        }
        .onChange(of: ledgerSheetPresented) { _, presented in
            if presented {
                if ledgerCoordinator == nil {
                    ledgerCoordinator = makeLedgerCoordinator()
                }
                // Do NOT call resetForm() here — `presentLedgerForm(kind:)`
                // already reset + assigned the right entry kind. Calling
                // it again would clobber Aportar back to `.expense`.
                Task { await ledgerCoordinator?.load() }
            }
        }
        .fullScreenCover(isPresented: $rulesSheetPresented) {
            if let rulesCoordinator {
                ResourceRulesSheet(
                    isPresented: $rulesSheetPresented,
                    coordinator: rulesCoordinator
                )
                .presentationBackground(.regularMaterial)
            }
        }
        .onChange(of: rulesSheetPresented) { _, presented in
            if presented && rulesCoordinator == nil {
                rulesCoordinator = makeRulesCoordinator()
            }
        }
        .sheet(isPresented: $activityHistoryPresented) {
            ResourceActivityHistorySheet(
                groupId: resource.groupId,
                resourceId: resource.id,
                displayName: displayName
            )
            .environment(app)
            .presentationBackground(.regularMaterial)
            .presentationDragIndicator(.visible)
        }
        // MARK: Space-specific covers — present above the resource detail
        // by attaching here (inside the content), not as siblings at the
        // shell root. SwiftUI only renders one sibling cover at a time.
        .sheet(isPresented: $spaceReservePresented) {
            SpaceReserveSheet(resourceName: displayName)
                .environment(app)
                .presentationBackground(.regularMaterial)
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $spaceCalendarPresented) {
            SpaceCalendarSheet(resource: liveResource ?? resource)
                .environment(app)
                .presentationBackground(.regularMaterial)
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $spaceEditPresented) {
            SpaceEditSheet(resource: liveResource ?? resource) {
                Task { await refreshResource() }
            }
            .environment(app)
            .presentationBackground(.regularMaterial)
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $fundEditPresented) {
            FundEditSheet(resource: liveResource ?? resource) {
                Task { await refreshResource() }
            }
            .environment(app)
            .presentationBackground(.regularMaterial)
            .presentationDragIndicator(.visible)
        }
        // MARK: Asset action sheets — only mounted for resource_type=asset
        // but cheap enough to declare unconditionally (each `.sheet`
        // sleeps until its binding flips). The `onSubmitted` of each
        // sheet refreshes the polymorphic row so the asset detail
        // reflects the new state without a manual reopen.
        .sheet(isPresented: $logMaintenancePresented) {
            LogMaintenanceSheet(asset: liveResource ?? resource) {
                Task { await refreshResource() }
            }
            .environment(app)
            .presentationBackground(.regularMaterial)
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $reportDamagePresented) {
            ReportDamageSheet(asset: liveResource ?? resource) {
                Task { await refreshResource() }
            }
            .environment(app)
            .presentationBackground(.regularMaterial)
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $checkOutAssetPresented) {
            CheckOutAssetSheet(
                asset: liveResource ?? resource,
                members: Array(memberDirectory.values)
            ) {
                Task { await refreshResource() }
            }
            .environment(app)
            .presentationBackground(.regularMaterial)
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $recordValuationPresented) {
            RecordValuationSheet(asset: liveResource ?? resource) {
                Task { await refreshResource() }
            }
            .environment(app)
            .presentationBackground(.regularMaterial)
            .presentationDragIndicator(.visible)
        }
    }

    /// Toolbar trailing menu with asset-specific actions. Hidden when
    /// the resource isn't an asset so other types keep their original
    /// toolbar shape (Cancelar only). Each menu item flips a sheet
    /// binding; the sheet handles the RPC + atom emission.
    @ToolbarContentBuilder
    private var assetActionsToolbar: some ToolbarContent {
        if resource.resourceType == .asset {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        logMaintenancePresented = true
                    } label: {
                        Label("Marcar mantenimiento", systemImage: "wrench.and.screwdriver")
                    }
                    Button {
                        reportDamagePresented = true
                    } label: {
                        Label("Reportar daño", systemImage: "exclamationmark.triangle")
                    }
                    Button {
                        checkOutAssetPresented = true
                    } label: {
                        Label("Prestar activo", systemImage: "arrow.up.right.square")
                    }
                    Button {
                        recordValuationPresented = true
                    } label: {
                        Label("Registrar valuación", systemImage: "chart.line.uptrend.xyaxis")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Acciones del activo")
            }
        }
    }

    /// Light-weight reload after enabling a capability — only refetches
    /// the resource_capabilities rows, not the member directory or
    /// inbox actions.
    @MainActor
    private func reloadCapabilities() async {
        capabilities = (try? await app.resourceCapabilityRepo.list(resourceId: resource.id)) ?? []
    }

    /// Re-fetches the polymorphic row when a child section mutated
    /// `resources.metadata` (asset custody, transfer, checkout, etc.).
    /// Failures fall through silently — the user still sees the prior
    /// snapshot, and the next dismiss/reopen cycle picks up the change.
    @MainActor
    private func refreshResource() async {
        if let fresh = try? await app.resourceRepo.resource(resource.id) {
            liveResource = fresh
            // Phase E: rebuild block tree with the fresh row
            if let group = parentGroup {
                await buildBlocks(for: group)
            }
        }
    }

    /// Dispatches the `Necesita atención` tap. Mirrors the action-type
    /// switch in `HomeTab.handleInboxAction` so the same UserAction
    /// behaves consistently no matter where the user opens it (Inbox
    /// list, Home pendings strip, or here from a resource detail). For
    /// surfaces that already live on this screen (rsvp on an event-like
    /// resource, contribution on a fund) we resolve the action row so it
    /// stops nagging — the user is already at the right place.
    @MainActor
    private func handleInboxAction(_ action: UserAction) async {
        switch action.actionType {
        case .finePending, .fineVoided:
            if let fine = try? await app.fineRepo.fine(id: action.referenceId) {
                router.openFine(fine)
            }
        case .appealVotePending:
            if let appeal = try? await app.appealRepo.appeal(id: action.referenceId),
               let fine = try? await app.fineRepo.fine(id: appeal.fineId) {
                router.openVoteOnAppeal(AppealRouteContext(appeal: appeal, fine: fine))
            }
        case .votePending:
            if let vote = try? await app.voteRepo.vote(id: action.referenceId) {
                router.openVoteDetail(VoteDetailRouteContext(vote: vote))
            }
        case .fineProposalReview, .hostAssigned, .rsvpPending:
            // These reference an event that, for non-event resources,
            // isn't this resource. Open the event detail.
            if let event = try? await app.eventRepo.event(action.referenceId) {
                router.openEvent(event)
            }
        case .ruleChangeApplyPending:
            // Vote → rule → group fetch chain. Re-uses the same async
            // shape as HomeTab.openRuleEditFromInbox.
            guard let vote = try? await app.voteRepo.vote(id: action.referenceId),
                  case .object(let payload) = vote.payload,
                  case .int(let proposedAmount) = payload["proposed_amount"] ?? .null,
                  let group = app.groups.first(where: { $0.id == action.groupId }),
                  let rules = try? await app.ruleRepo.list(groupId: group.id),
                  let rule = rules.first(where: { $0.id == vote.referenceId })
            else { return }
            router.handleRuleChange(
                rule: rule,
                group: group,
                proposedAmount: proposedAmount,
                pendingActionId: action.id
            )
        case .slotPending, .contributionDue, .compensationDue, .assetActionApproval:
            // Resource-scoped pendings — the user is already on the right
            // detail. Resolve so the badge disappears and refresh.
            try? await app.userActionRepo.resolve(actionId: action.id)
            await refreshResourceActions()
        }
    }

    @MainActor
    private func refreshResourceActions() async {
        guard let userId = app.session?.user.id else {
            resourceActions = []
            return
        }
        if let allActions = try? await app.userActionRepo.pending(
            userId: userId,
            groupId: resource.groupId
        ) {
            resourceActions = allActions.filter { $0.referenceId == resource.id }
        } else {
            resourceActions = []
        }
    }

    // MARK: - Phase E: block-tree rendering

    /// Block-tree state — recomputed after load and after any resource mutation.
    @State private var blocks: ResourceBlocks?

    @ViewBuilder
    private var content: some View {
        if let group = parentGroup {
            if let blocks {
                ResourceDetailContent(config: withGroupContext(makeConfig(blocks: blocks, group: group), group: group))
            } else {
                ZStack {
                    Color.ruulBackgroundCanvas.ignoresSafeArea()
                    ProgressView()
                        .controlSize(.large)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .task { await buildBlocks(for: group) }
            }
        } else {
            ZStack {
                Color.ruulBackgroundCanvas.ignoresSafeArea()
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - ResourceBlocks → ResourceConfig

    /// Dispatches to a type-specific adapter when one exists, otherwise
    /// falls back to a generic header + hero + activity shell built from
    /// the polymorphic `ResourceBlocks`. Rich adapters (fund, space) use
    /// the boceto's `.fund(_:)` / `.space(_:)` factories so the user gets
    /// the dedicated balance/breakdown/bookings UI instead of the empty
    /// generic fallback.
    private func makeConfig(blocks: ResourceBlocks, group: RuulCore.Group) -> ResourceConfig {
        let live = liveResource ?? resource
        switch live.resourceType {
        case .fund:
            return makeFundConfig(live: live, blocks: blocks)
        case .space:
            return makeSpaceConfig(live: live, blocks: blocks)
        case .asset, .slot, .right, .event, .unknown:
            return makeGenericConfig(live: live, blocks: blocks, group: group)
        }
    }

    /// Generic fallback for resource types without a rich factory yet.
    /// Maps Identity + Hero + the primary action + Activity. Capability
    /// sections are skipped — promoting them is a follow-up that maps
    /// each `BlockLayoutKind` to a `ResourceSection`.
    private func makeGenericConfig(live: ResourceRow, blocks: ResourceBlocks, group: RuulCore.Group) -> ResourceConfig {
        let accent = blocks.identity.tint.color
        let primary = blocks.state.primaryAction
        let actions: [ResourceAction] = {
            guard let primary, primary.kind != .none else { return [] }
            return [
                ResourceAction(
                    label: primary.label,
                    icon: primary.symbol,
                    tint: accent,
                    handler: { Task { await self.dispatchPrimary(group: group) } }
                )
            ]
        }()
        return ResourceConfig(
            identity: IdentityData(
                iconSystemName: blocks.identity.icon,
                name: blocks.identity.title,
                typeLabel: Self.typeLabel(for: live.resourceType),
                metadata: blocks.identity.subtitleSegments,
                badge: nil
            ),
            accent: accent,
            hero: HeroData(
                value: blocks.state.headline,
                label: blocks.state.supportingFacts.joined(separator: " · "),
                size: .title
            ),
            actions: actions,
            sections: [],
            activity: .static(blocks.activityHead.map(Self.mapActivityEntry)),
            toolbarMenu: makeToolbarMenu(),
            moneyContext: makeMoneyContextIfApplicable(
                live: live,
                blocks: blocks,
                group: group
            )
        )
    }

    /// SharedMoney Phase 4 brick C: surface the universal Money Block
    /// on resource types that benefit from per-resource money attribution
    /// — assets (warehouse / vehicle / inversión per
    /// `doctrine_in_kind_contributions.md`) and events that fall through
    /// to the generic shell (e.g. deeplinks that bypass EventDetailHost).
    ///
    /// Skipped types:
    /// - `.fund`  → has its own makeFundConfig; the fund IS the money.
    /// - `.space` → has its own makeSpaceConfig; will be wired in a
    ///              follow-up brick.
    /// - `.slot` / `.right` / `.unknown` → no money story today;
    ///              `source_resource_id` queries return nil and the
    ///              block would be a confusing empty state.
    private func makeMoneyContextIfApplicable(
        live: ResourceRow,
        blocks: ResourceBlocks,
        group: RuulCore.Group
    ) -> MoneyContext? {
        switch live.resourceType {
        case .asset, .event:
            return MoneyContext(
                groupId: group.id,
                resourceId: live.id,
                resourceName: blocks.identity.title,
                currency: group.currency,
                members: Array(memberDirectory.values),
                onDidChange: { Task { await refreshResource() } }
            )
        case .fund, .space, .slot, .right, .unknown:
            return nil
        }
    }

    /// Fund adapter — feeds the boceto's `.fund(_:)` factory so the user
    /// sees the proper balance hero (with Aportado/Retirado sub-row),
    /// Aportar/Retirar/Libro actions, the movements list, and the
    /// participants pile. Reads `fund_balance_view` + `ledger_entries`
    /// loaded in `loadTypeSpecificProjections`.
    private func makeFundConfig(live: ResourceRow, blocks: ResourceBlocks) -> ResourceConfig {
        let fund = fundProjection
        let currency = fund?.currency ?? "MXN"
        let balance     = Decimal(fund?.balanceCents ?? 0) / 100
        let contributed = Decimal(fund?.inCents ?? 0)      / 100
        let withdrawn   = Decimal(fund?.outCents ?? 0)     / 100
        let createdAgo  = Self.relativeAgo(fund?.createdAt ?? live.createdAt)

        let movements = ledgerEntries.map { entry in
            ActivityItem(
                id: entry.id.uuidString,
                title: Self.ledgerTitle(for: entry),
                subtitle: Self.ledgerSubtitle(for: entry, currency: currency),
                timestamp: entry.occurredAt,
                icon: Self.ledgerIcon(for: entry),
                kind: entry.amountCents >= 0 ? .positive : .negative,
                prebakedRelativeTime: Self.relativeAgo(entry.occurredAt)
            )
        }

        let participants = memberDirectory.values
            .sorted(by: { ($0.profile?.displayName ?? "") < ($1.profile?.displayName ?? "") })
            .map(Self.makePerson)

        let input = FundInput(
            id: live.id.uuidString,
            name: blocks.identity.title,
            createdAgo: createdAgo,
            balance: balance,
            contributed: contributed,
            withdrawn: withdrawn,
            participants: participants,
            movements: movements
        )

        return .fund(
            input,
            onContribute: { presentLedgerForm(kind: .contribution) },
            onWithdraw:   { presentLedgerForm(kind: .expense) },
            onSeeLedger:  { activityHistoryPresented = true },
            onSeeParticipants: { /* future: members sheet */ },
            activityLoader: nil
        )
    }

    /// Opens the AddLedgerEntry form with a pre-selected entry kind so
    /// "Aportar" lands on a contribution form and "Retirar" lands on an
    /// expense form. The legacy single-sheet flow opened both with the
    /// default `.expense` kind which made `Aportar` silently incorrect.
    private func presentLedgerForm(kind: ResourceLedgerCoordinator.EntryKind) {
        if ledgerCoordinator == nil {
            ledgerCoordinator = makeLedgerCoordinator()
        }
        ledgerCoordinator?.resetForm()
        ledgerCoordinator?.formKind = kind
        ledgerSheetPresented = true
    }

    /// Space adapter — uses the boceto's `.space(_:)` factory. Capacity
    /// and location come from `resources.metadata`; bookings this month
    /// and next booking time aggregate over the child `slot` resources
    /// loaded into `spaceSlots`.
    private func makeSpaceConfig(live: ResourceRow, blocks: ResourceBlocks) -> ResourceConfig {
        let capacity = (live.metadata["capacity"]?.intValue) ?? 0
        let location: String = {
            if case let .string(s) = live.metadata["location"] { return s }
            return ""
        }()
        let (bookingsThisMonth, nextBookingTime) = Self.summarize(slots: spaceSlots)
        let input = SpaceInput(
            id: live.id.uuidString,
            name: blocks.identity.title,
            isActive: live.archivedAt == nil,
            capacity: capacity,
            location: location,
            bookingsThisMonth: bookingsThisMonth,
            nextBookingTime: nextBookingTime,
            activity: blocks.activityHead.map(Self.mapActivityEntry)
        )
        return .space(
            input,
            onReserve:     { spaceReservePresented = true },
            onSeeCalendar: { spaceCalendarPresented = true },
            onEdit:        { spaceEditPresented = true }
        )
    }

    private func makeToolbarMenu() -> [ToolbarMenuItem] {
        let live = liveResource ?? resource
        var items: [ToolbarMenuItem] = [
            ToolbarMenuItem(label: "Reglas", icon: "list.bullet.rectangle") {
                rulesSheetPresented = true
            },
            ToolbarMenuItem(label: "Libro", icon: "book") {
                ledgerSheetPresented = true
            }
        ]
        // Editar — exposed per resource type. Funds + spaces have
        // dedicated edit sheets; other types skip the entry until their
        // metadata-update RPC ships.
        switch live.resourceType {
        case .space:
            items.append(ToolbarMenuItem(label: "Editar espacio", icon: "pencil") {
                spaceEditPresented = true
            })
        case .fund:
            items.append(ToolbarMenuItem(label: "Editar fondo", icon: "pencil") {
                fundEditPresented = true
            })
            // SharedMoney Phase 6 (mig 00365): admin-only action to
            // promote this fund to "protected" status — moves it out
            // of the canonical surface into the "Otros fondos /
            // Fondos separados" advanced area. Hidden on the shared
            // pool (the RPC would raise) and on already-protected
            // funds (idempotent but the affordance would be noisy).
            if shouldShowMarkProtected(for: live) {
                items.append(ToolbarMenuItem(label: "Marcar como fondo separado", icon: "lock") {
                    Task { await markCurrentFundProtected() }
                })
            }
        case .asset, .slot, .right, .event, .unknown:
            break
        }
        return items
    }

    /// Phase 6 visibility filter: only show the action on non-shared,
    /// non-already-protected funds. Reads server-stamped metadata
    /// flags (`is_shared_pool`, `is_protected_fund`).
    private func shouldShowMarkProtected(for row: ResourceRow) -> Bool {
        guard row.resourceType == .fund else { return false }
        let isShared = (row.metadata["is_shared_pool"]?.boolValue == true)
            || (row.metadata["is_shared_pool"]?.stringValue == "true")
        let isProtected = (row.metadata["is_protected_fund"]?.boolValue == true)
            || (row.metadata["is_protected_fund"]?.stringValue == "true")
        return !isShared && !isProtected
    }

    @MainActor
    private func markCurrentFundProtected() async {
        let live = liveResource ?? resource
        do {
            try await app.fundRepo.markProtected(fundId: live.id)
            // Refresh the row so the toolbar item disappears (the
            // visibility filter now sees is_protected_fund=true).
            await refreshResource()
        } catch {
            // Silent failure for V1 — the action is admin-rare and
            // the toolbar item simply won't disappear if the RPC
            // erred. A future revision can surface an alert.
        }
    }

    private static func typeLabel(for type: ResourceType) -> String {
        switch type {
        case .event:   return "Evento"
        case .fund:    return "Fondo"
        case .asset:   return "Activo"
        case .space:   return "Espacio"
        case .slot:    return "Reserva"
        case .right:   return "Derecho"
        case .unknown: return ""
        }
    }

    /// Mirrors the mapper used by `EventDetailHost` — keeps the
    /// pre-formatted relative time so the new view's
    /// RelativeDateTimeFormatter doesn't try to recompute from `.now`.
    private static func mapActivityEntry(_ entry: ActivityEntry) -> ActivityItem {
        ActivityItem(
            id: entry.id.uuidString,
            title: entry.sentence,
            subtitle: nil,
            timestamp: .now,
            icon: entry.icon,
            kind: .neutral,
            prebakedRelativeTime: entry.relativeTime
        )
    }

    /// Pretty Spanish relative-time string ("hace 2h", "hace 3 d"). Used
    /// for fund creation age and ledger movement prebaked timestamps so
    /// the new view's formatter doesn't recompute from `.now` and lose
    /// the original `occurred_at` context.
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "es_MX")
        f.unitsStyle = .short
        return f
    }()

    private static func relativeAgo(_ date: Date) -> String {
        relativeFormatter.localizedString(for: date, relativeTo: .now)
    }

    /// One sentence per ledger row. Builders haven't standardized this
    /// surface yet — we fall back to the entry's `metadata.note` and
    /// finally to a default per `type`.
    private static func ledgerTitle(for entry: LedgerEntry) -> String {
        if case let .string(note) = entry.metadata["note"], !note.isEmpty {
            return note
        }
        switch entry.type {
        case LedgerEntry.Kind.contribution: return "Aporte"
        case LedgerEntry.Kind.expense:      return "Gasto"
        case LedgerEntry.Kind.payout:       return "Pago"
        case LedgerEntry.Kind.reimbursement: return "Reembolso"
        case LedgerEntry.Kind.settlement:   return "Liquidación"
        case LedgerEntry.Kind.fineIssued:   return "Multa emitida"
        case LedgerEntry.Kind.finePaid:     return "Multa pagada"
        default:                            return entry.type.capitalized
        }
    }

    private static func ledgerIcon(for entry: LedgerEntry) -> String {
        switch entry.type {
        case LedgerEntry.Kind.contribution, LedgerEntry.Kind.reimbursement, LedgerEntry.Kind.finePaid:
            return "arrow.down.circle"
        case LedgerEntry.Kind.expense, LedgerEntry.Kind.payout, LedgerEntry.Kind.fineIssued:
            return "arrow.up.circle"
        case LedgerEntry.Kind.settlement:
            return "arrow.left.arrow.right.circle"
        default:
            return "circle"
        }
    }

    private static func formatLedgerAmount(_ entry: LedgerEntry, currency: String) -> String {
        let amount = Decimal(entry.amountCents) / 100
        let formatted = amount.formatted(.currency(code: currency))
        return entry.amountCents >= 0 ? "+\(formatted)" : formatted  // negatives carry their own sign
    }

    /// Subtitle for a ledger row: amount + " · Compartido entre N" when
    /// the entry was split (mig 00370). Falls back to plain amount when
    /// the entry has no split metadata, so legacy and protected-fund
    /// rows render unchanged.
    private static func ledgerSubtitle(for entry: LedgerEntry, currency: String) -> String {
        let amount = formatLedgerAmount(entry, currency: currency)
        guard let count = entry.participantCount else { return amount }
        return "\(amount) · Compartido entre \(count)"
    }

    /// Avatar tint comes from `ResourceFamilyTint.persons` to stay
    /// consistent with the rest of the identity surface.
    private static func makePerson(_ mwp: MemberWithProfile) -> Person {
        let name = mwp.profile?.displayName ?? "Miembro"
        let avatar = mwp.profile?.avatarUrl.flatMap(URL.init(string:))
        return Person(
            id: mwp.member.userId.uuidString,
            name: name,
            initials: personInitials(from: name),
            color: ResourceFamilyTint.persons.color,
            imageURL: avatar
        )
    }

    private static func personInitials(from name: String) -> String {
        let chars = name.split(separator: " ").prefix(2).compactMap { $0.first }.map(String.init)
        let joined = chars.joined()
        return joined.isEmpty ? "?" : joined.uppercased()
    }

    /// Splices the group context into the config so `GroupContextSlot`
    /// renders under the identity ribbon. Resolves `proposedBy` from
    /// `resources.created_by` against the loaded `memberDirectory`.
    private func withGroupContext(_ config: ResourceConfig, group: RuulCore.Group) -> ResourceConfig {
        let live = liveResource ?? resource
        let proposedBy = live.createdBy.flatMap { memberDirectory[$0]?.profile?.displayName }
        return ResourceConfig(
            identity: config.identity,
            accent: config.accent,
            hero: config.hero,
            actions: config.actions,
            sections: config.sections,
            activity: config.activity,
            toolbarMenu: config.toolbarMenu,
            groupContext: GroupContextData(
                groupName: group.name,
                groupInitials: Self.groupInitials(group.name),
                proposedBy: proposedBy,
                proposedAt: live.createdAt,
                onTapGroup: { dismiss() }
            ),
            // SharedMoney Phase 4 brick C: preserve moneyContext through
            // the wrapper. Without this, makeGenericConfig (asset/event)
            // populates the slot but the wrapper drops it silently —
            // the Money Block never renders on any sheet-routed detail.
            moneyContext: config.moneyContext
        )
    }

    private static func groupInitials(_ name: String) -> String {
        let chars = name.split(separator: " ").prefix(2).compactMap { $0.first }.map(String.init)
        return chars.joined().uppercased()
    }

    /// Derives `(bookingsThisMonth, nextBookingTime)` from a flat slot
    /// list. "Booking" here = a slot with `bookingId != nil` (i.e.
    /// someone has claimed the time window). Next booking = the closest
    /// future slot whose status hasn't transitioned to archived.
    private static func summarize(slots: [Slot]) -> (count: Int, next: String?) {
        let now = Date.now
        let cal = Calendar.current
        let monthStart = cal.dateInterval(of: .month, for: now)?.start ?? now
        let monthEnd   = cal.dateInterval(of: .month, for: now)?.end   ?? now

        let bookedThisMonth = slots.filter { slot in
            slot.bookingId != nil
                && slot.archivedAt == nil
                && slot.startsAt >= monthStart
                && slot.startsAt < monthEnd
        }.count

        let nextSlot = slots
            .filter { $0.bookingId != nil && $0.archivedAt == nil && $0.startsAt >= now }
            .sorted { $0.startsAt < $1.startsAt }
            .first

        let nextLabel: String?
        if let next = nextSlot {
            let f = DateFormatter()
            f.locale = Locale(identifier: "es_MX")
            f.dateFormat = cal.isDateInToday(next.startsAt)
                ? "'hoy' h:mm a"
                : cal.isDateInTomorrow(next.startsAt) ? "'mañana' h:mm a"
                : "d MMM · h:mm a"
            nextLabel = f.string(from: next.startsAt)
        } else {
            nextLabel = nil
        }
        return (bookedThisMonth, nextLabel)
    }

    /// Builds blocks from the current resource row + group, then augments
    /// the result with the live activity feed.
    ///
    /// Events do NOT build blocks here — the body short-circuits to a
    /// router redirect (see `redirectIfEvent`). Reaching this method with
    /// an event row means the redirect path didn't fire; we fall back to
    /// an identity-only placeholder rather than mis-rendering the event
    /// through a non-event builder.
    @MainActor
    private func buildBlocks(for group: RuulCore.Group) async {
        let live = liveResource ?? resource
        let viewerCtx = viewerContext(group: group)
        let built: ResourceBlocks
        switch live.resourceType {
        case .event:
            built = neutralEventPlaceholderBlocks(for: live)
        case .fund:
            built = FundBlockBuilder().build(source: live, viewer: viewerCtx, now: Date())
        case .right:
            built = RightBlockBuilder().build(source: live, viewer: viewerCtx, now: Date())
        case .asset, .space, .slot:
            built = AssetBlockBuilder().build(source: live, viewer: viewerCtx, now: Date())
        case .unknown:
            built = AssetBlockBuilder().build(source: live, viewer: viewerCtx, now: Date())
        }

        // Post-build augmentation: load system_events for this resource
        // so the activity layer reflects creation/mutation/lifecycle
        // events. Events skip the feed since they redirect anyway.
        if live.resourceType == .event {
            blocks = built
        } else {
            let feed = await ActivityFeedLoader.load(
                app: app,
                groupId: live.groupId,
                resourceId: live.id
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
    }

    /// Identity-only placeholder for events that somehow reach this
    /// generic sheet instead of `EventDetailHost`. The state hero tells
    /// the user we're routing to the right surface; `redirectIfEvent`
    /// does the actual dismiss + push.
    private func neutralEventPlaceholderBlocks(for live: ResourceRow) -> ResourceBlocks {
        let title = live.metadata["title"]?.stringValue ?? "Evento"
        return ResourceBlocks(
            identity: IdentityRibbon(
                icon: "calendar", tint: .events,
                title: title, subtitleSegments: ["Evento"]
            ),
            state: StateHeadline(
                headline: "Abriendo el evento…",
                supportingFacts: [],
                primaryAction: nil,
                urgency: .ambient
            ),
            properties: PropertiesBlock(rows: []),
            capabilities: [],
            relations: [],
            activityHead: [],
            hasMoreActivity: false
        )
    }

    /// Fires once on appear when the resource is an event: fetches the
    /// full Event and hands off to `router.openEvent`, dismissing this
    /// generic sheet. The placeholder blocks above keep the screen
    /// neutral while the fetch resolves.
    @MainActor
    private func redirectIfEvent() async {
        guard resource.resourceType == .event else { return }
        guard let event = try? await app.eventRepo.event(resource.id) else {
            // No event row found — leave the placeholder in place and
            // let the user dismiss. Silently swallowing the error here
            // mirrors the legacy behaviour for missing event rows.
            return
        }
        router.openEvent(event)
        dismiss()
    }

    private func viewerContext(group: RuulCore.Group) -> BlockViewerContext {
        let userId = app.session?.user.id
        let me = userId.flatMap { memberDirectory[$0] }?.member
        let catalog = group.effectiveRoles
        var perms = Set<Permission>()
        if let me {
            for raw in me.rawRoles {
                if let def = catalog[raw] {
                    for p in def.permissions { perms.insert(p) }
                }
            }
        }
        return BlockViewerContext(
            userId: userId,
            permissions: perms,
            activeModules: Set(group.effectiveActiveModules),
            memberId: me?.id
        )
    }

    @MainActor
    private func dispatchPrimary(group: RuulCore.Group) async {
        guard let kind = blocks?.state.primaryAction?.kind else { return }
        switch kind {
        case .openContribute:
            ledgerSheetPresented = true  // route to ledger for fund contribute
        case .openBooking:
            break  // slot/space booking — post-Beta-1
        case .exerciseRight:
            break  // right exercise — post-Beta-1
        case .rsvpConfirm, .rsvpCancel, .viewHostActions,
             .viewClosed, .payFine, .castVote:
            break  // not applicable for non-event resources in this path
        case .none:
            break  // PrimaryAction.Kind.none — no CTA
        }
    }

    private func openBlockDestination(_ id: String, group: RuulCore.Group) {
        switch id {
        case "fund.ledger":
            ledgerSheetPresented = true
        case "fund.contribute":
            ledgerSheetPresented = true  // routes to ledger where contributions are shown
        case "rules":
            rulesSheetPresented = true
        default:
            break
        }
    }

    private var parentGroup: RuulCore.Group? {
        app.groups.first(where: { $0.id == resource.groupId })
    }

    // Phase E: context(for:) and enabledCapabilitySet removed —
    // ResourceDetailSheet now builds ResourceBlocks directly via builders.
    // The capabilities set is retained for ledger/rules coordinator creation
    // but no longer drives section gating inside the View.

    // MARK: - Sub-coordinators

    /// Builds the polymorphic ledger coordinator on first ledger sheet
    /// present. Reuses the resource's group_id + id so the listForResource
    /// query hits the right ledger_entries rows.
    private func makeLedgerCoordinator() -> ResourceLedgerCoordinator {
        let ctx = ResourceLedgerContext(
            groupId: resource.groupId,
            resourceId: resource.id,
            resourceType: resourceTypeString,
            displayName: displayName,
            currentUserId: app.session?.user.id ?? UUID()
        )
        return ResourceLedgerCoordinator(
            context: ctx,
            ledgerRepo: app.ledgerRepo,
            groupsRepo: app.groupsRepo,
            policyRepo: app.policyRepo
        )
    }

    /// Builds the polymorphic rules coordinator. `canCreate` is the
    /// server-side gate predicate. V1 mirrors the legacy behavior:
    /// founders + admins can create; everyone else reads only. The
    /// gate hardens in the governance plan (Tasks 8-10) once
    /// resolve_governance is fully wired into RuleRepository mutations.
    private func makeRulesCoordinator() -> ResourceRulesCoordinator {
        let ctx = ResourceRuleContext(
            groupId: resource.groupId,
            resourceId: resource.id,
            resourceType: resourceTypeString,
            displayName: displayName,
            canCreate: canCreateRules
        )
        return ResourceRulesCoordinator(
            context: ctx,
            ruleRepo: app.ruleRepo,
            shapeRegistry: app.ruleShapeRegistry
        )
    }

    /// True when the current user holds a role with the `modifyRules`
    /// permission. Local catalog walk (server still gates the write at
    /// the RPC level via has_permission(modifyRules)).
    ///
    /// Sprint E (V18 fix): pre-Sprint-E this gated on identity (`group
    /// .createdBy == userId`) which meant a transferred-founder or a
    /// custom rules-managing role couldn't see the create-rule CTA.
    /// Now reads the catalog so any role with `modifyRules` qualifies.
    private var canCreateRules: Bool {
        guard let userId = app.session?.user.id,
              let group = parentGroup,
              let me = memberDirectory[userId]?.member else { return false }
        let catalog = group.effectiveRoles
        for raw in me.rawRoles {
            if let def = catalog[raw], def.grants(.modifyRules) { return true }
        }
        return false
    }

    /// Raw wire-format string for the resource type ("event", "fund", etc.).
    /// Feeds `ResourceLedgerContext` and `ResourceRuleContext` which use it
    /// for analytics / catalog filtering — not user-facing display.
    private var resourceTypeString: String { resource.resourceType.rawString }

    @MainActor
    private func load() async {
        async let capsTask = app.resourceCapabilityRepo.list(resourceId: resource.id)
        async let membersTask = app.groupsRepo.membersWithProfiles(of: resource.groupId)
        capabilities = (try? await capsTask) ?? []
        let members = (try? await membersTask) ?? []
        var dir: [UUID: MemberWithProfile] = [:]
        for m in members { dir[m.member.userId] = m }
        memberDirectory = dir

        // Inbox is cross-group; pending(_, groupId:) filters to this group
        // so unrelated rows from other groups don't leak into the section.
        // V1 attribution to a resource: `referenceId == resource.id` —
        // catches rsvpPending + fineProposalReview for events directly.
        // Phase 2 widens this to follow indirect refs (finePending →
        // fine → event, etc.).
        if let userId = app.session?.user.id,
           let allActions = try? await app.userActionRepo.pending(
               userId: userId,
               groupId: resource.groupId
           )
        {
            resourceActions = allActions.filter { $0.referenceId == resource.id }
        } else {
            resourceActions = []
        }

        // Phase E: build the initial block tree now that we have member directory.
        if let group = parentGroup {
            await buildBlocks(for: group)
        }

        // Type-specific projections that power the rich `.fund(_:)` /
        // `.space(_:)` factories. Skip the fetches for types that don't
        // need them so we don't waste a round-trip on assets/rights.
        await loadTypeSpecificProjections()
    }

    /// Fetches the polymorphic projections the rich per-type adapters
    /// need (Fund balance row, ledger entries, slot bookings). Each
    /// branch fails open — silent fallback means the new layout still
    /// renders even if the projection isn't reachable yet.
    @MainActor
    private func loadTypeSpecificProjections() async {
        let live = liveResource ?? resource
        switch live.resourceType {
        case .fund:
            async let fund = app.fundRepo.get(live.id)
            async let ledger = app.ledgerRepo.listForResource(live.id, limit: 50)
            fundProjection = (try? await fund)?.first
            ledgerEntries = (try? await ledger) ?? []
        case .slot:
            bookings = (try? await app.bookingRepo.listForSlot(live.id)) ?? []
        case .space:
            // A space is a parent container; its bookable units are
            // child `slot` resources with `assetId == space.id`. We
            // surface slot-derived counts directly so V1 doesn't need
            // a separate "space_booking_summary" projection.
            spaceSlots = (try? await app.slotRepo.listForAsset(live.id)) ?? []
        case .asset, .right, .event, .unknown:
            break
        }
    }

    private var displayName: String {
        if case let .string(name) = resource.metadata["name"]  { return name }
        if case let .string(title) = resource.metadata["title"] { return title }
        return typeLabel
    }

    private var typeLabel: String {
        resource.resourceType.humanLabel
    }
}
