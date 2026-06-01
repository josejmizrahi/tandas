import SwiftUI
import RuulCore

/// D.22 — Search MVP sheet. One searchable list grouped by entity type
/// in a fixed section order (Miembros → Recursos → Decisiones → Reglas).
/// Empty sections render invisible. Result taps fire `onSelect(_:)` —
/// the host decides routing.
public struct SearchView: View {
    @Bindable var store: SearchStore
    let onSelect: (SearchResult) -> Void

    @Environment(\.dismiss) private var dismiss

    public init(store: SearchStore, onSelect: @escaping (SearchResult) -> Void) {
        self.store = store
        self.onSelect = onSelect
    }

    public var body: some View {
        NavigationStack {
            content
                .navigationTitle("Buscar")
                .navigationBarTitleDisplayMode(.inline)
                .searchable(
                    text: $store.query,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: Text("Buscá miembros, recursos, decisiones o reglas")
                )
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cerrar") {
                            store.clear()
                            dismiss()
                        }
                    }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        if store.query.trimmingCharacters(in: .whitespacesAndNewlines).count < 2 {
            emptyHint
        } else if store.isLoading && store.results.isEmpty {
            loadingState
        } else if let message = store.errorMessage, store.results.isEmpty {
            errorState(message)
        } else if store.results.isEmpty {
            noResultsState
        } else {
            resultsList
        }
    }

    @ViewBuilder
    private var emptyHint: some View {
        ContentUnavailableView(
            "Buscá lo que necesitás",
            systemImage: "magnifyingglass",
            description: Text("Mínimo 2 letras. Resultados se agrupan por tipo.")
        )
    }

    @ViewBuilder
    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Buscando…")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var noResultsState: some View {
        ContentUnavailableView.search(text: store.query)
    }

    @ViewBuilder
    private func errorState(_ message: String) -> some View {
        ContentUnavailableView(
            "No pudimos buscar",
            systemImage: "exclamationmark.triangle",
            description: Text(message)
        )
    }

    @ViewBuilder
    private var resultsList: some View {
        List {
            ForEach(store.groupedResults, id: \.section) { group in
                Section(group.section.sectionTitle) {
                    ForEach(group.items) { result in
                        Button {
                            onSelect(result)
                        } label: {
                            SearchResultRowView(result: result)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}
