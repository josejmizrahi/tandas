import SwiftUI

/// Tab "Ajustes" per DS v3 §6.2 — dual scope:
///   - Sección "Tu cuenta" (global): perfil personal, notificaciones
///   - Sección "Este grupo" (grupo-activo, con switcher): members, governance, danger zone
///
/// V1 reusa ProfileView completo como contenido principal. Sección "Este grupo"
/// se queda como placeholder hasta que Fase 5 le ponga affordances reales.
///
/// **No conectado a MainTabView todavía** — Fase 4b hará el swap.
@MainActor
struct SettingsTabView: View {
    let activeGroup: Group
    let onSwitchGroup: () -> Void
    /// `ProfileView` usa `@State var coordinator`, no `@Bindable`, así que
    /// recibimos la instancia por valor y la pasamos al child.
    let profileCoordinator: ProfileCoordinator
    let onOpenMyFines: () -> Void
    let onOpenHistory: () -> Void
    let onOpenSettings: () -> Void
    let onSignOut: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            ProfileView(
                coordinator: profileCoordinator,
                onOpenMyFines: onOpenMyFines,
                onOpenHistory: onOpenHistory,
                onOpenSettings: onOpenSettings,
                onSignOut: onSignOut
            )
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
#Preview("SettingsTabView") {
    Text("SettingsTabView preview requires Group + ProfileCoordinator fixtures.")
        .padding(RuulSpacing.lg)
        .background(Color.ruulBackground)
}
#endif
