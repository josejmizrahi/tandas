import SwiftUI
import RuulCore
import RuulUI

/// Apple Invites-inspired resource detail v2.
///
/// Layout:
///   1. ResourceCoverHero            — full-bleed, parallax, white overlay
///   2. ResourceDetailPanel          — rounded panel slides up over cover
///        a. NeedsAttention card     — DetailAttentionView (compact)
///        b. ResourceTitleBlock      — date + host (Luma-style identity zone)
///        c. ResourceQuickFactsView  — horizontal pills (non-events only;
///                                     events surface their facts via b/Location)
///        d. Capability sections     — fixed order: Description, Location, RSVP,
///                                     CheckIn, Money, Rules, Activity
///        e. SettingsSection         — collapsed accordion (capability toggle, archive)
///   3. ResourcePrimaryCTA           — sticky footer, single button (.glassEffect)
///   4. NavigationStack toolbar      — close, share, ⋯ menu (secondaryActions)
@MainActor
public struct UniversalResourceDetailView: View {
    @Environment(AppState.self) private var app
    @Environment(\.eventInteractor) private var eventInteractor
    @Environment(\.eventDetailPresenter) private var presenter
    @Environment(\.dismiss) private var dismiss

    public let context: ResourceDetailContext

    public init(context: ResourceDetailContext) {
        self.context = context
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    coverHero
                    ResourceDetailPanel {
                        VStack(alignment: .leading, spacing: RuulSpacing.s7) {
                            DetailAttentionView(context: context)
                            ResourceTitleBlock(
                                context: context,
                                startsAt: parseStartsAt(),
                                endsAt: parseEndsAt()
                            )
                            if !shouldHideQuickFacts {
                                ResourceQuickFactsView(facts: quickFacts)
                            }
                            sections
                            SettingsSectionView(
                                onPresentEnableCapability: shouldShowEnableCapability
                                    ? context.onPresentEnableCapability
                                    : nil,
                                onArchive: nil
                            )
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
            .ignoresSafeArea(edges: .top)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ResourcePrimaryCTA(action: primaryAction, onTap: dispatchPrimary)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        if let onDismiss = context.onDismiss {
                            onDismiss()
                        } else {
                            dismiss()
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .ruulTextStyle(RuulTypography.subheadSemibold)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
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
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - Cover hero

    @ViewBuilder
    private var coverHero: some View {
        ResourceCoverHero(
            title: context.displayName,
            subtitle: app.capabilityResolver.coverSubtitle(
                for: context.resource,
                in: context.group,
                memberDirectory: context.memberDirectory,
                enabledCapabilities: context.enabledCapabilities
            ),
            dateLabel: dateLabel,
            timeLabel: timeLabel,
            statusPill: statusPill,
            coverImageURL: context.coverImageURL,
            groupCategory: context.group.category
        )
    }

    private var dateLabel: String? {
        guard let date = parseStartsAt() else { return nil }
        return date.ruulShortDate
    }

    private var timeLabel: String? {
        guard let date = parseStartsAt() else { return nil }
        return date.ruulShortTime
    }

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

    /// QuickFacts pills duplicate the title-block info for events
    /// (date / time / location). Hide for events; keep for funds / assets
    /// where the pills carry distinct facts (balance, progress, status).
    private var shouldHideQuickFacts: Bool {
        context.resource.resourceType == .event
    }

    private var statusPill: ResourceCoverHero.StatusPill? {
        guard let interactor = eventInteractor else { return nil }
        switch interactor.event.status {
        case .upcoming:   return .init(label: "PRÓXIMO", color: .green)
        case .inProgress: return .init(label: "EN CURSO", color: .blue)
        case .closed:     return .init(label: "CERRADO", color: .gray)
        case .cancelled:  return .init(label: "CANCELADO", color: .red)
        }
    }

    // MARK: - Sections (capability-gated, fixed order)

    @ViewBuilder
    private var sections: some View {
        if hasDescription {
            DescriptionSectionView(context: context)
                .padding(.horizontal, RuulSpacing.s6)
        }
        if context.enabledCapabilities.contains("location") {
            LocationSectionView(context: context)
                .padding(.horizontal, RuulSpacing.s6)
        }
        if context.enabledCapabilities.contains("rsvp") {
            RSVPSectionView(context: context)
                .padding(.horizontal, RuulSpacing.s6)
        }
        if context.enabledCapabilities.contains("check_in"), eventInteractor != nil {
            CheckInSectionView(context: context)
                .padding(.horizontal, RuulSpacing.s6)
        }
        if context.enabledCapabilities.contains("ledger") {
            MoneySectionView(context: context)
                .padding(.horizontal, RuulSpacing.s6)
        }
        if context.enabledCapabilities.contains("rules") {
            RulesSectionView(context: context)
                .padding(.horizontal, RuulSpacing.s6)
        }
        if context.enabledCapabilities.contains("activity") {
            ActivitySectionView(context: context)
                .padding(.horizontal, RuulSpacing.s6)
        }
    }

    private var hasDescription: Bool {
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

    // MARK: - Resolver-driven actions

    private var quickFacts: [QuickFact] {
        app.capabilityResolver.quickFacts(
            for: context.resource,
            in: context.group,
            enabledCapabilities: context.enabledCapabilities
        )
    }

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
            enabledCapabilities: context.enabledCapabilities
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
        }
    }
}

#if DEBUG
#Preview {
    Text("UniversalResourceDetailView v2 needs AppState + EventInteractor environment to render. See EventDetailHost.swift for full wiring.")
        .padding()
}
#endif
