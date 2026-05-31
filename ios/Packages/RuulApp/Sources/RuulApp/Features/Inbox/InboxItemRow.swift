import SwiftUI
import RuulCore

/// D.21B — Render compacto de una notificación.
/// Muestra categoría humanizada, cuerpo (payload.message), y hora relativa.
struct InboxItemRow: View {
    let item: InboxItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(item.isRead ? .secondary : .tint)
                .font(.title3)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(humanCategory)
                    .font(.subheadline.weight(item.isRead ? .regular : .semibold))
                    .foregroundStyle(.primary)

                Text(item.bodyText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 4) {
                Text(item.createdAt, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if !item.isRead {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 8, height: 8)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var systemImage: String {
        switch item.category {
        case "rule_consequence":      return "bolt.fill"
        case "sanction.issued":       return "exclamationmark.shield"
        case "decision.passed":       return "checkmark.circle"
        case "decision.rejected":     return "xmark.circle"
        case "member.joined":         return "person.crop.circle.badge.plus"
        case "money.expense_recorded": return "creditcard"
        case "money.settlement_recorded": return "arrow.left.arrow.right"
        case "dispute.opened":        return "scale.3d"
        case "mandate.expiring_in_24h": return "clock.badge.exclamationmark"
        default:                      return "bell"
        }
    }

    private var humanCategory: String {
        switch item.category {
        case "rule_consequence":         return "Regla aplicada"
        case "sanction.issued":          return "Nueva sanción"
        case "decision.passed":          return "Decisión aprobada"
        case "decision.rejected":        return "Decisión rechazada"
        case "member.joined":            return "Nuevo miembro"
        case "money.expense_recorded":   return "Gasto registrado"
        case "money.settlement_recorded": return "Liquidación registrada"
        case "dispute.opened":           return "Disputa abierta"
        case "mandate.expiring_in_24h":  return "Mandato por vencer"
        default:                         return item.category
        }
    }
}
