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

    /// Bumped after every successful fund action so `FundBalanceSection`'s
    /// `.task(id:)` re-runs and the projection re-reads.
    @State private var fundRefreshToken: Int = 0

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
                if hasDescription {
                    DescriptionSectionView(context: context)
                }
                if context.enabledCapabilities.contains("location") {
                    LocationSectionView(context: context)
                }
                if context.resource.resourceType == .asset {
                    if context.enabledCapabilities.contains("custody") {
                        AssetCustodySection(
                            asset: context.resource,
                            onMetadataChanged: { await context.onResourceMutated() }
                        )
                    }
                    if context.enabledCapabilities.contains("transfer")
                        || context.enabledCapabilities.contains("valuation") {
                        AssetOwnershipSection(
                            asset: context.resource,
                            onMetadataChanged: { await context.onResourceMutated() }
                        )
                    }
                    if context.enabledCapabilities.contains("maintenance") {
                        // Maintenance writes system_events (not resources.metadata),
                        // so the section's internal reload handles freshness — no
                        // need to bubble `onResourceMutated`.
                        AssetMaintenanceSection(asset: context.resource)
                    }
                    if context.enabledCapabilities.contains("booking") {
                        AssetBookingsSection(asset: context.resource)
                    }
                }
                if context.resource.resourceType == .fund {
                    // Fund-specific projection card: current balance,
                    // target progress, contribution/expense counts, lock
                    // indicator. Reads from `fund_balance_view` (mig 00202)
                    // via `fundRepo.get`. Refreshes whenever
                    // `fundRefreshToken` bumps after a successful action.
                    FundBalanceSection(
                        fundId: context.resource.id,
                        refreshToken: fundRefreshToken
                    )
                }
                if context.enabledCapabilities.contains("rsvp") {
                    RSVPSectionView(context: context)
                }
                if context.enabledCapabilities.contains("check_in"), eventInteractor != nil {
                    CheckInSectionView(context: context)
                }
                if context.enabledCapabilities.contains("ledger") {
                    MoneySectionView(context: context)
                }
                if context.enabledCapabilities.contains("rules") {
                    RulesSectionView(context: context)
                }
                if context.resource.resourceType == .event {
                    // Plans/Active/EventResource.md §12 — "event uses
                    // space/asset/fund/right". Hidden for non-event types.
                    ResourcesUsedSectionView(context: context)
                }
                if context.enabledCapabilities.contains("activity") {
                    ActivitySectionView(context: context)
                }
                stubCapabilitySections
                SettingsSectionView(
                    onPresentEnableCapability: shouldShowEnableCapability
                        ? context.onPresentEnableCapability
                        : nil,
                    onArchive: nil
                )
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
                holderMemberId: currentHolderMemberId,
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

    /// Fan-out after a successful fund action. Bumps the FundBalanceSection
    /// refresh token so its `.task(id:)` re-reads `fund_balance_view`, AND
    /// calls `context.onResourceMutated` so the parent coordinator refetches
    /// the resource row (the "Estado: Bloqueado" indicator in the
    /// INFORMACIÓN card reads from row metadata, so a lock/unlock changes
    /// it). The two signals are complementary — the projection and the
    /// row each have their own freshness contract.
    private func onFundActionSucceeded() {
        fundRefreshToken &+= 1
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

    /// Per-type sub-line under the title. Falls through to the type label
    /// when no domain-specific subtitle applies (e.g. "Activo · activo").
    private var heroSubtitle: String? {
        let typeLabel: String
        switch context.resource.resourceType {
        case .event: typeLabel = "Evento"
        case .fund:  typeLabel = "Fondo"
        case .asset: typeLabel = "Activo"
        case .space: typeLabel = "Espacio"
        case .slot:  typeLabel = "Cupo"
        case .right: typeLabel = "Derecho"
        case .unknown: return nil
        }
        // Status only worth surfacing when it's not the boring default.
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
    /// shape. Polled before the universal "Creado" tail row so it lands
    /// in a stable spot in the card.
    private var typeSpecificRows: [(label: String, value: String)] {
        switch context.resource.resourceType {
        case .fund:
            var out: [(String, String)] = []
            if let currency = context.resource.metadata["currency"]?.stringValue {
                out.append(("Moneda", currency))
            }
            if let goalCents = fundTargetAmountCents {
                out.append(("Meta", formatCurrencyCents(goalCents)))
            }
            // Surface lock state — fund_lock writes locked_at/locked_by/
            // locked_reason into metadata + emits fundLocked. Pre-fix
            // this was invisible to the UI even though the SQL state
            // existed, so admins couldn't tell whether a fund was locked
            // without querying the DB.
            if let lockedAt = context.resource.metadata["locked_at"]?.stringValue,
               !lockedAt.isEmpty {
                let reason = context.resource.metadata["locked_reason"]?.stringValue
                let suffix = (reason?.isEmpty == false) ? " (\(reason!))" : ""
                out.append(("Estado", "Bloqueado\(suffix)"))
            }
            return out
        case .asset:
            var out: [(String, String)] = []
            if let custodianId = uuidFromMeta("custodian_id"),
               let m = memberByMemberId(custodianId) {
                out.append(("Custodio", m.displayName))
            }
            if let ownerId = uuidFromMeta("owner_id"),
               let m = memberByMemberId(ownerId) {
                out.append(("Dueño", m.displayName))
            }
            if let holderId = uuidFromMeta("checked_out_to"),
               let m = memberByMemberId(holderId) {
                out.append(("Prestado a", m.displayName))
            }
            if let cap = context.resource.metadata["capacity"]?.intValue {
                out.append(("Capacidad", "\(cap)"))
            }
            if let unit = context.resource.metadata["unit_label"]?.stringValue {
                let count = context.resource.metadata["currentCount"]?.intValue
                out.append(("Inventario", count.map { "\($0) \(unit)" } ?? unit))
            }
            return out
        case .space:
            var out: [(String, String)] = []
            // `create_space` writes `metadata.location_name` (mig 00207).
            // Pre-fix this row read the wrong key (`address`), so wizard-
            // created spaces never surfaced their dirección. Fallback to
            // `locationName` for any future codepath that uses camelCase
            // (LocationSectionView already accepts both shapes).
            let address = context.resource.metadata["location_name"]?.stringValue
                ?? context.resource.metadata["locationName"]?.stringValue
            if let address, !address.isEmpty {
                out.append(("Dirección", address))
            }
            if let cap = context.resource.metadata["capacity"]?.intValue {
                out.append(("Capacidad", "\(cap)"))
            }
            return out
        case .right:
            // Slice 11 restored: cover hero was deleted in the universal
            // frame refactor (commit b01f8fb) so the holder/status/
            // priority/expires info from the old quickFacts pills has
            // no home now. Surface them as INFORMACIÓN rows instead.
            // Affirmative-only — default values (priority 0, exclusive
            // false, etc.) are hidden so the card stays scannable.
            var out: [(String, String)] = []

            // Titular: read holder_user_id (auth.users.id, populated by
            // create_right alongside holder_member_id). The directory is
            // keyed by userId for events; works the same here.
            if let holderUid = uuidFromMeta("holder_user_id"),
               let holder = context.memberDirectory[holderUid] {
                out.append(("Titular", holder.displayName))
            }
            // Delegado: when set, signal who can exercise today.
            if let delegateUid = uuidFromMeta("delegate_user_id"),
               let delegate = context.memberDirectory[delegateUid] {
                out.append(("Delegado", delegate.displayName))
            }
            // Estado: only render non-default states. `active` is
            // implicit (no row needed); `expired` / `revoked` are
            // material to the holder.
            switch context.resource.status {
            case "expired": out.append(("Estado", "Vencido"))
            case "revoked": out.append(("Estado", "Revocado"))
            default: break
            }
            // Suspended: separate from status (suspension keeps status
            // active but blocks exercise). Pull `suspended_until` when
            // set; else just signal the suspended state.
            if let until = parseISOMeta("suspended_until") {
                out.append(("Suspendido hasta", until.ruulShortDate))
            } else if context.resource.metadata["suspended_at"]?.stringValue != nil {
                out.append(("Estado", "Suspendido"))
            }
            // Priority: only when explicitly > 0 (default rendered as
            // no row to avoid noise).
            if let priority = context.resource.metadata["priority"]?.intValue,
               priority > 0 {
                out.append(("Prioridad", "\(priority)"))
            }
            // Affirmative flags: only render when true.
            if context.resource.metadata["exclusive"]?.boolValue == true {
                out.append(("Alcance", "Exclusivo"))
            }
            if context.resource.metadata["transferable"]?.boolValue == true {
                out.append(("Transferible", "Sí"))
            }
            if context.resource.metadata["delegable"]?.boolValue == true {
                out.append(("Delegable", "Sí"))
            }
            // Expiration: forward-looking only. The expire_due_rights
            // cron flips status to `expired` once the date lapses, so
            // a future date is the meaningful signal here.
            if let expires = parseISOMeta("expires_at"), expires > Date.now {
                out.append(("Vence", expires.ruulShortDate))
            }
            return out
        case .event, .slot, .unknown:
            return []
        }
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

    /// Looks up a member by their `group_members.id` — asset metadata
    /// (custodian_id / owner_id / checked_out_to) stores the member-row
    /// id, NOT the user id. `context.memberDirectory` is keyed by
    /// `member.userId` (host lookup), so a direct subscript misses on
    /// asset rows. Iterates values — fine for typical group sizes.
    private func memberByMemberId(_ id: UUID) -> MemberWithProfile? {
        context.memberDirectory.values.first { $0.member.id == id }
    }

    /// `create_fund` (mig 00139) stores the target as `target_amount_cents`
    /// (bigint cents). Previously this read `goal_amount` (which mig
    /// 00139 never writes) — the "Meta" row was silently empty even when
    /// the founder set a target. Reads both keys for backwards compat
    /// with any rows written under the old metadata shape, then converts
    /// from cents.
    private var fundTargetAmountCents: Int64? {
        if case .int(let i)? = context.resource.metadata["target_amount_cents"] {
            return Int64(i)
        }
        // Backwards-compat: pre-mig 00139 hand-written rows could have
        // stored `goal_amount` in pesos. Treat as pesos → cents conversion.
        if case .double(let d)? = context.resource.metadata["goal_amount"] {
            return Int64(d * 100)
        }
        if case .int(let i)? = context.resource.metadata["goal_amount"] {
            return Int64(i) * 100
        }
        return nil
    }

    /// Renders a cents value as a localized currency string. Centavos →
    /// pesos divide by 100. Reads the resource's `currency` from
    /// metadata, falling back to MXN.
    private func formatCurrencyCents(_ cents: Int64) -> String {
        let pesos = Double(cents) / 100.0
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = context.resource.metadata["currency"]?.stringValue ?? "MXN"
        nf.maximumFractionDigits = pesos.truncatingRemainder(dividingBy: 1) == 0 ? 0 : 2
        return nf.string(from: NSNumber(value: pesos)) ?? "\(pesos)"
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

    /// Reads `metadata.<key>` as an ISO-8601 string and parses it.
    /// Right's metadata uses ISO timestamps for `expires_at` /
    /// `suspended_until` / `delegate_until` (slice 11 INFORMACIÓN rows
    /// consume this). Returns nil when the key is absent, empty, or
    /// doesn't parse — caller decides whether to render the row.
    private func parseISOMeta(_ key: String) -> Date? {
        guard let raw = context.resource.metadata[key]?.stringValue,
              !raw.isEmpty else { return nil }
        return Self.parseISO(raw)
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

    // MARK: - Capability gating

    private var hasDescription: Bool {
        guard context.enabledCapabilities.contains("description") else { return false }
        if case .string(let s)? = context.resource.metadata["description"], !s.isEmpty {
            return true
        }
        return false
    }

    private var shouldShowEnableCapability: Bool {
        // "Activar capability" dead-route for events (capability set
        // hard-seeded by the platform). Surface only for non-event types.
        context.resource.resourceType != .event
    }

    /// Renders every capability that owns a stub section (Sections/Stubs/).
    /// Each `if context.enabledCapabilities.contains(...)` only fires when
    /// the capability is actually enabled on this resource, so a vanilla
    /// event with no extras still renders zero extra cards. Sections that
    /// have a bespoke renderer above (rsvp, check_in, money, rules,
    /// rotation, schedule, location, description, activity) are NOT
    /// duplicated here.
    @ViewBuilder
    private var stubCapabilitySections: some View {
        let caps = context.enabledCapabilities
        let isAsset = context.resource.resourceType == .asset
        if caps.contains("status") { StatusSectionView(context: context) }
        if caps.contains("recurrence") { RecurrenceSectionView(context: context) }
        if caps.contains("deadline") { DeadlineSectionView(context: context) }
        if caps.contains("expiration") { ExpirationSectionView(context: context) }
        if caps.contains("participants") { ParticipantsSectionView(context: context) }
        if caps.contains("attendance") { AttendanceSectionView(context: context) }
        if caps.contains("guest_access") { GuestAccessSectionView(context: context) }
        if caps.contains("assignment") { AssignmentSectionView(context: context) }
        // Asset already gets a bespoke AssetBookingsSection / AssetOwnershipSection
        // upstream when these caps are enabled, so we skip the stub to avoid a
        // duplicate card on asset detail pages.
        if caps.contains("booking") && !isAsset { BookingSectionView(context: context) }
        if caps.contains("valuation") && !isAsset { ValuationSectionView(context: context) }
        if caps.contains("inventory") { InventorySectionView(context: context) }
        if caps.contains("access") { AccessSectionView(context: context) }
        if caps.contains("delegation") { DelegationSectionView(context: context) }
        if caps.contains("voting") { VotingSectionView(context: context) }
        if caps.contains("approval") { ApprovalSectionView(context: context) }
        if caps.contains("appeal") { AppealSectionView(context: context) }
        if caps.contains("consequence") { ConsequenceSectionView(context: context) }
        if caps.contains("swap") { SwapSectionView(context: context) }
        if caps.contains("cancellation") { CancellationSectionView(context: context) }
        if caps.contains("reminder") { ReminderSectionView(context: context) }
        if caps.contains("history") { HistorySectionView(context: context) }
    }

    /// Reads `metadata.holder_member_id` off the polymorphic resource row.
    /// Used by `RightActionSheet` to filter the transfer recipient picker
    /// so the current holder isn't offered as a self-transfer target.
    private var currentHolderMemberId: UUID? {
        guard context.resource.resourceType == .right,
              let raw = context.resource.metadata["holder_member_id"]?.stringValue,
              let id = UUID(uuidString: raw) else { return nil }
        return id
    }

    // MARK: - Resolver-driven actions

    private var primaryAction: PrimaryAction {
        let role = viewerRole()
        let rsvpStatus = eventInteractor?.myRSVP?.status
        let eventStatus = eventInteractor?.event.status

        return app.capabilityResolver.primaryAction(
            for: context.resource,
            viewerRole: role,
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
            viewerRole: viewerRole(),
            viewerCanIssueManualFine: presenter?.canIssueManualFine ?? false,
            enabledCapabilities: context.enabledCapabilities,
            viewerUserId: context.currentUserId
        )
    }

    private func viewerRole() -> MemberRole {
        guard let userId = context.currentUserId,
              let mwp = context.memberDirectory[userId] else {
            return .member
        }
        let roles = mwp.member.roles
        if roles.contains(.founder)  { return .founder }
        if roles.contains(.host)     { return .host }
        if roles.contains(.treasurer) { return .treasurer }
        return .member
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
        case .openLedger:
            context.onPresentLedger()
        case .issueManualFine:
            presenter?.onPresentManualFineSheet()
        case .openRules:
            context.onPresentRules()
        case .enableCapability:
            context.onPresentEnableCapability()
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
