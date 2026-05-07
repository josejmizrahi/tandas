import SwiftUI

/// Tab "Historial" per DS v3 §6.2 — timeline de SystemEvents del grupo activo
/// con header de RuulGroupSwitcher.
///
/// **No conectado a MainTabView todavía** — Fase 4b hará el swap.
@MainActor
struct HistoryTabView: View {
    let activeGroup: Group
    let onSwitchGroup: () -> Void
    /// `GroupHistoryView` usa `@State var coordinator` (no `@Bindable`),
    /// así que se pasa por valor al child y este lo adopta como state propio.
    let coordinator: GroupHistoryCoordinator

    var body: some View {
        VStack(spacing: 0) {
            header
            GroupHistoryView(coordinator: coordinator)
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
    Text("HistoryTabView preview requires Group + GroupHistoryCoordinator fixtures.")
        .padding(RuulSpacing.lg)
        .background(Color.ruulBackground)
}
#endif
