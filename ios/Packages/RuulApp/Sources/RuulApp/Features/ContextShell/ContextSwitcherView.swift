import SwiftUI
import RuulCore

/// F.3 — switcher de contexto. Menu en el toolbar: lista los contextos del
/// usuario (persona + colectivos), marca el activo y persiste el cambio.
/// El perfil del usuario vive aparte en `ProfileAvatarMenu` (top-right).
public struct ContextSwitcherMenu: View {
    let contextStore: ContextStore
    let invitationsStore: InvitationsStore?
    let onCreate: () -> Void
    let onJoin: () -> Void
    let onOpenContextSettings: () -> Void
    let onOpenInvitations: (() -> Void)?

    public init(
        contextStore: ContextStore,
        invitationsStore: InvitationsStore? = nil,
        onCreate: @escaping () -> Void,
        onJoin: @escaping () -> Void,
        onOpenContextSettings: @escaping () -> Void = {},
        onOpenInvitations: (() -> Void)? = nil
    ) {
        self.contextStore = contextStore
        self.invitationsStore = invitationsStore
        self.onCreate = onCreate
        self.onJoin = onJoin
        self.onOpenContextSettings = onOpenContextSettings
        self.onOpenInvitations = onOpenInvitations
    }

    private var pendingCount: Int {
        invitationsStore?.invitations.count ?? 0
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

            // F.1A-2 — Configuración del contexto activo (solo colectivos)
            if let current = contextStore.currentContext, !current.isPersonal {
                Section {
                    Button(action: onOpenContextSettings) {
                        Label("Configuración del contexto", systemImage: "gearshape")
                    }
                }
            }

            if pendingCount > 0, let onOpenInvitations {
                Section {
                    Button(action: onOpenInvitations) {
                        Label("Invitaciones (\(pendingCount))", systemImage: "tray.full")
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
        } label: {
            HStack(spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: contextStore.currentContext?.symbolName ?? "person.crop.circle")
                    if pendingCount > 0 {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 8, height: 8)
                            .offset(x: 4, y: -4)
                            .accessibilityHidden(true)
                    }
                }
                Text(contextStore.currentContext?.displayName ?? "Contexto")
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
            }
            .font(.subheadline.weight(.semibold))
            .accessibilityLabel(
                pendingCount > 0
                    ? "\(contextStore.currentContext?.displayName ?? "Contexto"). \(pendingCount) invitaciones pendientes"
                    : (contextStore.currentContext?.displayName ?? "Contexto")
            )
        }
    }
}

/// F.1A-1 — avatar del usuario en el top-right. Menu con configuración y logout.
public struct ProfileAvatarMenu: View {
    let currentActorStore: CurrentActorStore
    let onOpenSettings: () -> Void
    let onSignOut: () -> Void

    public init(
        currentActorStore: CurrentActorStore,
        onOpenSettings: @escaping () -> Void,
        onSignOut: @escaping () -> Void
    ) {
        self.currentActorStore = currentActorStore
        self.onOpenSettings = onOpenSettings
        self.onSignOut = onSignOut
    }

    public var body: some View {
        Menu {
            if let name = currentActorStore.actor?.displayName, !name.isEmpty {
                Text(name)
            }
            Section {
                Button(action: onOpenSettings) {
                    Label("Configuración", systemImage: "gearshape")
                }
                Button(role: .destructive, action: onSignOut) {
                    Label("Cerrar sesión", systemImage: "rectangle.portrait.and.arrow.right")
                }
            }
        } label: {
            ActorInitialsView(
                name: currentActorStore.actor?.displayName ?? "?",
                size: 32
            )
            .accessibilityLabel("Mi configuración")
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
                        onJoin: {}
                    )
                }
                ToolbarItem(placement: .topBarTrailing) {
                    ProfileAvatarMenu(
                        currentActorStore: CurrentActorStore(
                            rpc: MockRuulRPCClient.demo(),
                            previewActor: CurrentActor(
                                actor: ActorRecord(
                                    id: UUID(),
                                    actorKind: .person,
                                    actorSubtype: "person",
                                    displayName: "José"
                                )
                            )
                        ),
                        onOpenSettings: {},
                        onSignOut: {}
                    )
                }
            }
    }
}
