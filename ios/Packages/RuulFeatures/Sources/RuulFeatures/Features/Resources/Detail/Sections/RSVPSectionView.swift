import SwiftUI
import RuulUI
import RuulCore

/// RSVP surface for event-shaped resources. Composed of two stacked
/// elements, both optional:
///
///   1. **Intent CTA** — surfaces only when `\.eventInteractor` is in
///      scope. Lets the current user set their own RSVP (going / maybe /
///      declined), pick plus-ones, and reach the Wallet/QR/Scanner
///      affordances via `\.eventDetailPresenter`.
///   2. **Roll** — tally + expandable per-status list of other members'
///      RSVPs. Renders even when no interactor is present (read-only
///      surface for non-event resources that gain the cap in Phase 2+).
///
/// Section visibility is governed by the `rsvp` capability on the
/// resource; presence of the interactor only decides whether the intent
/// control draws.
public struct RSVPSectionView: View {
    @Environment(AppState.self) private var app
    @Environment(\.eventInteractor) private var interactor: (any EventInteractor)?
    @Environment(\.eventDetailPresenter) private var presenter: EventDetailPresenter?

    public let context: ResourceDetailContext

    @State private var rsvps: [RSVP] = []
    @State private var isLoading: Bool = true
    @State private var expanded: Set<RSVPStatus> = [.going]
    /// Local plus-ones stepper state. Mirrors `interactor.myRSVP?.plusOnes`
    /// after each interactor change so the stepper reflects the truth even
    /// if the server downgrades the count (capacity).
    @State private var pendingPlusOnes: Int = 0

    public static let definition = CapabilitySection(
        id: "rsvp",
        priority: 200,
        isEnabledFor: { caps in caps.contains("rsvp") },
        render: { ctx in AnyView(RSVPSectionView(context: ctx)) }
    )

