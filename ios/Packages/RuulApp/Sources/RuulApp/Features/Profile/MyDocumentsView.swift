import SwiftUI
import RuulCore

/// R.8.MiMundo.S5 — Vista cross-context de documentos visibles. Mismo patrón
/// que MyObligations/MyDecisions: fan-out paralelo + Picker (Mías / Todas) +
/// secciones por DocumentType + searchable por título.
///
/// `list_context_documents` ya filtra por permisos vía RLS — la vista solo
/// agrega y agrupa. "Mías" = `owner_actor_id == myActorId`. Compartidos
/// conmigo = el complemento (documentos donde soy miembro del contexto pero
/// no soy owner).
public struct MyDocumentsView: View {
    let container: DependencyContainer

    @State private var phase: StorePhase = .idle
    @State private var aggregated: [Entry] = []
    @State private var filter: OwnershipFilter = .mine
    @State private var query: String = ""
    @State private var documentsStore: DocumentsStore
    @State private var selected: SelectedDocument?

    public init(container: DependencyContainer) {
        self.container = container
        _documentsStore = State(initialValue: DocumentsStore(rpc: container.rpc))
    }

    public var body: some View {
        Group {
            switch phase {
            case .idle, .loading:
                RuulLoadingState(title: "Cargando documentos…")
            case .failed(let message):
                RuulErrorState(message: message) {
                    Task { await load() }
                }
            case .loaded:
                content
            }
        }
        .navigationTitle("Mis documentos")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .sheet(item: $selected) { sel in
            NavigationStack {
                DocumentDetailView(
                    document: sel.document,
                    context: sel.context,
                    container: container,
                    store: documentsStore
                )
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        let myActorId = container.currentActorStore.actorId
        let filtered = aggregated
            .filter { matchesFilter($0, myActorId: myActorId) }
            .filter { matchesQuery($0) }
        let grouped = Dictionary(grouping: filtered) { $0.document.documentType }

        List {
            filterSection
            if filtered.isEmpty {
                emptySection
            } else {
                ForEach(DocumentType.allCases) { type in
                    if let entries = grouped[type], !entries.isEmpty {
                        section(type: type, entries: entries.sorted(by: createdAtDesc))
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $query, prompt: "Buscar documento")
        .searchToolbarBehavior(.minimize)
    }

    @ViewBuilder
    private var filterSection: some View {
        Section {
            Picker("Filtro", selection: $filter) {
                ForEach(OwnershipFilter.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: Theme.Spacing.sm, leading: Theme.Spacing.md,
                                       bottom: Theme.Spacing.sm, trailing: Theme.Spacing.md))
        }
    }

    @ViewBuilder
    private var emptySection: some View {
        Section {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: filter == .mine ? "doc.fill" : "tray")
                    .foregroundStyle(Theme.Text.tertiary)
                Text(filter == .mine ? "No has subido documentos aún" : "Sin documentos compartidos visibles")
                    .font(.callout)
                    .foregroundStyle(Theme.Text.secondary)
            }
            .padding(.vertical, Theme.Spacing.xs)
        }
    }

    @ViewBuilder
    private func section(type: DocumentType, entries: [Entry]) -> some View {
        Section {
            ForEach(entries) { entry in
                Button {
                    selected = SelectedDocument(document: entry.document, context: entry.context)
                } label: {
                    row(entry, type: type)
                }
                .buttonStyle(.plain)
            }
        } header: {
            Label(type.label, systemImage: type.symbolName)
                .foregroundStyle(Theme.Text.secondary)
        }
    }

    @ViewBuilder
    private func row(_ entry: Entry, type: DocumentType) -> some View {
        HStack(spacing: 12) {
            Image(systemName: type.symbolName)
                .foregroundStyle(typeTint(type))
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.document.title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Theme.Text.primary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(entry.context.displayName).lineLimit(1)
                    if let resourceName = entry.document.resourceDisplayName, !resourceName.isEmpty {
                        Text("·")
                        Text(resourceName).lineLimit(1)
                    }
                    if let created = entry.document.createdAt {
                        Text("·")
                        Text(created.formatted(.relative(presentation: .named)))
                    }
                }
                .font(.caption)
                .foregroundStyle(Theme.Text.secondary)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.Text.tertiary)
        }
    }

    private func typeTint(_ type: DocumentType) -> Color {
        switch type {
        case .contract:    return Theme.Tint.primary
        case .receipt:     return Theme.Tint.success
        case .id:          return Theme.Tint.info
        case .statement:   return Theme.Tint.warning
        case .photo:       return .pink
        case .other:       return Theme.Text.secondary
        // R.12.G — nuevos subtypes alineados con catalog.
        case .policy:      return Theme.Tint.warning
        case .certificate: return Theme.Tint.success
        }
    }

    private func createdAtDesc(_ a: Entry, _ b: Entry) -> Bool {
        (a.document.createdAt ?? .distantPast) > (b.document.createdAt ?? .distantPast)
    }

    // MARK: - Filter logic

    private func matchesFilter(_ entry: Entry, myActorId: UUID?) -> Bool {
        guard let myActorId else { return false }
        switch filter {
        case .mine:   return entry.document.ownerActorId == myActorId
        case .shared: return entry.document.ownerActorId != myActorId
        }
    }

    private func matchesQuery(_ entry: Entry) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return true }
        if entry.document.title.lowercased().contains(q) { return true }
        if let name = entry.document.resourceDisplayName?.lowercased(), name.contains(q) { return true }
        if entry.context.displayName.lowercased().contains(q) { return true }
        return false
    }

    // MARK: - Data

    private func load() async {
        if aggregated.isEmpty { phase = .loading }
        let contexts = container.contextStore.availableContexts
        guard !contexts.isEmpty else {
            aggregated = []
            phase = .loaded
            return
        }
        await withTaskGroup(of: ContextSlice.self) { group in
            for ctx in contexts {
                group.addTask {
                    let docs: [Document] = (try? await container.rpc.listContextDocuments(
                        contextId: ctx.id,
                        includeArchived: false
                    )) ?? []
                    return ContextSlice(context: ctx, documents: docs)
                }
            }
            var all: [Entry] = []
            for await slice in group {
                for doc in slice.documents {
                    all.append(Entry(document: doc, context: slice.context))
                }
            }
            aggregated = all
        }
        phase = .loaded
    }

    // MARK: - Types

    private struct Entry: Identifiable, Sendable {
        let document: Document
        let context: AppContext
        var id: UUID { document.id }
    }

    private struct SelectedDocument: Identifiable {
        let document: Document
        let context: AppContext
        var id: UUID { document.id }
    }

    private struct ContextSlice: Sendable {
        let context: AppContext
        let documents: [Document]
    }

    private enum OwnershipFilter: String, CaseIterable, Identifiable {
        case mine, shared
        var id: String { rawValue }
        var label: String {
            switch self {
            case .mine:   return "Mías"
            case .shared: return "Compartidas conmigo"
            }
        }
    }
}

#Preview("Mis documentos (demo)") {
    NavigationStack {
        MyDocumentsView(container: .demo())
    }
}
