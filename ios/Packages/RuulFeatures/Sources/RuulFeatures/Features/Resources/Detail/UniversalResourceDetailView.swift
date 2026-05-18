import SwiftUI
import RuulCore
import RuulUI

/// Universal resource detail — same clean frame for every `ResourceType`.
///
/// Layout (single column, no per-type dispatch):
///   1. Attention card     — `DetailAttentionView` when actions pending
///   2. Icon hero          — chrome symbol + title + subtitle
///   3. INFORMACIÓN section — type-aware key facts (status, date, money…)
///   4. Description        — capability-gated prose
///   5. Location           — capability-gated map card
///   6. Asset sections     — Custody / Ownership / Maintenance / Bookings
///                          (only when resourceType == .asset)
///   7. RSVP / CheckIn / Money / Rules / ResourcesUsed / Activity
///                         — existing capability section views
///   8. Settings           — manage capabilities + archive accordion
///   9. Sticky CTA         — `ResourcePrimaryCTA` over the scroll
///  10. Toolbar            — close (xmark) + ⋯ secondary menu
///
/// The cover hero / ambient palette / rounded panel / quick-fact pills
/// are intentionally gone — the user asked for "una página universal sin
/// importar el resource type" matching the clean look that fund / space /
/// right had as minimal scaffolds. Per-type detail views were deleted
/// alongside this rewrite; everything renders through `body` below.
@MainActor
public struct UniversalResourceDetailView: View {
    @Environment(AppState.self) private var app
    @Environment(\.eventInteractor) private var eventInteractor
    @Environment(\.eventDetailPresenter) private var presenter
    @Environment(\.dismiss) private var dismiss

    public let context: ResourceDetailContext

    /// Active right-lifecycle sheet (transfer/delegate/revoke/...).
    /// `nil` means no sheet is presented. The dispatch in
    /// `dispatchSecondary(_:)` writes this; the body's `.sheet(item:)`
    /// modifier renders the corresponding `RightActionSheet`.
    @State private var activeRightAction: RightActionSheet.Action?
    /// Toggles `EditRightSheet` (slice 13). Separate from
    /// `activeRightAction` because the edit form has its own field
    /// set (~10 knobs) too divergent to share the lifecycle sheet's
    /// shape. Dispatched from the ⋯ menu's `.editDetails` when the
    /// resource is a right.
    @State private var showEditRight: Bool = false

    /// Active fund action sheet. `nil` means no sheet is presented.
    /// `dispatchPrimary` (Aportar) and `dispatchSecondary` (Registrar
    /// gasto / Bloquear / Desbloquear) write this; the body renders
    /// the matching SwiftUI sheet bound to it.
    @State private var activeFundSheet: FundSheetSelection?

    /// Selected tab in the segmented control. Always starts at `.overview`
    /// when the detail is freshly presented — no persistence across
    /// presentations (Pass 1 default; revisit in Pass 2 per founder feedback).
    @State private var selectedTab: ResourceDetailTab = .overview

