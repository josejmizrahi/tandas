import SwiftUI
import RuulUI

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
    let onEditProfile: () -> Void
    let onSignOut: () -> Void
    /// DS v3 §6.2 — sección "Este grupo". Si los callbacks vienen, ProfileView
    /// renderiza la sección al final del scroll. Default = empty no-op para
    /// preservar compatibilidad de previews.
    let onOpenMembers: () -> Void
    let onOpenGovernance: () -> Void
    let onLeaveGroup: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            ProfileView(
                coordinator: profileCoordinator,
                onOpenMyFines: onOpenMyFines,
                onOpenHistory: onOpenHistory,
                onOpenSettings: onOpenSettings,
                onEditProfile: onEditProfile,
                onSignOut: onSignOut,
                groupScope: ProfileView.GroupScopeContext(
                    onOpenMembers: onOpenMembers,
                    onOpenGovernance: onOpenGovernance,
                    onLeaveGroup: onLeaveGroup
                )
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
