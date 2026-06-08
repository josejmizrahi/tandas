import SwiftUI

/// R.5V.2 — Action row canónico siguiendo UX Doctrine §0.4.
///
/// **5 estados de acción** que toda acción visible respeta:
///
/// 1. `enabled`           — tappable, ejecutable end-to-end
/// 2. `disabled(reason)`  — sin permiso o gate backend; muestra reason
/// 3. `requiresDecision`  — execution_mode='request_decision' (vota grupal)
/// 4. `comingSoon`        — catalog seedea pero NO RPC dispatch backend
/// 5. `dangerous`         — irreversible, requiere confirmación
///
/// Cierra el gap §0.4 del R.5V.0 audit: `QuickActionsSection` legacy sólo
/// renderiza 2/5 estados (enabled/disabled). RuulActionRow renderiza los 5.
public struct RuulActionRow: View {
    public enum State: Sendable, Equatable {
        case enabled
        case disabled(reason: String?)
        case requiresDecision
        case comingSoon
        case dangerous
    }

    public let label: String
    public let systemImage: String
    public let state: State
    public let action: () -> Void

    public init(
        _ label: String,
        systemImage: String,
        state: State = .enabled,
        action: @escaping () -> Void
    ) {
        self.label = label
        self.systemImage = systemImage
        self.state = state
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.md) {
                Image(systemName: systemImage)
                    .font(.body)
                    .foregroundStyle(iconTint)
                    .frame(width: Theme.IconSize.sm)
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text(label)
                        .font(.body)
                        .foregroundStyle(labelTint)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(Theme.Text.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer()
                trailing
                if isTappable {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.Text.tertiary)
                }
            }
            .padding(.vertical, Theme.Spacing.xxs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isTappable)
    }

    // MARK: - Derived visual state

    private var iconTint: Color {
        switch state {
        case .enabled:          return Theme.Tint.primary
        case .disabled:         return Theme.Text.tertiary
        case .requiresDecision: return Theme.Tint.info
        case .comingSoon:       return Theme.Text.tertiary
        case .dangerous:        return Theme.Tint.critical
        }
    }

    private var labelTint: Color {
        switch state {
        case .enabled:          return Theme.Text.primary
        case .disabled:         return Theme.Text.tertiary
        case .requiresDecision: return Theme.Text.primary
        case .comingSoon:       return Theme.Text.tertiary
        case .dangerous:        return Theme.Tint.critical
        }
    }

    private var subtitle: String? {
        switch state {
        case .enabled:                 return nil
        case .disabled(let reason):    return reason
        case .requiresDecision:        return "Requiere decisión grupal"
        case .comingSoon:              return "Próximamente"
        case .dangerous:               return nil
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch state {
        case .requiresDecision:
            Image(systemName: "checkmark.bubble.fill")
                .font(.caption2)
                .foregroundStyle(Theme.Tint.info)
        case .comingSoon:
            Text("Próximamente")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, Theme.Spacing.sm)
                .padding(.vertical, 2)
                .background(Color(uiColor: .systemGray5), in: Capsule())
                .foregroundStyle(Theme.Text.secondary)
        case .dangerous:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(Theme.Tint.critical)
        case .enabled, .disabled:
            EmptyView()
        }
    }

    private var isTappable: Bool {
        switch state {
        case .enabled, .dangerous, .requiresDecision: return true
        case .disabled, .comingSoon:                   return false
        }
    }
}

#Preview {
    List {
        RuulActionRow("Otorgar derecho", systemImage: "person.badge.key", action: {})
        RuulActionRow(
            "Aprobar reserva",
            systemImage: "checkmark.circle",
            state: .disabled(reason: "Sin permiso para administrar reservaciones"),
            action: {}
        )
        RuulActionRow(
            "Transferir propiedad",
            systemImage: "arrow.left.arrow.right",
            state: .requiresDecision,
            action: {}
        )
        RuulActionRow(
            "Registrar contribución",
            systemImage: "arrow.down.circle",
            state: .comingSoon,
            action: {}
        )
        RuulActionRow(
            "Archivar recurso",
            systemImage: "archivebox",
            state: .dangerous,
            action: {}
        )
    }
}
