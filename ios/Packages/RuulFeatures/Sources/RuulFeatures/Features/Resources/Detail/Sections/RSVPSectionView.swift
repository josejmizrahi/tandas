import SwiftUI
import RuulUI
import RuulCore

/// Dynamic Section showing **who's coming** to a resource. Per the
/// canonical Resource Detail spec, RSVP-as-an-action lives upstream in
/// the Primary Actions zone (`DetailPrimaryActions`); this section
/// renders the attendee surface only — tally + expandable per-status
/// rolls — gated by the `rsvp` capability.
public struct RSVPSectionView: View {
    @Environment(AppState.self) private var app
    @Environment(\.eventInteractor) private var interactor: (any EventInteractor)?

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
            Text("Asistentes")
                .ruulTextStyle(RuulTypography.headline)
                .foregroundStyle(Color.ruulTextPrimary)
                .padding(.horizontal, RuulSpacing.xxs)
            rollContent
        }
        .task { await load() }
    }

    @ViewBuilder
    private var rollContent: some View {
        if isLoading && effectiveRsvps.isEmpty {
            HStack { Spacer(); ProgressView().padding(RuulSpacing.lg); Spacer() }
                .background(
                    Color.ruulSurface,
                    in: RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous)
                )
        } else if effectiveRsvps.isEmpty {
            HStack(spacing: RuulSpacing.sm) {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .foregroundStyle(Color.ruulTextTertiary)
                    .accessibilityHidden(true)
                Text("Sin confirmaciones aún")
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextSecondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, RuulSpacing.xxs)
            .padding(.vertical, RuulSpacing.sm)
        } else {
            VStack(alignment: .leading, spacing: RuulSpacing.md) {
                tallyCard
                rolls
            }
        }
    }

    /// Prefer the interactor's realtime list (mutations land instantly)
    /// over the section's own one-shot fetch.
    private var effectiveRsvps: [RSVP] {
        interactor?.rsvps ?? rsvps
    }

    // MARK: - Tally

    private var tallyCard: some View {
        VStack(spacing: 0) {
            tallyRow(.going,    label: "Van",       color: .ruulPositive)
            divider
            tallyRow(.maybe,    label: "Tal vez",   color: .ruulWarning)
            divider
            tallyRow(.declined, label: "No van",    color: .ruulNegative)
            divider
            tallyRow(.pending,  label: "Pendientes", color: .ruulTextTertiary)
        }
        .background(
            Color.ruulSurface,
            in: RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous)
        )
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

    // MARK: - Rolls

    private var rolls: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.md) {
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
                        Text(rollLabel(for: status))
                            .ruulTextStyle(RuulTypography.callout)
                            .foregroundStyle(Color.ruulTextPrimary)
                        Text("\(filtered.count)")
                            .ruulTextStyle(RuulTypography.statSmall)
                            .foregroundStyle(Color.ruulTextTertiary)
                        Spacer()
                        Image(systemName: expanded.contains(status) ? "chevron.up" : "chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.ruulTextTertiary)
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, RuulSpacing.xxs)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if expanded.contains(status) {
                    VStack(spacing: RuulSpacing.xs) {
                        ForEach(filtered, id: \.id) { rsvp in
                            row(for: rsvp)
                        }
                    }
                    .padding(.horizontal, RuulSpacing.xxs)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    @ViewBuilder
    private func row(for rsvp: RSVP) -> some View {
        let profile = context.memberDirectory[rsvp.userId]
        let name    = profile?.displayName ?? "Miembro"
        Button { context.onSelectMember(rsvp.userId) } label: {
            HStack(spacing: RuulSpacing.sm) {
                RuulAvatar(name: name, imageURL: profile?.avatarURL, size: .small)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .ruulTextStyle(RuulTypography.body)
                        .foregroundStyle(Color.ruulTextPrimary)
                    if rsvp.isCheckedIn, let arrived = rsvp.arrivedAt {
                        Text("Llegó \(arrived.ruulShortTime)")
                            .ruulTextStyle(RuulTypography.caption)
                            .foregroundStyle(Color.ruulPositive)
                    } else if rsvp.plusOnes > 0 {
                        Text("+\(rsvp.plusOnes)")
                            .ruulTextStyle(RuulTypography.caption)
                            .foregroundStyle(Color.ruulTextTertiary)
                    }
                }
                Spacer(minLength: 0)
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
        guard interactor == nil else { return }
        do {
            rsvps = try await app.rsvpRepo.rsvps(for: context.resource.id)
        } catch {
            rsvps = []
        }
    }
}
