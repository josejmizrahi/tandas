import SwiftUI
import RuulUI
import RuulCore

/// Tab "Ajustes" per DS v3 §6.2 — dual scope:
///   - Sección "Tu cuenta" (global): perfil personal, notificaciones
///   - Sección "Este grupo" (grupo-activo, con switcher): members, governance, danger zone
///
/// V1 reusa ProfileView completo como contenido principal. Sección "Este grupo"
/// se queda como placeholder hasta que Fase 5 le ponga affordances reales.
///
/// **No conectado a MainTabView todavía** — Fase 4b hará el swap.
@MainActor
public struct SettingsTabView: View {
    public let activeGroup: RuulCore.Group
    public let onSwitchGroup: () -> Void
    /// `ProfileView` usa `@State var coordinator`, no `@Bindable`, así que
    /// recibimos la instancia por valor y la pasamos al child.
    public let profileCoordinator: ProfileCoordinator
    public let onOpenMyFines: () -> Void
    public let onOpenMyLedger: () -> Void
    public let onOpenHistory: () -> Void
    public let onOpenSettings: () -> Void
    public let onEditProfile: () -> Void
    public let onSignOut: () -> Void
    /// DS v3 §6.2 — sección "Este grupo". Si los callbacks vienen, ProfileView
    /// renderiza la sección al final del scroll. Default = empty no-op para
    /// preservar compatibilidad de previews.
    public let onOpenMembers: () -> Void
    public let onOpenGovernance: () -> Void
    public let onLeaveGroup: () -> Void

    public init(activeGroup: RuulCore.Group, onSwitchGroup: @escaping () -> Void, profileCoordinator: ProfileCoordinator, onOpenMyFines: @escaping () -> Void, onOpenMyLedger: @escaping () -> Void, onOpenHistory: @escaping () -> Void, onOpenSettings: @escaping () -> Void, onEditProfile: @escaping () -> Void, onSignOut: @escaping () -> Void, onOpenMembers: @escaping () -> Void, onOpenGovernance: @escaping () -> Void, onLeaveGroup: @escaping () -> Void) {
        self.activeGroup = activeGroup
        self.onSwitchGroup = onSwitchGroup
        self.profileCoordinator = profileCoordinator
        self.onOpenMyFines = onOpenMyFines
        self.onOpenMyLedger = onOpenMyLedger
        self.onOpenHistory = onOpenHistory
        self.onOpenSettings = onOpenSettings
        self.onEditProfile = onEditProfile
        self.onSignOut = onSignOut
        self.onOpenMembers = onOpenMembers
        self.onOpenGovernance = onOpenGovernance
        self.onLeaveGroup = onLeaveGroup
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            ProfileView(
                coordinator: profileCoordinator,
                onOpenMyFines: onOpenMyFines,
                onOpenHistory: onOpenHistory,
                onOpenSettings: onOpenSettings,
                onEditProfile: onEditProfile,
                onSignOut: onSignOut,
                onOpenMyLedger: onOpenMyLedger,
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
    Text("SettingsTabView preview requires RuulCore.Group + ProfileCoordinator fixtures.")
        .padding(RuulSpacing.lg)
        .background(Color.ruulBackground)
}
#endif
