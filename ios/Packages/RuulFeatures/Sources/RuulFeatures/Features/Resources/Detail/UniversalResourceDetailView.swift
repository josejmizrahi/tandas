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

    public init(context: ResourceDetailContext) {
        self.context = context
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RuulSpacing.xl) {
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
                    AssetCustodySection(asset: context.resource)
                    AssetOwnershipSection(asset: context.resource)
                    AssetMaintenanceSection(asset: context.resource)
                    AssetBookingsSection(asset: context.resource)
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
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                RuulCloseToolbarButton {
                    if let onDismiss = context.onDismiss {
                        onDismiss()
                    } else {
                        dismiss()
                    }
                }
            }
            ToolbarItem(placement: .principal) {
                Text(context.displayName)
                    .ruulTextStyle(RuulTypography.headline)
                    .foregroundStyle(Color.ruulTextPrimary)
                    .lineLimit(1)
            }
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
        .navigationBarTitleDisplayMode(.inline)
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
            VStack(alignment: .leading, spacing: RuulSpacing.xs) {
                Text("INFORMACIÓN")
                    .ruulTextStyle(RuulTypography.sectionLabel)
                    .foregroundStyle(Color.ruulTextTertiary)
                    .padding(.leading, RuulSpacing.xxs)
                VStack(spacing: 0) {
                    ForEach(Array(facts.enumerated()), id: \.offset) { idx, fact in
                        infoRow(fact)
                        if idx < facts.count - 1 {
                            Divider()
                                .background(Color.ruulSeparator)
                                .padding(.leading, RuulSpacing.md)
                        }
                    }
                }
                .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.lg))
                .overlay(
                    RoundedRectangle(cornerRadius: RuulRadius.lg)
                        .stroke(Color.ruulSeparator, lineWidth: 0.5)
                )
            }
        }
    }

    private func infoRow(_ fact: (label: String, value: String)) -> some View {
        HStack {
            Text(fact.label)
                .ruulTextStyle(RuulTypography.body)
                .foregroundStyle(Color.ruulTextSecondary)
            Spacer()
            Text(fact.value)
                .ruulTextStyle(RuulTypography.body)
                .foregroundStyle(Color.ruulTextPrimary)
                .multilineTextAlignment(.trailing)
        }
        .padding(RuulSpacing.md)
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
            if let goal = goalAmount {
                out.append(("Meta", formatCurrency(goal)))
            }
            return out
        case .asset:
            var out: [(String, String)] = []
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
            if let address = context.resource.metadata["address"]?.stringValue,
               !address.isEmpty {
                out.append(("Dirección", address))
            }
            if let cap = context.resource.metadata["capacity"]?.intValue {
                out.append(("Capacidad", "\(cap)"))
            }
            return out
        case .right:
            var out: [(String, String)] = []
            if let kind = context.resource.metadata["right_kind"]?.stringValue,
               !kind.isEmpty {
                out.append(("Tipo", kind))
            }
            return out
        case .event, .slot, .unknown:
            return []
        }
    }

    private var hostRow: MemberWithProfile? {
        guard let raw = context.resource.metadata["host_id"]?.stringValue,
              let id = UUID(uuidString: raw) else { return nil }
        return context.memberDirectory[id]
    }

    private var goalAmount: Double? {
        if case .double(let d)? = context.resource.metadata["goal_amount"] { return d }
        if case .int(let i)? = context.resource.metadata["goal_amount"] { return Double(i) }
        return nil
    }

    private func formatCurrency(_ amount: Double) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = context.resource.metadata["currency"]?.stringValue ?? "MXN"
        nf.maximumFractionDigits = 0
        return nf.string(from: NSNumber(value: amount)) ?? "\(amount)"
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
            enabledCapabilities: context.enabledCapabilities
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
        case .openContribute, .openBooking, .viewClosed, .none:
            break
        }
    }

    private func dispatchSecondary(_ action: SecondaryAction) {
        switch action.kind {
        case .editDetails:
            context.onPresentEditResource()
        case .addToCalendar:
            break  // wire in Pass 1.1; presenter doesn't expose this directly
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
        }
    }
}

#if DEBUG
#Preview {
    Text("UniversalResourceDetailView needs AppState + EventInteractor environment to render. See EventDetailHost.swift for full wiring.")
        .padding()
}
#endif
