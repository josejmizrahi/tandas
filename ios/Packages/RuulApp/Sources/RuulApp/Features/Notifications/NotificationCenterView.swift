import SwiftUI
import RuulCore

/// R.4D (P1.1) — centro de notificaciones. Lista de `notifications` del
/// caller con leído/no-leído, archivar por swipe y "marcar todas".
/// Tap → marca leída y navega al objeto vía AttentionDispatcher (scope-based).
public struct NotificationCenterView: View {
    let container: DependencyContainer

    @State private var runner = ActionRunner()

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
            Task { await store.markRead(notification) }
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
}

#Preview("Centro de notificaciones") {
    NavigationStack {
        NotificationCenterView(container: .demo())
    }
}
