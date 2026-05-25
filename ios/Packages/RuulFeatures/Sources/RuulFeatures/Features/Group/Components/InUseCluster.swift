import SwiftUI
import RuulUI
import RuulCore

/// "En uso" — cluster #4 de la doctrina situacional. Resources del
/// grupo que ahora mismo están con alguien: activos en custodia
/// (asset_current_custodian_view) + spaces con check-in activo
/// (space_occupancy_view). Slot in-use queda deferred — sus semánticas
/// no son inequívocas y la regla del founder ("no heurísticas
/// frágiles") aplica.
///
/// Auto-oculta si `items.isEmpty` (la decisión vive en
/// `GroupClusterStream`). Cap a 5 rows para mantener el home tight.
@MainActor
struct InUseCluster: View {
    let items: [InUseProjection]
    let members: [MemberWithProfile]
    let locale: String
    let onOpenResource: (UUID) -> Void

    private var visible: [InUseProjection] {
        Array(items.prefix(5))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text("En uso")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color(.tertiaryLabel))
                .padding(.leading, RuulSpacing.xxs)

            VStack(spacing: 0) {
                ForEach(visible) { item in
                    InUseRow(
                        item: item,
                        members: members,
                        locale: locale,
                        onTap: { onOpenResource(item.id) }
                    )
                    if item.id != visible.last?.id {
                        Divider()
                            .background(Color(.separator))
                            .padding(.leading, 64)
                    }
                }
            }
            .ruulCardSurface(.solid)
        }
    }
}

@MainActor
private struct InUseRow: View {
    let item: InUseProjection
    let members: [MemberWithProfile]
    let locale: String
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: RuulSpacing.md) {
                typeBadge

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                    Text(holderLine)
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Text(relativeTime(item.since))
                    .font(.caption2)
                    .foregroundStyle(Color(.tertiaryLabel))
                    .monospacedDigit()
            }
            .padding(RuulSpacing.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var typeBadge: some View {
        let (icon, tint) = typeStyle
        return Image(systemName: icon)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(tint)
            .frame(width: 40, height: 40)
            .background(tint.opacity(0.12), in: Circle())
    }

    private var typeStyle: (String, Color) {
        switch item.resourceType {
        case .asset: return ("shippingbox", GroupColorRamp.purple.accent)
        case .space: return ("building.2", GroupColorRamp.teal.accent)
        default:     return ("cube", Color.secondary)
        }
    }

    private var holderName: String {
        members
            .first(where: { $0.member.id == item.holderMemberId })?
            .displayName
            ?? "Alguien"
    }

    private var holderLine: String {
        switch item.resourceType {
        case .space: return "Ocupado por \(holderName)"
        default:     return "Con \(holderName)"
        }
    }

    private func relativeTime(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        f.locale = Locale(identifier: locale)
        return f.localizedString(for: date, relativeTo: .now)
    }
}
