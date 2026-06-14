import SwiftUI
import RuulCore

/// R.4D (P1.1) — centro de notificaciones. Lista de `notifications` del
/// caller con leído/no-leído, archivar por swipe y "marcar todas".
/// Tap → marca leída **y** navega al objeto vía AttentionDispatcher
/// (D2 re-audit 2026-06-14: el routing se introdujo aquí; antes solo se
/// marcaba leída).
public struct NotificationCenterView: View {
    let container: DependencyContainer

    @State private var runner = ActionRunner()
    /// D2 (re-audit 2026-06-14) — sheet con el destino resuelto por el
    /// AttentionDispatcher cuando el usuario toca una notificación.
    @State private var presentedDestination: AttentionDestination?

    public init(container: DependencyContainer) {
        self.container = container
    }

    private var store: NotificationsStore { container.notificationsStore }

    public var body: some View {
        Group {
            switch store.phase {
            case .idle, .loading:
                RuulLoadingState(title: "Cargando notificaciones…")
            case .failed(let message):
                RuulErrorState(message: message) {
                    Task { await store.load() }
                }
            case .loaded:
                content
            }
        }
        .navigationTitle("Notificaciones")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if store.unreadCount > 0 {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Marcar todas") {
                        Task { await runner.run { try await store.markAllRead() } }
                    }
                    .font(.subheadline)
                    .disabled(runner.isRunning)
                }
            }
        }
        .task { await store.load() }
        .refreshable { await store.load() }
        .actionErrorAlert(runner)
        .sheet(item: $presentedDestination) { destination in
            AttentionDestinationSheet(destination: destination, container: container)
        }
    }

    @ViewBuilder
    private var content: some View {
        if store.notifications.isEmpty {
            RuulEmptyState(
                title: "Sin notificaciones",
                systemImage: "bell",
                message: "Aquí verás avisos de tus espacios: decisiones nuevas, reglas que se dispararon y recordatorios."
            )
        } else {
            List {
                ForEach(store.notifications) { notification in
                    row(notification)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                Task { await runner.run { try await store.archive(notification) } }
                            } label: {
                                Label("Archivar", systemImage: "archivebox")
                            }
                        }
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    @ViewBuilder
    private func row(_ notification: RuulNotification) -> some View {
        Button {
            Task {
                await store.markRead(notification)
                // D2 (re-audit 2026-06-14) — además de marcar leída, enrutar al
                // objeto vía AttentionDispatcher (mismo patrón que HomeView /
                // ContextDetailViewV2 / AttentionBottomAccessory).
                if let destination = destination(for: notification) {
                    presentedDestination = destination
                }
            }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: notification.symbolName)
                    .font(.body)
                    .foregroundStyle(notification.isUnread ? Color.accentColor : Color.secondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(notification.title)
                        .font(.body.weight(notification.isUnread ? .semibold : .regular))
                        .foregroundStyle(.primary)
                    if let body = notification.body, !body.isEmpty {
                        Text(body)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Text(notification.createdAt.formatted(.relative(presentation: .named)))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
                if notification.isUnread {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 9, height: 9)
                        .padding(.top, 6)
                        .accessibilityLabel("No leída")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - D2 — RuulNotification → AttentionDestination

    /// Mapea una `RuulNotification` (tabla R.4D) al destino canónico del
    /// `AttentionDispatcher`. Equivale al `scopeBasedDestination(for:)` del
    /// dispatcher para `AttentionItem`, pero leyendo `targetType` / `targetId`
    /// del schema de notifications.
    ///
    /// Si la notificación no trae `targetId` (e.g., un anuncio general del
    /// contexto), cae a `.context` cuando hay `contextActorId`. Si ni eso, se
    /// silencia el routing y solo se marca leída.
    private func destination(for notification: RuulNotification) -> AttentionDestination? {
        let displayName = notification.contextActorId
            .flatMap { id in container.contextStore.availableContexts.first(where: { $0.id == id })?.displayName }
            ?? notification.title

        switch notification.targetType {
        case "decision":
            guard let id = notification.targetId, let ctx = notification.contextActorId else { return contextFallback(notification, displayName: displayName) }
            return .decision(decisionId: id, contextActorId: ctx)
        case "obligation":
            guard let id = notification.targetId, let ctx = notification.contextActorId else { return contextFallback(notification, displayName: displayName) }
            return .obligation(obligationId: id, contextActorId: ctx)
        case "settlement", "settlement_batch", "settlement_item":
            guard let ctx = notification.contextActorId else { return nil }
            return .settlement(contextActorId: ctx, highlightItemId: notification.targetId)
        case "resource":
            guard let id = notification.targetId, let ctx = notification.contextActorId else { return contextFallback(notification, displayName: displayName) }
            return .resourceDetail(resourceId: id, contextActorId: ctx)
        case "event":
            guard let id = notification.targetId, let ctx = notification.contextActorId else { return contextFallback(notification, displayName: displayName) }
            return .event(eventId: id, contextActorId: ctx, contextDisplayName: displayName)
        case "money_transaction":
            guard let ctx = notification.contextActorId else { return nil }
            return .money(contextActorId: ctx, contextDisplayName: displayName)
        case "context":
            guard let ctx = notification.contextActorId else { return nil }
            return .context(contextActorId: ctx, contextDisplayName: displayName)
        case "invitation":
            return .pendingInvitations
        default:
            // Reservation conflicts requieren resourceId — no expuesto en
            // `notifications`. Caemos a `.context` cuando hay ctx; si no, no
            // navegamos (la notif queda como leída sin sheet).
            return contextFallback(notification, displayName: displayName)
        }
    }

    private func contextFallback(_ notification: RuulNotification, displayName: String) -> AttentionDestination? {
        guard let ctx = notification.contextActorId else { return nil }
        return .context(contextActorId: ctx, contextDisplayName: displayName)
    }
}

#Preview("Centro de notificaciones") {
    NavigationStack {
        NotificationCenterView(container: .demo())
    }
}
