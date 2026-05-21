import SwiftUI
import RuulUI
import RuulCore

/// Full attendee list grouped by RSVP status. Presented as a sheet from
/// the event detail when the user taps the "Ver todos" affordance on
/// the avatar strip. Keeps the page hero quiet while still surfacing the
/// full per-status roll one tap away.
public struct AttendeesListSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var app

    public let rsvps: [RSVP]
    public let memberDirectory: [UUID: MemberWithProfile]
    public let onSelectMember: (UUID) -> Void

    public init(
        rsvps: [RSVP],
        memberDirectory: [UUID: MemberWithProfile],
        onSelectMember: @escaping (UUID) -> Void
    ) {
        self.rsvps = rsvps
        self.memberDirectory = memberDirectory
        self.onSelectMember = onSelectMember
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: RuulSpacing.xxl, pinnedViews: []) {
                    ForEach(RSVPStatus.allCases, id: \.self) { status in
                        roll(for: status)
                    }
                }
                .padding(.horizontal, RuulSpacing.lg)
                .padding(.vertical, RuulSpacing.lg)
            }
            .scrollIndicators(.hidden)
            .ruulSheetToolbar("Asistentes")
        }
    }

    // MARK: - Per-status roll

    @ViewBuilder
    private func roll(for status: RSVPStatus) -> some View {
        let filtered = rsvps.filter { $0.status == status }
        if !filtered.isEmpty {
            VStack(alignment: .leading, spacing: RuulSpacing.sm) {
                HStack(spacing: RuulSpacing.xs) {
                    Circle()
                        .fill(color(for: status))
                        .frame(width: 8, height: 8)
                    Text(label(for: status))
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.primary)
                    Text("\(filtered.count)")
                        .font(.footnote.monospacedDigit().weight(.bold))
                        .foregroundStyle(Color(.tertiaryLabel))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, RuulSpacing.xxs)

                VStack(spacing: 0) {
                    ForEach(filtered, id: \.id) { rsvp in
                        row(for: rsvp)
                        if rsvp.id != filtered.last?.id {
                            Divider()
                                .background(Color(.separator))
                                .padding(.leading, 56)
                        }
                    }
                }
                .cardBackground()
            }
        }
    }

    @ViewBuilder
    private func row(for rsvp: RSVP) -> some View {
        let profile = memberDirectory[rsvp.userId]
        let name = profile?.displayName ?? "Miembro"
        Button { onSelectMember(rsvp.userId) } label: {
            HStack(spacing: RuulSpacing.sm) {
                RuulAvatar(name: name, imageURL: profile?.avatarURL, size: .small)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.subheadline)
                        .foregroundStyle(Color.primary)
                    if rsvp.isCheckedIn, let arrived = rsvp.arrivedAt {
                        Text("Llegó \(arrived.ruulShortTime)")
                            .font(.caption)
                            .foregroundStyle(Color.green)
                    } else if rsvp.plusOnes > 0 {
                        Text("+\(rsvp.plusOnes)")
                            .font(.caption)
                            .foregroundStyle(Color(.tertiaryLabel))
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, RuulSpacing.md)
            .padding(.vertical, RuulSpacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Status helpers

    private func color(for status: RSVPStatus) -> Color {
        switch status {
        case .going:      return .green
        case .maybe:      return .orange
        case .declined:   return .red
        case .waitlisted: return .orange
        case .pending:    return Color(.tertiaryLabel)
        }
    }

    private func label(for status: RSVPStatus) -> String {
        switch status {
        case .going:      return "VAN"
        case .maybe:      return "TAL VEZ"
        case .declined:   return "NO VAN"
        case .waitlisted: return "LISTA DE ESPERA"
        case .pending:    return "PENDIENTES"
        }
    }
}
