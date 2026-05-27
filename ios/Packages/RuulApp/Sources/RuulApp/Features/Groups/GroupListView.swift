import SwiftUI
import RuulCore

/// First authenticated screen of the Foundation shell — the caller's
/// groups. Slice 4a renders the list, exposes "Nuevo grupo" + "Cerrar
/// sesión", and refreshes via `GroupsStore.refresh()`. Row taps are a
/// no-op until slice 4b lands the group home view.
struct GroupListView: View {
    let container: DependencyContainer

    @State private var isShowingCreateSheet: Bool = false

    var body: some View {
        List {
            switch container.groupsStore.phase {
            case .idle, .loading:
                Section {
                    HStack {
                        Spacer()
                        ProgressView()
                            .padding(.vertical, 24)
                        Spacer()
                    }
                }
            case .failed(let message):
                Section {
                    ContentUnavailableView {
                        Label("No pudimos cargar tus grupos", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Reintentar") {
                            Task { await container.groupsStore.refresh() }
                        }
                    }
                }
            case .loaded:
                if container.groupsStore.groups.isEmpty {
                    Section {
                        ContentUnavailableView {
                            Label("Aún no tienes grupos", systemImage: "person.3")
                        } description: {
                            Text("Crea uno nuevo para empezar a coordinar con tu gente.")
                        } actions: {
                            Button {
                                isShowingCreateSheet = true
                            } label: {
                                Label("Crear grupo", systemImage: "plus")
                            }
                            .buttonStyle(.glassProminent)
                        }
                    }
                } else {
                    Section {
                        ForEach(container.groupsStore.groups) { group in
                            GroupRow(group: group)
                        }
                    }
                }
            }
        }
        .navigationTitle("Mis grupos")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isShowingCreateSheet = true
                } label: {
                    Label("Nuevo", systemImage: "plus")
                }
            }
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Button(role: .destructive) {
                        Task { await container.sessionStore.signOut() }
                    } label: {
                        Label("Cerrar sesión", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                } label: {
                    Label("Cuenta", systemImage: "person.circle")
                }
            }
        }
        .refreshable {
            await container.groupsStore.refresh()
        }
        .task {
            await container.groupsStore.refresh()
        }
        .sheet(isPresented: $isShowingCreateSheet) {
            CreateGroupView(container: container) {
                isShowingCreateSheet = false
                Task { await container.groupsStore.refresh() }
            }
        }
    }
}

private struct GroupRow: View {
    let group: GroupListItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(group.name)
                .font(.headline)
            if let summary = group.purposeSummary, !summary.isEmpty {
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else if let category = group.category, !category.isEmpty {
                Text(category)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
