import SwiftUI
import RuulCore

/// F.NAV.4 — Context Switcher full sheet (estilo Apple Maps / Music / Notion).
/// Reemplaza el dropdown del switcher viejo. Trigger: tap sobre el título
/// del contexto en `ContextHomeContainer`.
///
/// Secciones:
///   - Favoritos (`preferencesStore.favorites`)
///   - Recientes (`preferencesStore.recents`)
///   - Todos (`contextStore.availableContexts`)
/// Acción inferior: ➕ Crear contexto.
///
/// Doctrina: la lista la da el backend; iOS sólo presenta + enruta.
public struct ContextSwitcherSheet: View {
    let container: DependencyContainer
    let currentContextId: UUID?
    let onSwitch: (AppContext) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var switchTrigger: Int = 0
    @State private var isShowingCreateContext = false
    /// 7.D.1 (audit 2026-06-14) — search bar local. Útil cuando el usuario
    /// pertenece a muchos espacios y no quiere scrollear hasta encontrar uno.
    @State private var searchText: String = ""

    public init(
        container: DependencyContainer,
        currentContextId: UUID?,
        onSwitch: @escaping (AppContext) -> Void
    ) {
        self.container = container
        self.currentContextId = currentContextId
        self.onSwitch = onSwitch
    }

    private var contextStore: ContextStore { container.contextStore }
    private var preferencesStore: ContextPreferencesStore { container.contextPreferencesStore }

    public var body: some View {
        NavigationStack {
            List {
                if isSearching {
                    searchResultsSection
                } else {
                    if !preferencesStore.favorites.isEmpty {
                        favoritesSection
                    }
                    if !preferencesStore.recents.isEmpty {
                        recentsSection
                    }
                    allContextsSection
                }
                createSection
            }
            .navigationTitle("Cambiar de espacio")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .automatic),
                prompt: "Buscar espacios"
            )
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cerrar") { dismiss() }
                }
            }
            .task {
                await preferencesStore.load()
                if contextStore.availableContexts.isEmpty {
                    await contextStore.load()
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .sensoryFeedback(.selection, trigger: switchTrigger)
        .sheet(isPresented: $isShowingCreateContext) {
            CreateContextView(container: container)
        }
    }

    // MARK: - Secciones

    @ViewBuilder
    private var favoritesSection: some View {
        Section {
            ForEach(preferencesStore.favorites) { pref in
                if let ctx = contextStore.availableContexts.first(where: { $0.id == pref.contextActorId }) {
                    contextRow(ctx)
                }
            }
        } header: {
            Label("Favoritos", systemImage: "star.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.yellow)
        }
    }

    @ViewBuilder
    private var recentsSection: some View {
        let favoriteIds = Set(preferencesStore.favorites.map(\.contextActorId))
        let nonFavRecents = preferencesStore.recents.filter { !favoriteIds.contains($0.contextActorId) }
        if !nonFavRecents.isEmpty {
            Section("Recientes") {
                ForEach(nonFavRecents) { pref in
                    if let ctx = contextStore.availableContexts.first(where: { $0.id == pref.contextActorId }) {
                        contextRow(ctx)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var allContextsSection: some View {
        let favoriteIds = Set(preferencesStore.favorites.map(\.contextActorId))
        let recentIds = Set(preferencesStore.recents.map(\.contextActorId))
        let rest = contextStore.availableContexts.filter {
            !favoriteIds.contains($0.id) && !recentIds.contains($0.id)
        }
        if !rest.isEmpty {
            Section("Todos") {
                ForEach(rest) { ctx in
                    contextRow(ctx)
                }
            }
        }
    }

    @ViewBuilder
    private var createSection: some View {
        Section {
            Button {
                isShowingCreateContext = true
            } label: {
                Label("Crear espacio nuevo", systemImage: "plus.circle.fill")
            }
        }
    }

    // MARK: - Search (7.D.1)

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var filteredContexts: [AppContext] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return contextStore.availableContexts }
        return contextStore.availableContexts.filter {
            $0.displayName.lowercased().contains(query)
        }
    }

    @ViewBuilder
    private var searchResultsSection: some View {
        let results = filteredContexts
        if results.isEmpty {
            Section {
                ContentUnavailableView.search(text: searchText)
            }
        } else {
            Section("Resultados (\(results.count))") {
                ForEach(results) { ctx in
                    contextRow(ctx)
                }
            }
        }
    }

    // MARK: - Row

    @ViewBuilder
    private func contextRow(_ context: AppContext) -> some View {
        Button {
            handleSwitch(to: context)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: context.symbolName)
                    .font(.title3)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tint)
                    .frame(width: 32, height: 32)
                    .background(Color.accentColor.badgeFillSubtle, in: Circle())
                    .contentTransition(.symbolEffect(.replace))
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.displayName).font(.callout.weight(.medium))
                    if !context.isPersonal {
                        // 7.D.1 — singular correcto cuando memberCount == 1.
                        Text(context.memberCount == 1 ? "1 miembro" : "\(context.memberCount) miembros")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Tu espacio personal")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if context.id == currentContextId {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func handleSwitch(to context: AppContext) {
        // Si tap al mismo contexto, solo cerramos.
        if context.id == currentContextId {
            dismiss()
            return
        }
        switchTrigger += 1
        onSwitch(context)
        dismiss()
    }
}

#Preview("Switcher (demo)") {
    Color.clear.sheet(isPresented: .constant(true)) {
        ContextSwitcherSheet(
            container: .demo(),
            currentContextId: MockRuulRPCClient.DemoIds.familia,
            onSwitch: { _ in }
        )
    }
}
