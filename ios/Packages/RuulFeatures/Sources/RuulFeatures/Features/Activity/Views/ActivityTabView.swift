import SwiftUI
import RuulUI
import RuulCore

/// Tab "Actividad" per DS v3 §6.2 — timeline de SystemEvents del grupo activo
/// con header de RuulGroupSwitcher.
///
/// **No conectado a MainTabView todavía** — Fase 4b hará el swap.
@MainActor
public struct ActivityTabView: View {
    public let activeGroup: RuulCore.Group
    public let onSwitchGroup: () -> Void
    /// `ActivityView` usa `@State var coordinator` (no `@Bindable`),
    /// así que se pasa por valor al child y este lo adopta como state propio.
    public let coordinator: ActivityCoordinator
    /// Optional: forward al `ActivityView` para mostrar CTA
    /// "Ver multa / Ver voto / etc." en el detail sheet. El router real
    /// vive en `MainTabView.routeFromHistoryEvent(_:)`.
    public var onOpenRelated: ((SystemEvent) -> Void)? = nil

    public init(activeGroup: RuulCore.Group, onSwitchGroup: @escaping () -> Void, coordinator: ActivityCoordinator, onOpenRelated: ((SystemEvent) -> Void)? = nil) {
        self.activeGroup = activeGroup
        self.onSwitchGroup = onSwitchGroup
        self.coordinator = coordinator
        self.onOpenRelated = onOpenRelated
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            ActivityView(coordinator: coordinator, onOpenRelated: onOpenRelated)
        }
    }

    private var header: some View {
        HStack {
            // Beta 1 W3 A-3.5: convenience init for API consistency. This
            // surface is currently orphan per §7 hide list — kept aligned
            // anyway so a future revival doesn't drift.
            RuulGroupSwitcher(activeGroup: activeGroup, onTap: onSwitchGroup)
            Spacer()
        }
        .padding(.horizontal, RuulSpacing.screenPadding)
        .padding(.vertical, RuulSpacing.md)
    }
}

#if DEBUG
#Preview("ActivityTabView") {
    Text("ActivityTabView preview requires RuulCore.Group + ActivityCoordinator fixtures.")
        .padding(RuulSpacing.lg)
        .background(Color.ruulBackground)
}
#endif
