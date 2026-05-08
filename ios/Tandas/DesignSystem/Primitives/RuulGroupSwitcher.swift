import SwiftUI
import RuulUI
import RuulCore

/// Pill button en header de tabs Grupo/Historial/Ajustes. Muestra grupo activo,
/// abre `RuulGroupSwitcherSheet` al tap. Per DS v3 §3.13.
///
/// Acepta categoría explícita hasta que Fase 2 agregue `Group.category`.
/// Cuando Fase 2 land, se simplifica.
public struct RuulGroupSwitcher: View {
    private let activeGroupName: String
    private let activeCategory: GroupCategory
    private let activeInitials: String?
    private let onTap: () -> Void

    public init(
        activeGroupName: String,
        activeCategory: GroupCategory,
        activeInitials: String? = nil,
        onTap: @escaping () -> Void
    ) {
        self.activeGroupName = activeGroupName
        self.activeCategory = activeCategory
        self.activeInitials = activeInitials
        self.onTap = onTap
    }

    public var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                RuulGroupAvatar(
                    groupName: activeGroupName,
                    initials: activeInitials,
                    category: activeCategory,
                    size: .sm
                )
                // Crossfade key: SwiftUI re-rendea avatar cuando el id cambia,
                // y .transition(.opacity) hace fade entre old/new identity.
                .id("\(activeGroupName)-\(activeCategory.rawValue)")
                .transition(.opacity)
                Text(activeGroupName)
                    .font(.ruulTitleSmall)
                    .foregroundStyle(Color.ruulTextPrimary)
                    .lineLimit(1)
                    .id(activeGroupName)
                    .transition(.opacity)
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.ruulTextSecondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            // No `interactive: true` — iOS 26.x swallows taps in small frames.
            .ruulGlass(Capsule(), material: .regular)
            .animation(.ruulGroupSwitch, value: activeGroupName)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Grupo activo: \(activeGroupName). Toca para cambiar.")
    }
}

#if DEBUG
#Preview("RuulGroupSwitcher") {
    VStack(spacing: RuulSpacing.md) {
        RuulGroupSwitcher(
            activeGroupName: "Cena del Jueves",
            activeCategory: .socialRecurring,
            onTap: {}
        )
        RuulGroupSwitcher(
            activeGroupName: "Tanda Marzo 2026",
            activeCategory: .rotatingSavings,
            onTap: {}
        )
    }
    .padding(RuulSpacing.lg)
    .background(Color.ruulBackground)
}
#endif
