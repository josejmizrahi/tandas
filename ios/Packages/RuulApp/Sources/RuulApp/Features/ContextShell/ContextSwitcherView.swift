import SwiftUI
import RuulCore

/// F.3 — switcher de contexto. Menu en el toolbar: lista los contextos del
/// usuario (persona + colectivos), marca el activo y persiste el cambio.
public struct ContextSwitcherMenu: View {
    let contextStore: ContextStore
    let onCreate: () -> Void
    let onJoin: () -> Void
    let onEditProfile: () -> Void
    let onSignOut: () -> Void

    public init(
        contextStore: ContextStore,
        onCreate: @escaping () -> Void,
        onJoin: @escaping () -> Void,
        onEditProfile: @escaping () -> Void,
        onSignOut: @escaping () -> Void
    ) {
        self.contextStore = contextStore
        self.onCreate = onCreate
        self.onJoin = onJoin
        self.onEditProfile = onEditProfile
        self.onSignOut = onSignOut
    }

    public var body: some View {
        Menu {
            Section("Mis contextos") {
                ForEach(contextStore.availableContexts) { context in
                    Button {
                        contextStore.switchTo(context)
                    } label: {
                        if context.id == contextStore.currentContext?.id {
                            Label(context.displayName, systemImage: "checkmark")
                        } else {
                            Label(context.displayName, systemImage: context.symbolName)
                        }
                    }
                }
            }

            Section {
                Button(action: onCreate) {
                    Label("Crear contexto", systemImage: "plus")
                }
                Button(action: onJoin) {
                    Label("Unirme con código", systemImage: "ticket")
                }
            }

            Section {
                Button(action: onEditProfile) {
                    Label("Tu perfil", systemImage: "person.crop.circle")
                }
                Button(role: .destructive, action: onSignOut) {
                    Label("Cerrar sesión", systemImage: "rectangle.portrait.and.arrow.right")
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: contextStore.currentContext?.symbolName ?? "person.crop.circle")
                Text(contextStore.currentContext?.displayName ?? "Contexto")
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
            }
            .font(.subheadline.weight(.semibold))
        }
    }
}

#Preview("Switcher") {
    NavigationStack {
        Text("Contenido")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ContextSwitcherMenu(
                        contextStore: ContextStore(
                            rpc: MockRuulRPCClient.demo(),
                            previewContexts: [
                                AppContext(id: UUID(), kind: .person, subtype: "person", displayName: "José"),
                                AppContext(id: UUID(), kind: .collective, subtype: "friend_group", displayName: "Cena Semanal", membershipType: "founder", memberCount: 5, roles: ["admin"])
                            ]
                        ),
                        onCreate: {},
                        onJoin: {},
                        onEditProfile: {},
                        onSignOut: {}
                    )
                }
            }
    }
}