    public var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.lg) {
            if let intent = intentControl {
                intent
            }
            rollContent
        }
        .task { await load() }
        .onChange(of: interactor?.myRSVP?.plusOnes ?? 0, initial: true) { _, new in
            pendingPlusOnes = new
        }
    }

    // MARK: - Intent CTA (current user)

    /// Rendered only when an `EventInteractor` is in scope. Falls back
    /// gracefully when no presenter is wired — Wallet/QR taps become
    /// no-ops, intent CTAs still work via the interactor.
    @ViewBuilder
    private var intentControl: (some View)? {
        if let interactor, let event = eventFromInteractor(interactor) {
            EventRSVPStateView(
                status: interactor.myRSVP?.status ?? .pending,
                event: event,
                walletAvailable: interactor.walletAvailable,
                isAtCapacity: isAtCapacity(interactor: interactor),
                plusOnes: $pendingPlusOnes,
                onChange: { newStatus in
                    Task {
                        await interactor.setRSVP(newStatus, plusOnes: pendingPlusOnes, reason: nil)
                    }
                },
                onAddToWallet: { presenter?.onAddToWallet() },
                onShowQR: { presenter?.onPresentMemberQR() }
            )
        }
    }

    /// Returns the live `Event` value from the interactor. Today the
    /// existential is a single concrete (`EventDetailCoordinator`) so this
    /// is a direct read; the indirection lets the protocol grow without
    /// every section knowing the conforming type.
    private func eventFromInteractor(_ interactor: any EventInteractor) -> Event? {
        interactor.event
    }

    /// Same capacity calc as the legacy EventDetailView: the viewer's
    /// own existing seats don't count against the threshold when
    /// re-confirming, matching the server's check semantics.
    private func isAtCapacity(interactor: any EventInteractor) -> Bool {
        guard let max = interactor.event.capacityMax else { return false }
        let seatsTaken = interactor.rsvps
            .filter { $0.status == .going }
            .reduce(0) { $0 + 1 + $1.plusOnes }
        let myExisting = (interactor.myRSVP?.status == .going)
            ? (1 + (interactor.myRSVP?.plusOnes ?? 0))
            : 0
        return (seatsTaken - myExisting + 1 + pendingPlusOnes) > max
    }

    // MARK: - Roll

    @ViewBuilder
    private var rollContent: some View {
        if isLoading {
            HStack { Spacer(); ProgressView().padding(RuulSpacing.lg); Spacer() }
                .cardBackground()
        } else if effectiveRsvps.isEmpty {
            HStack(spacing: RuulSpacing.sm) {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .foregroundStyle(Color.ruulTextTertiary)
                Text("Aún nadie ha confirmado")
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextSecondary)
                Spacer()
            }
            .padding(RuulSpacing.md)
            .cardBackground()
        } else {
            VStack(alignment: .leading, spacing: RuulSpacing.md) {
                tallyCard
                rolls
            }
        }
    }

    /// Prefer the interactor's realtime-driven list when present; otherwise
    /// fall back to the section's own one-shot fetch. Keeps the roll
    /// in-sync with optimistic mutations the user makes via the intent CTA.
    private var effectiveRsvps: [RSVP] {
        interactor?.rsvps ?? rsvps
    }

    // MARK: - Tally

    private var tallyCard: some View {
        VStack(spacing: 0) {
            tallyRow(.going,    label: "Vas",       color: .ruulPositive)
            divider
            tallyRow(.maybe,    label: "Quizás",    color: .ruulWarning)
            divider
            tallyRow(.declined, label: "No vas",    color: .ruulNegative)
            divider
            tallyRow(.pending,  label: "Pendiente", color: .ruulTextTertiary)
        }
        .cardBackground()
    }

    private func tallyRow(_ status: RSVPStatus, label: String, color: Color) -> some View {
        let count = effectiveRsvps.filter { $0.status == status }.count
        return HStack(spacing: RuulSpacing.sm) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
                .ruulTextStyle(RuulTypography.body)
                .foregroundStyle(Color.ruulTextPrimary)
            Spacer()
            Text("\(count)")
                .ruulTextStyle(RuulTypography.statSmall)
                .foregroundStyle(Color.ruulTextSecondary)
        }
        .padding(.horizontal, RuulSpacing.md)
        .padding(.vertical, RuulSpacing.sm)
    }

    private var divider: some View {
        Divider().background(Color.ruulSeparator).padding(.leading, RuulSpacing.md)
    }

    // MARK: - Rolls (expandable per status)

    private var rolls: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.lg) {
            ForEach(RSVPStatus.allCases, id: \.self) { status in
                roll(for: status)
            }
        }
    }

    @ViewBuilder
    private func roll(for status: RSVPStatus) -> some View {
        let filtered = effectiveRsvps.filter { $0.status == status }
        if !filtered.isEmpty {
            VStack(alignment: .leading, spacing: RuulSpacing.xs) {
                Button {
                    withAnimation(.ruulSnappy) {
                        if expanded.contains(status) { expanded.remove(status) }
                        else { expanded.insert(status) }
                    }
                } label: {
                    HStack(spacing: RuulSpacing.xs) {
                        rollIcon(for: status)
                        Text(rollLabel(for: status).uppercased())
                            .ruulTextStyle(RuulTypography.sectionLabelLg)
                            .foregroundStyle(Color.ruulTextPrimary)
                        Text("\(filtered.count)")
                            .ruulTextStyle(RuulTypography.statSmall)
                            .foregroundStyle(Color.ruulTextTertiary)
                        Spacer()
                        Image(systemName: expanded.contains(status) ? "chevron.up" : "chevron.down")
                            .font(.system(size: RuulSize.iconXS, weight: .bold))
                            .foregroundStyle(Color.ruulTextTertiary)
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if expanded.contains(status) {
                    VStack(spacing: RuulSpacing.xs) {
                        ForEach(filtered, id: \.id) { rsvp in
                            row(for: rsvp)
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    @ViewBuilder
    private func row(for rsvp: RSVP) -> some View {
        let profile = context.memberDirectory[rsvp.userId]
        let name    = profile?.displayName ?? "Miembro"
        let avatar  = profile?.avatarURL
        Button { context.onSelectMember(rsvp.userId) } label: {
            HStack(spacing: RuulSpacing.sm) {
                RuulAvatar(name: name, imageURL: avatar, size: .small)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .ruulTextStyle(RuulTypography.body)
                        .foregroundStyle(Color.ruulTextPrimary)
                    if rsvp.isCheckedIn, let arrived = rsvp.arrivedAt {
                        Text("Llegó \(arrived.ruulShortTime)")
                            .ruulTextStyle(RuulTypography.caption)
                            .foregroundStyle(Color.ruulPositive)
                    }
                }
                Spacer()
            }
            .padding(.vertical, RuulSpacing.xxs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func rollIcon(for status: RSVPStatus) -> some View {
        let (icon, color): (String, Color) = {
            switch status {
            case .going:      return ("checkmark.circle.fill", .ruulPositive)
            case .maybe:      return ("questionmark.circle.fill", .ruulWarning)
            case .declined:   return ("xmark.circle.fill", .ruulNegative)
            case .waitlisted: return ("person.crop.circle.badge.clock", .ruulWarning)
            case .pending:    return ("clock", .ruulTextTertiary)
            }
        }()
        return Image(systemName: icon)
            .foregroundStyle(color)
            .accessibilityHidden(true)
    }

    private func rollLabel(for status: RSVPStatus) -> String {
        switch status {
        case .going:      return "Van"
        case .maybe:      return "Tal vez"
        case .declined:   return "No van"
        case .waitlisted: return "Lista de espera"
        case .pending:    return "Pendientes"
        }
    }

    @MainActor
    private func load() async {
        defer { isLoading = false }
        // When the interactor is in scope it owns the realtime stream,
        // so a manual fetch would be redundant churn. Phase 11 will let
        // us delete this branch outright.
        guard interactor == nil else { return }
        do {
            rsvps = try await app.rsvpRepo.rsvps(for: context.resource.id)
        } catch {
            rsvps = []
        }
    }
}
