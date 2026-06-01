import SwiftUI
import RuulCore

/// D.21B — Bandeja in-app respaldada por `list_my_inbox`.
/// Hoy: lista cronológica reversa con secciones "No leídas" / "Anteriores",
/// swipe-to-mark-read, pull-to-refresh, mark-all-read en toolbar.
/// Out-of-scope: filtros avanzados, búsqueda, acciones inline.
public struct InboxView: View {
    @Bindable var store: InboxStore
    let scopeGroupId: UUID?

    public init(store: InboxStore, scopeGroupId: UUID? = nil) {
        self.store = store
        self.scopeGroupId = scopeGroupId
    }

    public var body: some View {
        Group {
            switch store.phase {
            case .idle, .loading where store.items.isEmpty:
                ProgressView().controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message) where store.items.isEmpty:
                ContentUnavailableView {
                    Label("No pudimos cargar tu bandeja", systemImage: "tray.fill")
                } description: {
                    Text(message)
                } actions: {
                    Button("Reintentar") {
                        Task { await store.refresh(groupId: scopeGroupId) }
                    }
                    .buttonStyle(.glassProminent)
                }
            default:
                listBody
            }
        }
        .navigationTitle("Bandeja")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if store.unreadCount > 0 {
                    Button {
                        Task { await store.markAllRead(groupId: scopeGroupId) }
                    } label: {
                        Label("Marcar todo como leído", systemImage: "checkmark.circle")
                    }
                }
            }
        }
        .refreshable {
            await store.refresh(groupId: scopeGroupId)
        }
        .task {
            await store.refreshIfNeeded(groupId: scopeGroupId)
        }
    }

    @ViewBuilder
    private var listBody: some View {
        if store.items.isEmpty {
            ContentUnavailableView(
                "Sin notificaciones",
                systemImage: "tray",
                description: Text("Cuando el grupo o tu Ruul hagan algo, aparecerá aquí.")
            )
        } else {
            List {
                if !store.unreadItems.isEmpty {
                    Section {
                        ForEach(store.unreadItems) { item in
                            InboxItemRow(item: item)
                                .swipeActions(edge: .trailing) {
                                    Button {
                                        Task { await store.markRead(item) }
                                    } label: {
                                        Label("Marcar leído", systemImage: "envelope.open")
                                    }
                                }
                                .onTapGesture {
                                    Task { await store.markRead(item) }
                                }
                        }
                    } header: {
                        Text("No leídas (\(store.unreadCount))")
                    }
                }

                if !store.readItems.isEmpty {
                    Section {
                        ForEach(store.readItems) { item in
                            InboxItemRow(item: item)
                        }
                    } header: {
                        Text("Anteriores")
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
    }
}
