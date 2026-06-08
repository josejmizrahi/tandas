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
    //
    // Diseño post-device review (founder 2026-06-07):
    // - No duplicar "Próximamente" en subtitle + capsule trailing. La capsule
    //   trailing es suficiente (más prominente, más iOS-native).
    // - Iconos comingSoon usan Theme.Text.secondary (no tertiary) — más legibles.
    // - Dangerous NO usa triangle warning trailing — el tint rojo del label
    //   ya comunica el riesgo. La confirmación dialog cubre la seguridad.
    // - requiresDecision usa subtitle informativo (sin trailing badge) —
    //   "Requiere decisión grupal" como hint.

    private var iconTint: Color {
        switch state {
        case .enabled:          return Theme.Tint.primary
        case .disabled:         return Theme.Text.tertiary
        case .requiresDecision: return Theme.Tint.info
        case .comingSoon:       return Theme.Text.secondary
        case .dangerous:        return Theme.Tint.critical
        }
    }

    private var labelTint: Color {
        switch state {
        case .enabled:          return Theme.Text.primary
        case .disabled:         return Theme.Text.tertiary
        case .requiresDecision: return Theme.Text.primary
        case .comingSoon:       return Theme.Text.secondary
        case .dangerous:        return Theme.Tint.critical
        }
    }

    /// Subtitle SOLO cuando agrega información (reason para disabled,
    /// hint para requiresDecision). NO en comingSoon (la capsule trailing
    /// lo dice) ni en dangerous (el tint del label basta).
    private var subtitle: String? {
        switch state {
        case .enabled:                 return nil
        case .disabled(let reason):    return reason
        case .requiresDecision:        return "Requiere decisión grupal"
        case .comingSoon:              return nil
        case .dangerous:               return nil
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch state {
        case .comingSoon:
            Text("Próximamente")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, Theme.Spacing.sm)
                .padding(.vertical, 3)
                .background(Color(uiColor: .systemGray5), in: Capsule())
                .foregroundStyle(Theme.Text.secondary)
        case .enabled, .disabled, .requiresDecision, .dangerous:
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
