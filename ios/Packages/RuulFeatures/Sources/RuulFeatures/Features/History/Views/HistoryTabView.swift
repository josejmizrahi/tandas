import SwiftUI
import RuulUI
import RuulCore

/// Tab "Historial" per DS v3 §6.2 — timeline de SystemEvents del grupo activo
/// con header de RuulGroupSwitcher.
///
/// **No conectado a MainTabView todavía** — Fase 4b hará el swap.
@MainActor
public struct HistoryTabView: View {
    public let activeGroup: RuulCore.Group
    public let onSwitchGroup: () -> Void
    /// `GroupHistoryView` usa `@State var coordinator` (no `@Bindable`),
    /// así que se pasa por valor al child y este lo adopta como state propio.
    public let coordinator: GroupHistoryCoordinator
    /// Optional: forward al `GroupHistoryView` para mostrar CTA
    /// "Ver multa / Ver voto / etc." en el detail sheet. El router real
    /// vive en `MainTabView.routeFromHistoryEvent(_:)`.
    public var onOpenRelated: ((SystemEvent) -> Void)? = nil

    public init(activeGroup: RuulCore.Group, onSwitchGroup: @escaping () -> Void, coordinator: GroupHistoryCoordinator, onOpenRelated: ((SystemEvent) -> Void)? = nil) {
        self.activeGroup = activeGroup
        self.onSwitchGroup = onSwitchGroup
        self.coordinator = coordinator
        self.onOpenRelated = onOpenRelated
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            GroupHistoryView(coordinator: coordinator, onOpenRelated: onOpenRelated)
        }
    }

    private var header: some View {
        HStack {
            RuulGroupSwitcher(
                activeGroupName: activeGroup.name,
                activeCategory: activeGroup.category,
                activeInitials: activeGroup.initials,
                onTap: onSwitchGroup
            )
            Spacer()
        }
        .padding(.horizontal, RuulSpacing.screenPadding)
        .padding(.vertical, RuulSpacing.md)
    }
}

#if DEBUG
#Preview("HistoryTabView") {
    Text("HistoryTabView preview requires RuulCore.Group + GroupHistoryCoordinator fixtures.")
        .padding(RuulSpacing.lg)
        .background(Color.ruulBackground)
}
#endif
