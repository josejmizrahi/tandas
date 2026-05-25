import SwiftUI
import RuulUI
import RuulCore

/// "Necesita atención" — cluster #1 de la doctrina situacional
/// (doctrine_group_space_situational, 2026-05-24). Absorbe lo que
/// antes era Pendientes + Decisiones: RSVPs, votos abiertos, multas
/// por pagar, approvals, rule-change proposals, appeals. El usuario
/// ve "algo que requiere que alguien haga algo" — sin importar el
/// tipo técnico detrás.
///
/// Auto-oculta si `items.isEmpty` — la decisión vive en
/// `GroupClusterStream`. Esta vista asume al menos un item.
@MainActor
struct AttentionCluster: View {
    let items: [UserAction]
    let onSelect: (UserAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text("Necesita atención")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color(.tertiaryLabel))
                .padding(.leading, RuulSpacing.xxs)

            VStack(spacing: 0) {
                ForEach(items) { item in
                    AttentionRow(item: item, onTap: { onSelect(item) })
                    if item.id != items.last?.id {
                        Divider()
                            .background(Color(.separator))
                            .padding(.leading, 64)
                    }
                }
            }
            .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.lg))
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.lg)
                    .stroke(Color(.separator), lineWidth: 0.5)
            )
        }
    }
}

@MainActor
private struct AttentionRow: View {
    let item: UserAction
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: RuulSpacing.md) {
                iconBadge

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                    if let body = item.body, !body.isEmpty {
                        Text(body)
                            .font(.caption)
                            .foregroundStyle(Color.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                Text(GroupPendingsBlock.cta(for: item.actionType))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.ruulTextInverse)
                    .padding(.horizontal, RuulSpacing.sm)
                    .padding(.vertical, RuulSpacing.xxs)
                    .background(
                        GroupPendingsBlock.tint(for: item.actionType),
                        in: Capsule()
                    )
            }
            .padding(RuulSpacing.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var iconBadge: some View {
        let tint = GroupPendingsBlock.tint(for: item.actionType)
        return ZStack(alignment: .topTrailing) {
            Image(systemName: GroupPendingsBlock.icon(for: item.actionType))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 40, height: 40)
                .background(tint.opacity(0.12), in: Circle())

            if item.priority == .urgent || item.priority == .high {
                Circle()
                    .fill(Color.ruulNegative)
                    .frame(width: 8, height: 8)
                    .overlay(Circle().strokeBorder(Color.ruulSurface, lineWidth: 2))
                    .offset(x: 2, y: -2)
            }
        }
    }
}
