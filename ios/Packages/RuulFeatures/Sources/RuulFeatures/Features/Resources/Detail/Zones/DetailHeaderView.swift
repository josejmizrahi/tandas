import SwiftUI
import RuulUI
import RuulCore

/// The "identity" zone. Tells the user WHAT this is at a glance:
/// type icon + name + type label + status pill. Stays compact —
/// the deep visual hero (cover image, capacity bar, etc.) lives in
/// the type-specific full-screen detail when one exists.
public struct DetailHeaderView: View {
    public let context: ResourceDetailContext
    public let onMore: () -> Void

    public init(context: ResourceDetailContext, onMore: @escaping () -> Void = {}) {
        self.context = context
        self.onMore = onMore
    }

    public var body: some View {
        HStack(alignment: .top, spacing: RuulSpacing.md) {
            iconBadge
            VStack(alignment: .leading, spacing: 4) {
                Text(context.displayName)
                    .ruulTextStyle(RuulTypography.title)
                    .foregroundStyle(Color.ruulTextPrimary)
                    .lineLimit(2)
                HStack(spacing: RuulSpacing.xs) {
                    Text(typeLabel)
                        .ruulTextStyle(RuulTypography.caption)
                        .foregroundStyle(Color.ruulTextSecondary)
                    if !statusLabel.isEmpty {
                        Text("·").foregroundStyle(Color.ruulTextTertiary)
                        Text(statusLabel)
                            .ruulTextStyle(RuulTypography.caption)
                            .foregroundStyle(Color.ruulTextSecondary)
                    }
                }
            }
            Spacer()
            Menu {
                Button("Editar", systemImage: "pencil",
                       action: context.onPresentEditResource)
                Button("Activar capability", systemImage: "plus.circle",
                       action: context.onPresentEnableCapability)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(Color.ruulTextSecondary)
            }
            .accessibilityLabel("Más acciones")
        }
        .padding(.horizontal, RuulSpacing.xxs)
    }

    private var iconBadge: some View {
        ZStack {
            Circle()
                .fill(Color.ruulAccent.opacity(0.18))
                .frame(width: 52, height: 52)
            Image(systemName: iconFor(context.resource.resourceType))
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color.ruulAccent)
        }
    }

    private func iconFor(_ type: ResourceType) -> String {
        switch type {
        case .event:        return "calendar.badge.clock"
        case .asset:        return "key.fill"
        case .slot:         return "ticket"
        case .fund:         return "banknote"
        case .booking:      return "calendar.badge.checkmark"
        case .contribution: return "arrow.up.bin"
        case .position:     return "person.fill.badge.plus"
        case .assignment:   return "checkmark.square"
        case .rotation:     return "arrow.triangle.2.circlepath"
        case .guestPass:    return "person.crop.circle.badge.plus"
        case .proposal:     return "doc.text"
        case .unknown:      return "square.dashed"
        }
    }

    private var typeLabel: String {
        switch context.resource.resourceType {
        case .event:        return "Evento"
        case .asset:        return "Activo compartido"
        case .slot:         return "Slot"
        case .fund:         return "Fondo"
        case .booking:      return "Reserva"
        case .contribution: return "Aportación"
        case .position:     return "Posición"
        case .assignment:   return "Tarea"
        case .rotation:     return "Rotación"
        case .guestPass:    return "Invitado"
        case .proposal:     return "Propuesta"
        case .unknown(let raw): return raw
        }
    }

    private var statusLabel: String {
        let s = context.resource.status
        switch s.lowercased() {
        case "active", "open", "scheduled": return "Activo"
        case "closed":                      return "Cerrado"
        case "cancelled", "canceled":       return "Cancelado"
        case "archived":                    return "Archivado"
        default:                            return s.capitalized
        }
    }
}
