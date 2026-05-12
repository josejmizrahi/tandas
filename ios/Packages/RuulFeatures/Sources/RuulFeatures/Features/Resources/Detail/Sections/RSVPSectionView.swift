import SwiftUI
import RuulUI
import RuulCore

/// RSVP surface for event-shaped resources: a tally header followed by
/// expandable rolls per status. Replaces the legacy hand-rolled
/// `AttendeesListSection` that lived in EventDetailView (audit task M.7):
/// folding it here removes the parallel attendees-vs-rsvp duplication
/// that the audit flagged, and any future Resource type with the `rsvp`
/// capability picks it up for free.
///
/// Stateful interaction (tap to RSVP) still routes through the legacy
/// `EventRSVPStateView` for events. That control is event-coordinator-
/// bound and stays hand-rolled until a polymorphic interaction context
/// lands in Phase 2.
public struct RSVPSectionView: View {
    @Environment(AppState.self) private var app
    public let context: ResourceDetailContext
    @State private var rsvps: [RSVP] = []
    @State private var isLoading: Bool = true
    @State private var expanded: Set<RSVPStatus> = [.going]

    public static let definition = CapabilitySection(
        id: "rsvp",
        priority: 200,
        isEnabledFor: { caps in caps.contains("rsvp") },
        render: { ctx in AnyView(RSVPSectionView(context: ctx)) }
    )

    public var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.sm) {
            sectionHeader("RSVP")
            content
        }
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            HStack { Spacer(); ProgressView().padding(RuulSpacing.lg); Spacer() }
                .cardBackground()
        } else if rsvps.isEmpty {
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
        let count = rsvps.filter { $0.status == status }.count
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
        let filtered = rsvps.filter { $0.status == status }
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
        do {
            rsvps = try await app.rsvpRepo.rsvps(for: context.resource.id)
        } catch {
            rsvps = []
        }
    }
}
