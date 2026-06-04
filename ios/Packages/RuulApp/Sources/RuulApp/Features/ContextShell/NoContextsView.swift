import SwiftUI
import RuulCore

/// F.3 — empty state cuando el usuario no tiene contextos colectivos ni
/// personal cargable (caso outsider). CTAs: crear contexto o unirse con código.
public struct NoContextsView: View {
    let onCreate: () -> Void
    let onJoin: () -> Void
    let onSignOut: () -> Void
    let pendingInvitationsCount: Int
    let onOpenInvitations: (() -> Void)?

    public init(
        onCreate: @escaping () -> Void,
        onJoin: @escaping () -> Void,
        onSignOut: @escaping () -> Void,
        pendingInvitationsCount: Int = 0,
        onOpenInvitations: (() -> Void)? = nil
    ) {
        self.onCreate = onCreate
        self.onJoin = onJoin
        self.onSignOut = onSignOut
        self.pendingInvitationsCount = pendingInvitationsCount
        self.onOpenInvitations = onOpenInvitations
    }

    public var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "person.3.sequence")
                .font(.system(size: 56))
                .foregroundStyle(.tint)

            VStack(spacing: 8) {
                Text("Bienvenido a Ruul")
                    .font(.title2.weight(.semibold))
                Text("Crea tu primer contexto (una cena semanal, tu familia, un viaje…) o únete a uno con un código de invitación.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)

            VStack(spacing: 12) {
                if pendingInvitationsCount > 0, let onOpenInvitations {
                    Button(action: onOpenInvitations) {
                        Label(
                            "Tienes \(pendingInvitationsCount) invitación\(pendingInvitationsCount == 1 ? "" : "es")",
                            systemImage: "tray.full"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .tint(.orange)
                }

                Button(action: onCreate) {
                    Label("Crear contexto", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)

                Button(action: onJoin) {
                    Label("Unirme con código", systemImage: "ticket")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
            }
            .padding(.horizontal, 24)

            Spacer()

            Button(role: .destructive, action: onSignOut) {
                Text("Cerrar sesión")
                    .font(.footnote)
            }
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Surface.appBackground)
    }
}

#Preview("Sin contextos") {
    NoContextsView(onCreate: {}, onJoin: {}, onSignOut: {})
}

#Preview("Sin contextos · con invitaciones") {
    NoContextsView(
        onCreate: {},
        onJoin: {},
        onSignOut: {},
        pendingInvitationsCount: 2,
        onOpenInvitations: {}
    )
}
