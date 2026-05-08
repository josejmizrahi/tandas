import SwiftUI
import RuulUI
import RuulCore

/// Sprint 1b placeholders for the new tabs. Sprint 1c replaces these with
/// `ActionInboxView`, `RulesView`, `ProfileView` respectively. Each stub
/// uses the same monochrome canvas + EmptyStateView pattern so the chrome
/// is consistent with the rest of the app while we build them out.

public struct InboxTabStub: View {
    public var body: some View {
        ZStack {
            Color.ruulBackground.ignoresSafeArea()
            EmptyStateView(
                systemImage: "tray.fill",
                title: "Inbox",
                message: "Aquí van a aparecer multas pendientes, apelaciones por votar y RSVPs sin contestar. Próximamente."
            )
        }
    }
}

public struct RulesTabStub: View {
    public var body: some View {
        ZStack {
            Color.ruulBackground.ignoresSafeArea()
            EmptyStateView(
                systemImage: "list.bullet.clipboard.fill",
                title: "Reglas",
                message: "Las 5 reglas del template ya están activas en el servidor. La pantalla para verlas y editarlas llega en el siguiente sprint."
            )
        }
    }
}

public struct ProfileTabStub: View {
    @Environment(AppState.self) private var app

    public var body: some View {
        ZStack {
            Color.ruulBackground.ignoresSafeArea()
            VStack(spacing: RuulSpacing.lg) {
                if let profile = app.profile {
                    RuulAvatar(name: profile.displayName, imageURL: nil, size: .hero)
                    Text(profile.displayName)
                        .ruulTextStyle(RuulTypography.title)
                        .foregroundStyle(Color.ruulTextPrimary)
                    if let phone = profile.phone {
                        Text(phone)
                            .ruulTextStyle(RuulTypography.callout)
                            .foregroundStyle(Color.ruulTextSecondary)
                    }
                }
                Text("Próximamente: tu historial, ajustes del grupo, y salir.")
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextTertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, RuulSpacing.xxl)
            }
            .padding(RuulSpacing.xxl)
        }
    }
}
