import SwiftUI
import RuulCore
import RuulUI

/// Universal resource detail — same shell for every `ResourceType`.
///
/// Layout (4-tab segmented, capability-driven section catalog):
///   - Attention card       — `DetailAttentionView` when actions pending
///   - Hero                 — `ResourceTypeChrome` symbol + title + subtitle
///   - INFORMACIÓN card     — `ResourceInfoRegistry` providers per type
///   - Tab bar (4)          — overview / activity / rules / connections
///   - Tab content          — `CapabilitySectionCatalog.sectionsFor(context:)`
///                            filtered by `isEnabledFor(caps)` and
///                            `isVisibleFor(context)`, sorted by priority
///   - Sticky CTA           — `ResourcePrimaryCTA` from `primaryAction`
///   - Toolbar              — close (xmark) + ⋯ menu from `secondaryActions`
///
/// Pass-1 cleanup (commits 4599a40 / 73c8f36 / b55b739 / bcfb763)
/// deleted the per-type detail views, the Settings tab, the
/// `Manage capabilities` sheet, and the dead `stubCapabilitySections`
/// helpers. Sections are now declared by `CapabilitySectionView` types
/// that register themselves with `CapabilitySectionCatalog.shared` and
/// gate via `isEnabledFor(caps:)` / `isVisibleFor(context:)`. Adding a
/// new section means writing a `SectionView` + registering — no edits
/// here.
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

    // MARK: Intent-driven toolbar state (Phase 1: asset + fund)
    //
    // The toolbar `+` / ⚙️ for asset and fund resources is wired to
    // `ResourceIntentRegistry`. Tapping an intent sets one of these
    // states — the body's sheet / confirmationDialog modifiers render
    // the matching surface and call the matching RPC on submit.
    //
    // TODO Phase 2: migrate event/right/slot/space from
    // CapabilityResolver.secondaryActions to the registry path; this
    // state set covers asset+fund destinations only.

    /// Intent whose action requires a sheet (transfer picker, checkout,
    /// valuation, log maintenance, …). Bound to `.sheet(item:)`.
    @State private var pendingIntentSheet: IdentifiableIntent?
    /// Intent whose action requires a destructive confirmation (release
    /// custody, mark returned, return to group, unlock fund, archive).
    @State private var pendingConfirmation: ConfirmationKind?
    /// Last RPC error surfaced to the user via a transient banner.
    @State private var intentError: String?

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
                    segments: visibleTabs.map { ($0, $0.label) }
                )
                .padding(.top, RuulSpacing.xs)
                .onChange(of: visibleTabs) { _, newTabs in
                    // If the user is on a tab that just disappeared
                    // (rare — caps don't usually change mid-view), fall
                    // back to .overview rather than render an empty
                    // segmented selection.
                    if !newTabs.contains(selectedTab) {
                        selectedTab = .overview
                    }
                }

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
            // ToolbarItemGroup keeps the two trailing buttons rendered as
            // a single block in NavigationStack. Two separate
            // `ToolbarItem(placement: .topBarTrailing)` instances collide
            // intermittently on iOS 26 (devicelogs from 2026-05-18:
            // second item disappears under certain modal-cover stacking).
            // The group form is the canonical recipe per Apple's
            // Toolbars HIG sample code.
            ToolbarItemGroup(placement: .topBarTrailing) {
                // `+` menu: everything the viewer can DO with this
                // resource right now. Sourced from `ResourceIntentRegistry`
                // for asset+fund (Phase 1); falls back to the legacy
                // `CapabilityResolver.secondaryActions` for other types.
                if !plusMenuIntents.isEmpty || !plusMenuLegacyActions.isEmpty {
                    Menu {
                        plusMenuContents
                    } label: {
                        Image(systemName: "plus")
                            .ruulTextStyle(RuulTypography.subheadSemibold)
                            .foregroundStyle(Color.ruulTextPrimary)
                            .accessibilityLabel("Acciones del recurso")
                    }
                }
                // ⚙️ menu: resource configuration (Editar detalles +
                // Archivar). Intentionally minimal — further config goes
                // into an "Avanzado" sub-sheet per doctrine 2026-05-18.
                if !gearMenuIntents.isEmpty || !gearMenuLegacyActions.isEmpty {
                    Menu {
                        gearMenuContents
                    } label: {
                        Image(systemName: "gearshape")
                            .ruulTextStyle(RuulTypography.subheadSemibold)
                            .foregroundStyle(Color.ruulTextPrimary)
                            .accessibilityLabel("Ajustes del recurso")
                    }
                }
            }
        }
        // Intent-driven sheets (asset + fund Phase 1). One `.sheet(item:)`
        // dispatches by `pendingIntentSheet.intent.destination`, so adding
        // a new sheet destination is a single switch case below.
        .sheet(item: $pendingIntentSheet) { wrapped in
            sheetForIntent(wrapped.intent)
                .environment(app)
        }
        // Intent-driven confirmations. Single `.confirmationDialog` keyed
        // by `pendingConfirmation`. Each case maps to its own title +
        // destructive CTA + async RPC call.
        .confirmationDialog(
            pendingConfirmation?.title ?? "",
            isPresented: confirmationBinding,
            titleVisibility: .visible
        ) {
            if let kind = pendingConfirmation {
                Button(kind.confirmCTA, role: .destructive) {
                    Task { await runConfirmedAction(kind) }
                }
                Button("Cancelar", role: .cancel) {
                    pendingConfirmation = nil
                }
            }
        } message: {
            if let kind = pendingConfirmation {
                Text(kind.message)
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
        // "Creado" alone is noise — a section just for the create date
        // adds chrome without earning it. Render the card only when at
        // least one other fact is present; Creado then rides along as
        // the tail row.
        let hasMeaningfulFact = facts.contains { $0.label != "Creado" }
        if hasMeaningfulFact {
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

    /// Tabs the segmented control actually renders for the current
    /// resource. `overview / rules / activity` are always present; the
    /// other three are content-gated — they appear only when at least
    /// one capability-driven section routes into them. Per V2 Human-Layer
    /// doctrine §H.2: Gente/Dinero/Relacionado disappear silently for
    /// resources with no capability driving them, so the typical
    /// resource shows 3-5 tabs instead of all 6.
    private var visibleTabs: [ResourceDetailTab] {
        ResourceDetailTab.allCases.filter { tab in
            switch tab {
            case .overview, .rules, .activity:
                return true
            case .people, .money, .connections:
                return !sectionsForTab(tab).isEmpty
            }
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .overview:    overviewContent
        case .people:      peopleContent
        case .money:       moneyContent
        case .activity:    activityContent
        case .rules:       rulesContent
        case .connections: connectionsContent
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
        // V2 Slice 3B: universal quiet bar at the bottom of every
        // Overview. Renders 6 ambient verbs (view_history, add_rules,
        // track_money, share_resource, edit_resource, archive_resource)
        // filtered by the intent registry's `available(in:)` predicate
        // — capability / permission / type gates apply, so a verb that
        // doesn't match the current resource silently disappears. The
        // bar is a quiet ambient surface; primary actions still live in
        // the toolbar `+` menu and the sticky CTA.
        quietActionBar
    }

    @ViewBuilder
    private var peopleContent: some View {
        // People tab is content-gated by `visibleTabs` — it never
        // renders when sections are empty, so no empty-state needed.
        ForEach(sectionsForTab(.people), id: \.id) { section in
            section.render(context)
        }
    }

    @ViewBuilder
    private var moneyContent: some View {
        // Money tab is content-gated by `visibleTabs` — it never
        // renders when sections are empty, so no empty-state needed.
        ForEach(sectionsForTab(.money), id: \.id) { section in
            section.render(context)
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
        // Relacionado tab is content-gated by `visibleTabs` — it never
        // renders when sections are empty, so no empty-state needed.
        ForEach(sectionsForTab(.connections), id: \.id) { section in
            section.render(context)
        }
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

    /// Toolbar split: actions ("+" button) vs configuration ("⚙️"
    /// button). Today only editDetails + archive are configuration —
    /// every other kind is something the user DOES with the resource.
    private static let settingsKinds: Set<SecondaryAction.Kind> = [
        .editDetails, .archive
    ]

    private var actionItems: [SecondaryAction] {
        secondaryActions.filter { !Self.settingsKinds.contains($0.kind) }
    }

    private var settingsItems: [SecondaryAction] {
        secondaryActions.filter { Self.settingsKinds.contains($0.kind) }
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

    // MARK: - Intent-driven toolbar (Phase 1: asset + fund)
    //
    // For asset + fund the toolbar reads from `ResourceIntentRegistry`.
    // For other types we keep `secondaryActions` / `dispatchSecondary`
    // wired above until Phase 2 migrates them.

    /// True when this resource type's toolbar is intent-driven (Phase 1).
    /// TODO Phase 2: extend to .right, .event, .slot, .space and remove
    /// this branch.
    private var usesIntentRegistry: Bool {
        switch context.resource.resourceType {
        case .asset, .fund: return true
        default: return false
        }
    }

    /// Context the registry needs to filter intents.
    private var intentContext: ResourceIntentContext {
        ResourceIntentContext(
            resource: context.resource,
            group: context.group,
            viewerUserId: context.currentUserId,
            viewerPermissions: viewerPermissions(),
            enabledCapabilities: context.enabledCapabilities
        )
    }

    /// All intents the registry says are valid right now for this
    /// resource + viewer. Empty when `usesIntentRegistry == false`.
    private var availableIntents: [ResourceIntent] {
        guard usesIntentRegistry else { return [] }
        return DefaultResourceIntentRegistry.v1.available(in: intentContext)
    }

    // MARK: - Universal quiet bar (V2 Slice 3B)

    /// Verbs the quiet bar surfaces below the Overview sections, in
    /// display order. Each id must resolve in `DefaultResourceIntentRegistry`;
    /// any that the registry's `available(in:)` predicate filters out
    /// for the current resource / viewer / capability state disappears
    /// from the bar silently (no greyed-out chrome).
    ///
    /// `link_resource` is intentionally absent until the link sheet is
    /// generalized to non-event resources (today `LinkResourcePickerSheet`
    /// requires an `eventId`). V2 §B.6 captures the follow-up.
    private static let quietBarIntentIDs: [String] = [
        "view_history",
        "add_rules",
        "track_money",
        "share_resource",
        "edit_resource",
        "archive_resource"
    ]

    /// Quiet bar actions filtered by the registry's universal predicate.
    /// Unlike the `+` / ⚙️ menus, this bypasses `usesIntentRegistry` —
    /// the quiet bar is universal across all 6 resource types, not
    /// Phase-1 (asset+fund) only.
    private var quietActions: [RuulQuietActionBar.Action] {
        let availableIDs = Set(
            DefaultResourceIntentRegistry.v1
                .available(in: intentContext)
                .map(\.id)
        )
        return Self.quietBarIntentIDs.compactMap { id in
            guard availableIDs.contains(id),
                  let intent = DefaultResourceIntentRegistry.v1.intent(id: id)
            else { return nil }
            return RuulQuietActionBar.Action(
                id: intent.id,
                label: intent.humanLabel,
                symbol: intent.icon,
                isDestructive: intent.isDestructive,
                perform: { dispatchIntent(intent) }
            )
        }
    }

    @ViewBuilder
    private var quietActionBar: some View {
        if !quietActions.isEmpty {
            RuulQuietActionBar(actions: quietActions)
        }
    }

    /// Intents for the `+` menu (everything that isn't a setting).
    private var plusMenuIntents: [ResourceIntent] {
        availableIntents.filter { !$0.isResourceSetting }
    }

    /// Intents for the ⚙️ menu (editDetails + archive today).
    private var gearMenuIntents: [ResourceIntent] {
        availableIntents.filter { $0.isResourceSetting }
    }

    /// Legacy `+` items for non-asset/non-fund types (Phase 2 work).
    private var plusMenuLegacyActions: [SecondaryAction] {
        usesIntentRegistry ? [] : actionItems
    }

    /// Legacy ⚙️ items for non-asset/non-fund types.
    private var gearMenuLegacyActions: [SecondaryAction] {
        usesIntentRegistry ? [] : settingsItems
    }

    /// Intents grouped + sorted for the `+` menu sectioning.
    private var groupedPlusMenuIntents: [(IntentGroup, [ResourceIntent])] {
        let buckets = Dictionary(grouping: plusMenuIntents) { $0.group }
        return IntentGroup.allCases
            .compactMap { group in
                guard let items = buckets[group], !items.isEmpty else { return nil }
                return (group, items)
            }
    }

    // MARK: - Menu contents

    /// Sections inside the `+` Menu. Intent-driven for asset+fund;
    /// flat legacy list for other types.
    @ViewBuilder
    private var plusMenuContents: some View {
        if usesIntentRegistry {
            ForEach(groupedPlusMenuIntents, id: \.0) { group, items in
                Section(group.label) {
                    ForEach(items) { intent in
                        Button(role: intent.isDestructive ? .destructive : nil) {
                            dispatchIntent(intent)
                        } label: {
                            Label(intent.humanLabel, systemImage: intent.icon)
                        }
                    }
                }
            }
        } else {
            ForEach(plusMenuLegacyActions) { action in
                Button(role: action.isDestructive ? .destructive : nil) {
                    dispatchSecondary(action)
                } label: {
                    Label(action.label, systemImage: action.symbol)
                }
            }
        }
    }

    @ViewBuilder
    private var gearMenuContents: some View {
        if usesIntentRegistry {
            ForEach(gearMenuIntents) { intent in
                Button(role: intent.isDestructive ? .destructive : nil) {
                    dispatchIntent(intent)
                } label: {
                    Label(intent.humanLabel, systemImage: intent.icon)
                }
            }
        } else {
            ForEach(gearMenuLegacyActions) { action in
                Button(role: action.isDestructive ? .destructive : nil) {
                    dispatchSecondary(action)
                } label: {
                    Label(action.label, systemImage: action.symbol)
                }
            }
        }
    }

    // MARK: - Intent dispatch

    private func dispatchIntent(_ intent: ResourceIntent) {
        switch intent.destination {
        // --- Sheet destinations ---
        case .transferAssetPicker,
             .checkoutAssetSheet,
             .recordValuationSheet,
             .logMaintenanceSheet,
             .reportDamageSheet,
             .createSlotUnderAssetSheet,
             .fundLockSheet,
             .systemShareSheet,
             .editResourceSheet,
             .custodyAssignment,
             .assignCustodyPicker,
             .valuationForm:
            pendingIntentSheet = IdentifiableIntent(intent: intent)

        case .fundContributeSheet:
            activeFundSheet = .contribute
        case .fundRecordExpenseSheet:
            activeFundSheet = .recordExpense

        // --- Confirmation destinations ---
        case .returnAssetToGroupConfirm:
            pendingConfirmation = .returnAssetToGroup
        case .releaseCustodyConfirm:
            pendingConfirmation = .releaseCustody
        case .markReturnedConfirm:
            pendingConfirmation = .markReturned
        case .fundUnlockConfirm:
            pendingConfirmation = .fundUnlock
        case .archiveResourceConfirm:
            pendingConfirmation = .archiveResource

        // --- Universal quiet-bar tab switches (V2 Slice 3B) ---
        case .historyTab:
            selectedTab = .activity
        case .moneyTab:
            selectedTab = .money
        case .ruleTemplatePicker:
            // Add Rules from the quiet bar lands on the .rules tab, same
            // entry point as PR #51 (fix(creation): route add_rules to
            // resource detail). The user picks a template / opens the
            // composer from there.
            selectedTab = .rules

        // --- Post-create navigation destinations (Phase 2 wiring) ---
        case .ledgerEntryForm,
             .reservationSetup,
             .rightCreationFlow,
             .linkPicker,
             .rsvpManager,
             .checkInLauncher,
             .slotAllocationForm,
             .rightHolderForm,
             .governanceRuleEditor,
             .childResourceWizard:
            // TODO Phase 2: wire navigation destinations from toolbar.
            // For now these only fire from the post-create screen; the
            // toolbar's intent surface doesn't expose them. `.linkPicker`
            // specifically waits on a non-event link sheet (the existing
            // LinkResourcePickerSheet is event-only — see V2 Slice 3B
            // commit).
            break
        }
    }

    // MARK: - Sheet renderer per destination

    @ViewBuilder
    private func sheetForIntent(_ intent: ResourceIntent) -> some View {
        switch intent.destination {
        case .transferAssetPicker:
            NavigationStack {
                MemberPickerSheet(
                    members: transferableMembers,
                    title: "Transferir a"
                ) { memberId in
                    Task { await transferAsset(to: memberId) }
                }
            }
        case .custodyAssignment, .assignCustodyPicker:
            NavigationStack {
                MemberPickerSheet(
                    members: assignableCustodians,
                    title: "Asignar custodia"
                ) { memberId in
                    Task { await assignCustody(to: memberId) }
                }
            }
        case .checkoutAssetSheet:
            CheckOutAssetSheet(
                asset: context.resource,
                members: Array(context.memberDirectory.values)
            ) {
                pendingIntentSheet = nil
                Task { await context.onResourceMutated() }
            }
        case .recordValuationSheet, .valuationForm:
            RecordValuationSheet(asset: context.resource) {
                pendingIntentSheet = nil
                Task { await context.onResourceMutated() }
            }
        case .logMaintenanceSheet:
            LogMaintenanceSheet(asset: context.resource) {
                pendingIntentSheet = nil
                Task { await context.onResourceMutated() }
            }
        case .reportDamageSheet:
            ReportDamageSheet(asset: context.resource) {
                pendingIntentSheet = nil
                Task { await context.onResourceMutated() }
            }
        case .createSlotUnderAssetSheet:
            CreateSlotSheet(asset: context.resource) {
                pendingIntentSheet = nil
                Task { await context.onResourceMutated() }
            }
        case .fundLockSheet:
            LockFundSheet(asset: context.resource) {
                pendingIntentSheet = nil
                Task { await context.onResourceMutated() }
            }
        case .systemShareSheet:
            // TODO Phase 2: wire a system UIActivityViewController bridge
            // (or reuse ShareEventSheet when generalized). For now show a
            // placeholder so the menu entry doesn't silently dead-end.
            VStack(spacing: RuulSpacing.md) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 48))
                    .foregroundStyle(Color.ruulTextSecondary)
                Text("Compartir llega en la siguiente iteración.")
                    .ruulTextStyle(RuulTypography.body)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, RuulSpacing.lg)
                Button("Cerrar") { pendingIntentSheet = nil }
                    .buttonStyle(.bordered)
            }
            .padding(RuulSpacing.xl)
            .presentationDetents([.medium])
        case .editResourceSheet:
            // Per-type edit sheets: right → EditRightSheet (existing).
            // Other types: Phase 2. For now the menu surfaces a
            // "coming soon" so the entry doesn't disappear without a
            // breadcrumb.
            if context.resource.resourceType == .right {
                EditRightSheet(
                    rightId: context.resource.id,
                    metadata: context.resource.metadata,
                    onCompleted: {
                        pendingIntentSheet = nil
                        if let onDismiss = context.onDismiss { onDismiss() }
                        else { dismiss() }
                    }
                )
            } else {
                VStack(spacing: RuulSpacing.md) {
                    Image(systemName: "pencil")
                        .font(.system(size: 48))
                        .foregroundStyle(Color.ruulTextSecondary)
                    Text("Editar este tipo de recurso llega en la siguiente iteración.")
                        .ruulTextStyle(RuulTypography.body)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, RuulSpacing.lg)
                    Button("Cerrar") { pendingIntentSheet = nil }
                        .buttonStyle(.bordered)
                }
                .padding(RuulSpacing.xl)
                .presentationDetents([.medium])
            }
        default:
            EmptyView()
        }
    }

    // MARK: - Confirmation dispatch

    private var confirmationBinding: Binding<Bool> {
        Binding(
            get: { pendingConfirmation != nil },
            set: { isPresented in
                if !isPresented { pendingConfirmation = nil }
            }
        )
    }

    @MainActor
    private func runConfirmedAction(_ kind: ConfirmationKind) async {
        defer { pendingConfirmation = nil }
        do {
            switch kind {
            case .releaseCustody:
                try await app.assetLifecycleRepo.releaseCustody(
                    asset: context.resource.id, notes: nil
                )
            case .markReturned:
                try await app.assetLifecycleRepo.checkInAsset(
                    asset: context.resource.id, conditionNotes: nil
                )
            case .returnAssetToGroup:
                try await app.assetLifecycleRepo.transferAsset(
                    asset: context.resource.id, to: nil, notes: nil
                )
            case .fundUnlock:
                try await app.fundRepo.unlock(fundId: context.resource.id)
            case .archiveResource:
                // TODO Phase 2: wire `archive_resource` RPC (mig 00291).
                // For now log + surface as error so the user knows it
                // didn't go through silently.
                intentError = "Archivar llega en la siguiente iteración."
                return
            }
            await context.onResourceMutated()
            intentError = nil
        } catch {
            intentError = error.localizedDescription
        }
    }

    // MARK: - RPC handlers (sheet-completion callbacks)

    @MainActor
    private func transferAsset(to memberId: UUID) async {
        pendingIntentSheet = nil
        do {
            try await app.assetLifecycleRepo.transferAsset(
                asset: context.resource.id, to: memberId, notes: nil
            )
            await context.onResourceMutated()
        } catch {
            intentError = error.localizedDescription
        }
    }

    @MainActor
    private func assignCustody(to memberId: UUID) async {
        pendingIntentSheet = nil
        do {
            try await app.assetLifecycleRepo.assignCustody(
                asset: context.resource.id, to: memberId, notes: nil
            )
            await context.onResourceMutated()
        } catch {
            intentError = error.localizedDescription
        }
    }

    // MARK: - Member-picker filtering for asset action sheets

    /// Members eligible to receive the asset via transfer — everyone in
    /// the group except the current owner.
    private var transferableMembers: [MemberWithProfile] {
        let all = Array(context.memberDirectory.values)
        guard let raw = context.resource.metadata["owner_id"]?.stringValue,
              let ownerMemberId = UUID(uuidString: raw) else {
            return all
        }
        return all.filter { $0.member.id != ownerMemberId }
    }

    /// Members eligible to assume custody — everyone except the current
    /// custodian (selecting the same person is a no-op server-side but
    /// muddies the audit trail).
    private var assignableCustodians: [MemberWithProfile] {
        let all = Array(context.memberDirectory.values)
        guard let raw = context.resource.metadata["custodian_id"]?.stringValue,
              let custodianMemberId = UUID(uuidString: raw) else {
            return all
        }
        return all.filter { $0.member.id != custodianMemberId }
    }
}

// MARK: - Intent wrapper + confirmation kind

/// `.sheet(item:)` requires Identifiable. Wrapping `ResourceIntent` so
/// the destination can drive the sheet renderer without making the
/// public `ResourceIntent` value itself Identifiable-by-self (intents
/// can repeat per resource type — id alone isn't a sheet key).
struct IdentifiableIntent: Identifiable {
    let intent: ResourceIntent
    var id: String { intent.id }
}

/// Direct-action confirmations driven by `.confirmationDialog`. Each
/// case carries its own copy + destructive CTA so the dialog body
/// reads naturally per action.
enum ConfirmationKind: Identifiable, Hashable {
    case releaseCustody
    case markReturned
    case returnAssetToGroup
    case fundUnlock
    case archiveResource

    var id: Self { self }

    var title: String {
        switch self {
        case .releaseCustody:     return "¿Liberar custodia?"
        case .markReturned:       return "¿Marcar como devuelto?"
        case .returnAssetToGroup: return "¿Devolver al grupo?"
        case .fundUnlock:         return "¿Desbloquear el fondo?"
        case .archiveResource:    return "¿Archivar este recurso?"
        }
    }

    var message: String {
        switch self {
        case .releaseCustody:
            return "El activo vuelve a custodia del grupo (sin custodio asignado)."
        case .markReturned:
            return "Marca que el activo volvió a la persona que lo tiene en custodia."
        case .returnAssetToGroup:
            return "Quita al dueño actual. El activo queda como propiedad del grupo."
        case .fundUnlock:
            return "El fondo vuelve a permitir aportaciones y gastos."
        case .archiveResource:
            return "El recurso sale del feed activo. Queda en historial."
        }
    }

    var confirmCTA: String {
        switch self {
        case .releaseCustody:     return "Liberar"
        case .markReturned:       return "Marcar devuelto"
        case .returnAssetToGroup: return "Devolver"
        case .fundUnlock:         return "Desbloquear"
        case .archiveResource:    return "Archivar"
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