    public init(context: ResourceDetailContext) {
        self.context = context
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RuulSpacing.xl) {
                liveBanner
                if !context.attentionActions.isEmpty {
                    DetailAttentionView(context: context)
                }
                hero
                informationSection

                RuulSegmentedControl(
                    selection: $selectedTab,
                    segments: ResourceDetailTab.allCases.map { ($0, $0.label) }
                )
                .padding(.top, RuulSpacing.xs)

                tabContent
            }
            .padding(.horizontal, RuulSpacing.lg)
            .padding(.vertical, RuulSpacing.lg)
        }
        .scrollIndicators(.hidden)
        .background(Color.ruulBackground.ignoresSafeArea())
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ResourcePrimaryCTA(action: primaryAction, onTap: dispatchPrimary)
        }
        .ruulSheetToolbar(context.displayName, onClose: context.onDismiss)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if !secondaryActions.isEmpty {
                    Menu {
                        ForEach(secondaryActions) { action in
                            Button(role: action.isDestructive ? .destructive : nil) {
                                dispatchSecondary(action)
                            } label: {
                                Label(action.label, systemImage: action.symbol)
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .ruulTextStyle(RuulTypography.subheadSemibold)
                            .foregroundStyle(Color.ruulTextPrimary)
                    }
                }
            }
        }
        .sheet(item: $activeRightAction) { action in
            RightActionSheet(
                action: action,
                rightId: context.resource.id,
                members: Array(context.memberDirectory.values),
                holderMemberId: context.resource.rightHolderMemberId,
                onCompleted: {
                    // The right's resource row mutated server-side
                    // (status/metadata). The outer detail screen owns
                    // its own refresh — the simplest signal is to
                    // dismiss so the caller re-fetches on present.
                    if let onDismiss = context.onDismiss {
                        onDismiss()
                    } else {
                        dismiss()
                    }
                }
            )
            .environment(app)
        }
        .sheet(isPresented: $showEditRight) {
            EditRightSheet(
                rightId: context.resource.id,
                metadata: context.resource.metadata,
                onCompleted: {
                    // Mirror RightActionSheet's dismiss pattern: the
                    // metadata mutated, so dismiss the detail so the
                    // caller re-fetches on next present. A future
                    // slice could refresh in place via a coordinator
                    // callback if the dismiss feels heavy-handed.
                    if let onDismiss = context.onDismiss {
                        onDismiss()
                    } else {
                        dismiss()
                    }
                }
            )
            .environment(app)
        }
        // Fund action sheets. `.contribute` is the primary CTA
        // ("Aportar"); `.recordExpense` lives in the ⋯ menu for admins.
        // Lock/unlock are surfaced directly in MoneySectionView's
        // fundLockRow, NOT here — keeping the lock controls grouped
        // with the dinero card per upstream's choice.
        .sheet(item: $activeFundSheet) { selection in
            fundSheet(for: selection)
                .environment(app)
        }
    }

    @ViewBuilder
    private func fundSheet(for selection: FundSheetSelection) -> some View {
        switch selection {
        case .contribute:
            ContributeToFundSheet(
                fundId: context.resource.id,
                fundName: context.displayName,
                currency: fundCurrency,
                onDidContribute: { onFundActionSucceeded() }
            )
        case .recordExpense:
            RecordExpenseFromFundSheet(
                fundId: context.resource.id,
                fundName: context.displayName,
                currency: fundCurrency,
                members: Array(context.memberDirectory.values),
                onDidRecord: { onFundActionSucceeded() }
            )
        }
    }

    /// Fan-out after a successful fund action. Calls
    /// `context.onResourceMutated` so the parent coordinator re-fetches
    /// the resource row. FundBalanceSection observes the new row's
    /// `updatedAt` via `.task(id: fund.updatedAt)` and re-reads the
    /// projection automatically — one signal, single source of truth.
    private func onFundActionSucceeded() {
        Task { await context.onResourceMutated() }
    }

    /// Currency for fund operations. Reads `resources.metadata.currency`,
    /// falling back to MXN (matches `create_fund`'s default in mig 00139).
    private var fundCurrency: String {
        context.resource.metadata["currency"]?.stringValue ?? "MXN"
    }

    // MARK: - Live banner (UXJourney P1)
    //
    // Para eventos sucediendo justo ahora (event.startsAt <= now <
    // event.resolvedEndsAt, status != closed/cancelled). Sin esto, el
    // detail no comunicaba el estado live — el usuario tenía que
    // adivinar por la fecha. Ahora aparece arriba con un pulse animation
    // hasta que el evento termina.

    @ViewBuilder
    private var liveBanner: some View {
        if let interactor = eventInteractor, interactor.event.isLive {
            // Show one-tap "Llegué" inline cuando el viewer puede self-
            // check-in: RSVP'd going + no checked-in todavía + capability
            // habilitada. Cierra el loop más rápido que abrir el card
            // de la CheckInSection.
            let canSelfCheckIn = context.enabledCapabilities.contains("check_in")
                && (interactor.myRSVP?.status == .going)
                && (interactor.myRSVP?.isCheckedIn == false)
            LiveEventBanner(
                eventTitle: interactor.event.title,
                onSelfCheckIn: canSelfCheckIn ? {
                    Task { await interactor.selfCheckIn(locationVerified: false) }
                } : nil
            )
        }
    }

    // MARK: - Hero (Fund-style icon badge + title + subtitle)

    private var hero: some View {
        HStack(spacing: RuulSpacing.md) {
            Image(systemName: chrome.symbol)
                .font(.system(size: 32))
                .foregroundStyle(chrome.semanticColor)
                .frame(width: 60, height: 60)
                .background(
                    chrome.semanticColor.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: RuulRadius.md)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(context.displayName)
                    .ruulTextStyle(RuulTypography.title)
                    .foregroundStyle(Color.ruulTextPrimary)
                    .lineLimit(2)
                if let subtitle = heroSubtitle {
                    Text(subtitle)
                        .ruulTextStyle(RuulTypography.caption)
                        .foregroundStyle(Color.ruulTextSecondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// Per-type sub-line under the title. Reads `humanLabel` from the
    /// ResourceType enum (single source of truth for type display copy).
    /// Falls through with status when the resource isn't in its default
    /// "active" state.
    private var heroSubtitle: String? {
        if case .unknown = context.resource.resourceType { return nil }
        let typeLabel = context.resource.resourceType.humanLabel
        if context.resource.status.lowercased() != "active",
           !context.resource.status.isEmpty {
            return "\(typeLabel) · \(context.resource.status.capitalized)"
        }
        return typeLabel
    }

    private var chrome: ResourceTypeChrome {
        ResourceTypeChrome.resolve(context.resource.resourceType)
    }

    // MARK: - INFORMACIÓN section (type-aware key facts)

    @ViewBuilder
    private var informationSection: some View {
        let facts = infoRows
        if !facts.isEmpty {
            RuulInfoCard("INFORMACIÓN") {
                ForEach(Array(facts.enumerated()), id: \.offset) { idx, fact in
                    RuulInfoRow(label: fact.label, value: fact.value)
                    if idx < facts.count - 1 {
                        RuulInfoDivider()
                    }
                }
            }
        }
    }

    /// Type-aware key facts shown in the INFORMACIÓN card. The set is
    /// intentionally small (3-6 rows) so the card stays scannable; deeper
    /// facets (custody, ledger, ...) live in their own sections below.
    private var infoRows: [(label: String, value: String)] {
        var rows: [(String, String)] = []

        if let date = parseStartsAt() {
            rows.append(("Fecha", date.ruulFullDate))
            let start = date.ruulShortTime
            if let end = parseEndsAt() {
                rows.append(("Hora", "\(start) – \(end.ruulShortTime)"))
            } else {
                rows.append(("Hora", start))
            }
        }
        if let host = hostRow {
            rows.append(("Anfitrión", host.displayName))
        }
        rows.append(contentsOf: typeSpecificRows)
        rows.append(("Creado", context.resource.createdAt.ruulShortDate))
        return rows
    }

    /// Per-type facts that don't fit the generic date/host/created
    /// shape. Sourced from `ResourceInfoRegistry` — each type registers
    /// its own provider in its section file. Per ontology constitution
    /// Rule 6 ("UI siempre capability-driven; cero switch resource_type
    /// en routing"). Returns empty for types without a registered
    /// provider (event, slot, unknown today).
    private var typeSpecificRows: [(label: String, value: String)] {
        ResourceInfoRegistry.shared.rows(for: context).map { ($0.label, $0.value) }
    }

    private var hostRow: MemberWithProfile? {
        guard let id = uuidFromMeta("host_id") else { return nil }
        return context.memberDirectory[id]
    }

    /// Reads a `metadata.<key>` string and parses it as UUID. Used by
    /// every "look up this member from the metadata shortcut" row in the
    /// INFORMACIÓN card. `memberDirectory` is keyed by `userId` for events
    /// (host) but by `group_members.id` for assets (custodian/owner/holder)
    /// — caller decides which dictionary to query after this helper hands
    /// back the parsed UUID.
    private func uuidFromMeta(_ key: String) -> UUID? {
        guard let raw = context.resource.metadata[key]?.stringValue,
              !raw.isEmpty else { return nil }
        return UUID(uuidString: raw)
    }

    // MARK: - Date parsing helpers

    private func parseStartsAt() -> Date? {
        if case .string(let iso)? = context.resource.metadata["starts_at"] {
            return Self.parseISO(iso)
        }
        return nil
    }

    /// Prefer explicit `ends_at` from metadata; fall back to
    /// `starts_at + duration_minutes` so guests still see a time range
    /// when the server only stored a duration.
    private func parseEndsAt() -> Date? {
        if case .string(let iso)? = context.resource.metadata["ends_at"],
           let date = Self.parseISO(iso) {
            return date
        }
        guard let start = parseStartsAt(),
              case .int(let minutes)? = context.resource.metadata["duration_minutes"],
              minutes > 0 else { return nil }
        return start.addingTimeInterval(TimeInterval(minutes * 60))
    }

    /// Tries both ISO-8601 shapes the backend may emit: with and without
    /// fractional seconds. The dual-write trigger writes the fractional
    /// form (`to_jsonb(timestamptz)`), but some older rows / RPC payloads
    /// land without them — so accept both rather than silently dropping
    /// the date on parse failure.
    private nonisolated static func parseISO(_ iso: String) -> Date? {
        if let date = isoFrac.date(from: iso) { return date }
        return isoPlain.date(from: iso)
    }

    private nonisolated(unsafe) static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private nonisolated(unsafe) static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    // MARK: - Tab dispatch

    /// All catalog sections (canonical + bespoke + stubs) that
    /// (a) gate-in for the current enabled capabilities and context,
    /// AND (b) belong to the supplied tab. Sorted by `priority` ascending.
    private func sectionsForTab(_ tab: ResourceDetailTab) -> [CapabilitySection] {
        CapabilitySectionCatalog.shared
            .sectionsFor(context: context)
            .filter { $0.tabId == tab.id }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .overview:    overviewContent
        case .activity:    activityContent
        case .rules:       rulesContent
        case .connections: connectionsContent
        case .governance:  governanceContent
        }
    }

    @ViewBuilder
    private var overviewContent: some View {
        let sections = sectionsForTab(.overview)
        if sections.isEmpty {
            emptyTab(
                symbol: ResourceDetailTab.overview.symbol,
                message: "No hay información para mostrar todavía."
            )
        } else {
            ForEach(sections, id: \.id) { section in
                section.render(context)
            }
        }
    }

    @ViewBuilder
    private var activityContent: some View {
        let sections = sectionsForTab(.activity)
        if sections.isEmpty {
            emptyTab(
                symbol: ResourceDetailTab.activity.symbol,
                message: "Aún no hay actividad. Cuando alguien interactúe con este recurso, lo verás aquí."
            )
        } else {
            ForEach(sections, id: \.id) { section in
                section.render(context)
            }
        }
    }

    @ViewBuilder
    private var rulesContent: some View {
        let sections = sectionsForTab(.rules)
        if sections.isEmpty {
            emptyTab(
                symbol: ResourceDetailTab.rules.symbol,
                message: "Sin reglas propias. Las reglas del grupo aplican aquí por defecto."
            )
        } else {
            ForEach(sections, id: \.id) { section in
                section.render(context)
            }
        }
    }

    @ViewBuilder
    private var connectionsContent: some View {
        let sections = sectionsForTab(.connections)
        if sections.isEmpty {
            emptyTab(
                symbol: ResourceDetailTab.connections.symbol,
                message: "Aún no hay recursos vinculados. Las conexiones aparecerán aquí cuando se agreguen."
            )
        } else {
            ForEach(sections, id: \.id) { section in
                section.render(context)
            }
        }
    }

    @ViewBuilder
    private var governanceContent: some View {
        GovernanceTabView(resource: context.resource, onArchive: nil)
    }

    @ViewBuilder
    private func emptyTab(symbol: String, message: String) -> some View {
        VStack(spacing: RuulSpacing.sm) {
            Image(systemName: symbol)
                .ruulTextStyle(RuulTypography.title)
                .foregroundStyle(Color.ruulTextTertiary)
            Text(message)
                .ruulTextStyle(RuulTypography.body)
                .foregroundStyle(Color.ruulTextSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(RuulSpacing.xl)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: RuulRadius.lg))
    }

    /// Stub capability sections sourced from `CapabilitySectionCatalog`.
    /// Each section file declares `static let definition = CapabilitySection(
    /// id, priority, isEnabledFor, render)` and registers itself once at
    /// catalog boot. Filter to the stubs by id-set so we don't re-render
    /// dynamic sections (rsvp, check_in, money, rules, …) that already
    /// rendered via `dynamicSectionIds` above.
    ///
    /// Asset/space still skip the universal `booking` + `valuation` stubs
    /// because the bespoke `asset.bookings` / `asset.ownership` /
    /// `space.bookings` sections cover the same caps with type-aware
    /// renderers. Once stub rendering is rebalanced (some stubs deserve
    /// to render near their semantic priority instead of at the bottom),
    /// this whole helper collapses into the main catalog call.
    @ViewBuilder
    private var stubCapabilitySections: some View {
        let isAsset = context.resource.resourceType == .asset
        let isSpace = context.resource.resourceType == .space
        let sections = CapabilitySectionCatalog.shared
            .sectionsFor(context: context)
            .filter { Self.stubSectionIds.contains($0.id) }
            .filter { section in
                // Universal `booking` + `valuation` stubs are duplicated
                // by the bespoke `asset.bookings`/`asset.ownership` /
                // `space.bookings` sections. Skip the stub when a bespoke
                // already handles this resource.
                if section.id == "booking", isAsset || isSpace { return false }
                if section.id == "valuation", isAsset { return false }
                return true
            }
        ForEach(sections, id: \.id) { section in
            section.render(context)
        }
    }

    /// Sections from the catalog whose id is in `ids`. Filtered by both
    /// `isEnabledFor(caps)` and `isVisibleFor(context)` predicates, then
    /// sorted by priority. SwiftUI @Environment values (eventInteractor,
    /// eventDetailPresenter) propagate through the ForEach body, so
    /// sections that read them internally (RSVP, CheckIn, HostActions)
    /// work transparently.
    @ViewBuilder
    private func catalogSections(idIn ids: Set<String>) -> some View {
        let sections = CapabilitySectionCatalog.shared
            .sectionsFor(context: context)
            .filter { ids.contains($0.id) }
        ForEach(sections, id: \.id) { section in
            section.render(context)
        }
    }

    /// All dynamic catalog sections rendered between the hero/info card
    /// and the stub overflow. Priority-sorted so the natural top-to-bottom
    /// order is: schedule (100) → description (150) → asset.*/space.*/
    /// fund.balance (160-167) → rsvp (200) → check_in (250) →
    /// host_actions (350) → money (400) → rotation (600) → rules (800)
    /// → resource_links (850) → activity (900). Each section gates its
    /// own empty/missing-data state and contributes nothing when not
    /// applicable. Schedule/host_actions/rotation were registered in the
    /// catalog but never consumed; this is the fix that surfaces them.
    private static let dynamicSectionIds: Set<String> = [
        "schedule",
        "description", "location",
        "asset.custody", "asset.ownership", "asset.maintenance", "asset.bookings",
        "space.capacity", "space.occupancy", "space.bookings",
        "fund.balance",
        "rsvp", "check_in", "host_actions", "money", "rotation", "rules",
        "resource_links",
        "activity",
    ]

    /// Ids of catalog sections rendered here. The complement (canonical
    /// ids like `rsvp`, `check_in`, `money`, `rules`, `schedule`,
    /// `location`, `description`, `activity`, `host_actions`,
    /// `rotation`, `capacity_progress`) is rendered inline above and
    /// must NOT appear in this set or the page renders twice.
    private static let stubSectionIds: Set<String> = [
        "status", "recurrence", "deadline", "expiration",
        "participants", "attendance", "guest_access", "assignment",
        "booking", "valuation", "inventory", "access",
        "delegation", "voting", "approval", "appeal",
        "consequence", "swap", "cancellation", "reminder", "history",
    ]

    // MARK: - Resolver-driven actions

    private var primaryAction: PrimaryAction {
        let rsvpStatus = eventInteractor?.myRSVP?.status
        let eventStatus = eventInteractor?.event.status

        return app.capabilityResolver.primaryAction(
            for: context.resource,
            viewerPermissions: viewerPermissions(),
            viewerIsEventHost: viewerIsEventHost(),
            rsvpStatus: rsvpStatus,
            eventStatus: eventStatus,
            enabledCapabilities: context.enabledCapabilities,
            // Slice 14: needed for right's "Ejercer" primary CTA —
            // resolver checks holder_user_id / delegate_user_id against
            // the viewer to decide whether to render the sticky button.
            viewerUserId: context.currentUserId
        )
    }

    private var secondaryActions: [SecondaryAction] {
        app.capabilityResolver.secondaryActions(
            for: context.resource,
            viewerPermissions: viewerPermissions(),
            viewerIsEventHost: viewerIsEventHost(),
            viewerCanIssueManualFine: presenter?.canIssueManualFine ?? false,
            enabledCapabilities: context.enabledCapabilities,
            viewerUserId: context.currentUserId
        )
    }

    /// Sprint E (V16 fix): replaces the previous `viewerRole()` lossy
    /// projection that collapsed N member.rawRoles into 1 MemberRole
    /// enum (dropping `admin` + every custom role like `seat_owner`,
    /// `treasurer_aux`). Now: walks the role catalog and returns the
    /// UNION of permissions granted by all roles the viewer holds.
    /// Local sync read (no I/O); server is still authoritative on
    /// actions via the RPC gates.
    private func viewerPermissions() -> Set<Permission> {
        guard let userId = context.currentUserId,
              let mwp = context.memberDirectory[userId] else {
            return []
        }
        let catalog = context.group.effectiveRoles
        var perms: Set<Permission> = []
        for raw in mwp.member.rawRoles {
            if let def = catalog[raw] {
                for p in def.permissions { perms.insert(p) }
            }
        }
        return perms
    }

    /// Per-event host check (contextual assignment, NOT a permission).
    /// Read from the event interactor when present; resources that are
    /// not events return false unconditionally.
    private func viewerIsEventHost() -> Bool {
        guard let interactor = eventInteractor,
              let userId = context.currentUserId else { return false }
        return interactor.event.hostId == userId
    }

    // MARK: - Dispatch

    private func dispatchPrimary() {
        switch primaryAction.kind {
        case .rsvpConfirm:
            Task { await eventInteractor?.setRSVP(.going, plusOnes: 0, reason: nil) }
        case .rsvpCancel:
            presenter?.onPresentCancelAttendanceSheet()
        case .viewHostActions:
            // Pass 1 of v2: route to closeEvent as stand-in for full host actions sheet.
            presenter?.onPresentCloseEventSheet()
        case .exerciseRight:
            // Slice 14: route through the same activeRightAction sheet
            // pipeline used by the ⋯ menu so success behavior (atom
            // emit + dismiss) is uniform across both surfaces.
            activeRightAction = .exercise
        case .openContribute:
            // Fund → ContributeToFundSheet (mig 00202 fund_contribute).
            // Earlier upstream wired this to `context.onPresentLedger()`
            // which opened the generic ledger composer — usable but not
            // fund-specific. The dedicated sheet only asks for the two
            // fields fund_contribute needs (amount + optional note),
            // matching the wizard ergonomics every other type uses.
            // Refresh signal travels via `context.onResourceMutated`
            // which the sheet calls on success.
            activeFundSheet = .contribute
        case .openBooking, .viewClosed, .none:
            break
        }
    }

    private func dispatchSecondary(_ action: SecondaryAction) {
        switch action.kind {
        case .editDetails:
            // Slice 13: rights have a dedicated EditRightSheet wrapping
            // update_right_metadata (mig 00199). Other resource types
            // still route through the generic onPresentEditResource
            // callback (no-op for many today; per-type sheets land as
            // each type's edit surface is built).
            if context.resource.resourceType == .right {
                showEditRight = true
            } else {
                context.onPresentEditResource()
            }
        case .addToCalendar:
            // P1 wire: el presenter ahora invoca CalendarExportService
            // directamente (sin pasar por ShareEventSheet). EventKit
            // pide authorization en primer uso.
            presenter?.onAddToCalendar()
        case .share:
            presenter?.onPresentShareSheet()
        case .generateWalletPass:
            presenter?.onAddToWallet()
        case .remindAttendees:
            presenter?.onPresentRemindAttendeesSheet()
        case .closeEvent:
            presenter?.onPresentCloseEventSheet()
        case .cancelEvent:
            presenter?.onPresentCancelEventSheet()
        case .reopenEvent:
            // Mig 00295: idempotent server-side; no confirmation sheet
            // (the action is itself reversible by closing again).
            if let eventInteractor {
                Task { await eventInteractor.reopenEvent() }
            }
        case .openLedger:
            context.onPresentLedger()
        case .issueManualFine:
            presenter?.onPresentManualFineSheet()
        case .openRules:
            context.onPresentRules()
        case .enableCapability:
            // Post-Pass-1 dead route — the Governance tab is the
            // canonical entry point. The resolver no longer emits this
            // kind, so the case stays only for switch exhaustiveness.
            break
        case .archive:
            break  // no archive endpoint yet
        // Right lifecycle (slice 6). Setting activeRightAction triggers
        // the `.sheet(item:)` above which renders the matching
        // RightActionSheet variant.
        case .exerciseRight:  activeRightAction = .exercise
        case .transferRight:  activeRightAction = .transfer
        case .delegateRight:  activeRightAction = .delegate
        case .revokeRight:    activeRightAction = .revoke
        case .suspendRight:   activeRightAction = .suspend
        case .restoreRight:   activeRightAction = .restore
        // Fund lifecycle. Setting activeFundSheet triggers the
        // `.sheet(item:)` above which renders the matching fund sheet.
        // Lock/unlock are NOT here — they live on MoneySectionView's
        // fundLockRow (gated by viewerIsAdmin + resource.type=fund),
        // keeping every fund admin control grouped with the dinero card.
        case .recordExpenseFromFund: activeFundSheet = .recordExpense
        }
    }
}

/// Active fund sheet selector. Identifiable so it can drive
/// `.sheet(item:)` directly.
enum FundSheetSelection: Identifiable {
    case contribute
    case recordExpense
    var id: Self { self }
}

/// "EN VIVO" banner que aparece arriba del EventDetail mientras el
/// evento sucede (startsAt <= now < endsAt). Pulse animation suave
/// honra accessibilityReduceMotion. Cuando `onSelfCheckIn` está set,
/// muestra un botón inline "Llegué" como atajo al check-in sin
/// scroll a la CheckInSection.
private struct LiveEventBanner: View {
    let eventTitle: String
    let onSelfCheckIn: (() -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false
    @State private var checkInTriggered = 0

    var body: some View {
        HStack(spacing: RuulSpacing.sm) {
            Circle()
                .fill(Color.ruulNegative)
                .frame(width: 10, height: 10)
                .scaleEffect(pulse ? 1.3 : 1.0)
                .opacity(pulse ? 0.6 : 1.0)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("EN VIVO")
                    .ruulTextStyle(RuulTypography.sectionLabel)
                    .foregroundStyle(Color.ruulNegative)
                Text("Sucediendo ahora")
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextSecondary)
            }
            Spacer(minLength: 0)
            if let onSelfCheckIn {
                Button {
                    checkInTriggered &+= 1
                    onSelfCheckIn()
                } label: {
                    Label("Llegué", systemImage: "checkmark.circle.fill")
                        .ruulTextStyle(RuulTypography.subheadSemibold)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.ruulPositive)
                .controlSize(.small)
                .accessibilityLabel("Marcar que llegué al evento")
            }
        }
        .padding(.horizontal, RuulSpacing.md)
        .padding(.vertical, RuulSpacing.sm)
        .background(
            Color.ruulNegative.opacity(0.08),
            in: RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous)
                .stroke(Color.ruulNegative.opacity(0.25), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(eventTitle), evento en vivo")
        .sensoryFeedback(.success, trigger: checkInTriggered)
        .onAppear {
            guard !reduceMotion else { pulse = true; return }
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}

#if DEBUG
#Preview {
    Text("UniversalResourceDetailView needs AppState + EventInteractor environment to render. See EventDetailHost.swift for full wiring.")
        .padding()
}
#endif
