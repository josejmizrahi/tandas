import SwiftUI

/// R.5V.2 — Badge de estado canónico siguiendo UX Doctrine §0.3.
///
/// **6 estados universales** que cualquier objeto Ruul (Context, Resource,
/// Decision, Reservation, Obligation, Conflict, Document, Event, Rule, Policy)
/// soporta con representación visual consistente.
///
/// Estados legacy (e.g. decision `approved/rejected/executed`) se mapean a los
/// 6 canonical vía `RuulStatusBadge.canonical(from:domain:)` cuando sea necesario.
public struct RuulStatusBadge: View {
    public enum State: String, Sendable {
        case active, inactive, archived, pending, completed, cancelled

        /// Símbolo SF Symbol canónico para este estado.
        public var systemImage: String {
            switch self {
            case .active:    return "checkmark.circle.fill"
            case .inactive:  return "circle.dashed"
            case .archived:  return "archivebox.fill"
            case .pending:   return "clock.fill"
            case .completed: return "checkmark.seal.fill"
            case .cancelled: return "xmark.octagon.fill"
            }
        }

        /// Tint semántico para este estado.
        public var tint: Color {
            switch self {
            case .active:    return Theme.Tint.success
            case .inactive:  return Color(uiColor: .systemGray)
            case .archived:  return Theme.Tint.warning
            case .pending:   return .yellow
            case .completed: return .indigo
            case .cancelled: return Theme.Tint.critical
            }
        }

        /// Label en español.
        public var label: String {
            switch self {
            case .active:    return "Activo"
            case .inactive:  return "Inactivo"
            case .archived:  return "Archivado"
            case .pending:   return "Pendiente"
            case .completed: return "Completado"
            case .cancelled: return "Cancelado"
            }
        }
    }

    public let state: State
    public let label: String?

    public init(_ state: State, label: String? = nil) {
        self.state = state
        self.label = label
    }

    public var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Image(systemName: state.systemImage)
                .font(.caption2.weight(.semibold))
            Text(label ?? state.label)
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, 3)
        .background(state.tint.badgeFill, in: Capsule())
        .foregroundStyle(state.tint)
    }
}

// MARK: - Mapping helpers (legacy domain → universal canonical)

public extension RuulStatusBadge.State {
    /// Mapea status legacy de Resource (`active/inactive/archived`).
    static func resource(_ raw: String) -> RuulStatusBadge.State {
        switch raw {
        case "active":   return .active
        case "inactive": return .inactive
        case "archived": return .archived
        default:         return .active
        }
    }

    /// Mapea status legacy de Decision (`open/approved/rejected/executed/cancelled`).
    static func decision(_ raw: String) -> RuulStatusBadge.State {
        switch raw {
        case "open":      return .pending
        case "approved":  return .active
        case "executed":  return .completed
        case "rejected",
             "cancelled": return .cancelled
        default:          return .active
        }
    }

    /// Mapea status legacy de Reservation
    /// (`requested/approved/confirmed/rejected/cancelled/completed/waitlisted`).
    static func reservation(_ raw: String) -> RuulStatusBadge.State {
        switch raw {
        case "requested",
             "approved",
             "waitlisted":   return .pending
        case "confirmed":    return .active
        case "completed":    return .completed
        case "rejected",
             "cancelled":    return .cancelled
        default:             return .active
        }
    }

    /// Mapea status legacy de Obligation
    /// (`open/accepted/in_progress/completed/expired/settled/cancelled/forgiven/disputed`).
    static func obligation(_ raw: String) -> RuulStatusBadge.State {
        switch raw {
        case "open",
             "accepted",
             "in_progress": return .pending
        case "completed",
             "settled":     return .completed
        case "expired":     return .archived
        case "cancelled",
             "forgiven",
             "disputed":    return .cancelled
        default:            return .active
        }
    }
}

#Preview {
    VStack(spacing: 12) {
        RuulStatusBadge(.active)
        RuulStatusBadge(.inactive)
        RuulStatusBadge(.archived)
        RuulStatusBadge(.pending)
        RuulStatusBadge(.completed)
        RuulStatusBadge(.cancelled)
    }
    .padding()
}
