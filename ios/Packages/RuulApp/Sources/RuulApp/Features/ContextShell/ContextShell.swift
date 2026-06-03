import SwiftUI
import RuulCore

/// F.3 — navegación base context-first. Carga los contextos disponibles,
/// muestra el contexto activo y permite cambiarlo desde el switcher.
/// Sin tabs globales: el home del contexto es la raíz del NavigationStack.
public struct ContextShell: View {
    let container: DependencyContainer

    @Environment(\.scenePhase) private var scenePhase
    @State private var isShowingCreateContext = false
    @State private var isShowingJoinByCode = false
    @State private var isShowingPersonalSettings = false
    @State private var isShowingContextSettings = false
    @State private var isShowingInvitations = false
    @State private var prefilledInviteCode: String?

    public init(container: DependencyContainer) {
        self.container = container
    }

    private var contextStore: ContextStore { container.contextStore }

    public var body: some View {
        Group {
            switch contextStore.phase {
            case .idle, .loading:
                SessionLoadingView(message: "Cargando tus contextos…")

            case .failed(let message):
                ErrorStateView(title: "No pudimos cargar tus contextos", message: message) {
                    Task { await contextStore.load() }
                }

            case .loaded:
                if let context = contextStore.currentContext {
                    contextRoot(context)
                } else {
                    NoContextsView(
                        onCreate: { isShowingCreateContext = true },
                        onJoin: { isShowingJoinByCode = true },
                        onSignOut: { Task { await container.signOut() } },
                        pendingInvitationsCount: container.invitationsStore.invitations.count,
                        onOpenInvitations: { isShowingInvitations = true }
                    )
                }
            }
        }
        .task {
            await contextStore.load()
            await container.invitationsStore.load(actorId: container.currentActorStore.actorId)
        }
        // Refrescar la lista de contextos + invitaciones al volver del background.
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            Task {
                await contextStore.load()
                await container.invitationsStore.load(actorId: container.currentActorStore.actorId)
            }
        }
        // Invitación entrante por universal link / ruul:// — el código quedó
        // pendiente en el router (aunque haya llegado antes de pasar los gates).
        .onChange(of: container.deepLinks.pendingInviteCode, initial: true) { _, code in
            guard code != nil else { return }
            prefilledInviteCode = container.deepLinks.consumePendingInviteCode()
            isShowingJoinByCode = true
        }
        .sheet(isPresented: $isShowingCreateContext) {
            CreateContextView(container: container)
        }
        .sheet(isPresented: $isShowingJoinByCode, onDismiss: { prefilledInviteCode = nil }) {
            JoinByCodeView(container: container, prefilledCode: prefilledInviteCode)
        }
        .sheet(isPresented: $isShowingPersonalSettings) {
            PersonalSettingsView(container: container)
        }
        .sheet(isPresented: $isShowingContextSettings) {
            if let current = contextStore.currentContext, !current.isPersonal {
                ContextSettingsView(context: current, container: container)
            }
        }
        .sheet(isPresented: $isShowingInvitations) {
            PendingInvitationsView(container: container)
        }
    }

    @ViewBuilder
    private func contextRoot(_ context: AppContext) -> some View {
        NavigationStack {
            ContextHomeView(context: context, container: container)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        ContextSwitcherMenu(
                            contextStore: contextStore,
                            invitationsStore: container.invitationsStore,
                            onCreate: { isShowingCreateContext = true },
                            onJoin: { isShowingJoinByCode = true },
                            onOpenContextSettings: { isShowingContextSettings = true },
                            onOpenInvitations: { isShowingInvitations = true }
                        )
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        ProfileAvatarMenu(
                            currentActorStore: container.currentActorStore,
                            onOpenSettings: { isShowingPersonalSettings = true },
                            onSignOut: { Task { await container.signOut() } }
                        )
                    }
                }
        }
        // Rebuild completo al cambiar de contexto: cero estado compartido.
        .id(context.id)
    }
}

#Preview("Shell con contextos") {
    ContextShell(container: .demo())
}
