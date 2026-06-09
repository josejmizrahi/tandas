import SwiftUI
import RuulCore

/// Documents V2 · D.3 — lista cross-resource de documentos del contexto.
///
/// **R.5V.X (2026-06-09)** — Rebuild Apple-native + Liquid Glass (mismo patrón
/// que MyResources/Events/Members/Rules/Decisions/Resources v3):
/// 1. Hero Liquid Glass: count + breakdown chips por tipo (Contratos /
///    Recibos / IDs / etc.)
/// 2. `.searchable` por título / resource displayName
/// 3. Sections por DocumentType (Contratos / Recibos / Identificaciones /
///    Estados de cuenta / Fotos / Otros) con tints semánticos
/// 4. Section "Archivados" al final (cuando `includeArchived` toggle ON)
/// 5. Estados Ruul* (Loading/Error/Empty)
public struct ContextDocumentsListView: View {
    let context: AppContext
    let container: DependencyContainer

    @State private var store: DocumentsStore
    @State private var includeArchived: Bool = false
    @State private var isShowingAttach: Bool = false
    @State private var pickedResource: Resource?
    @State private var pushedDocumentId: UUID?
    @State private var query: String = ""

    public init(context: AppContext, container: DependencyContainer) {
        self.context = context
        self.container = container
        _store = State(initialValue: DocumentsStore(rpc: container.rpc))
    }

    public var body: some View {
        Group {
            switch store.contextPhase {
            case .idle, .loading:
                RuulLoadingState(title: "Cargando documentos…")
            case .failed(let message):
                RuulErrorState(message: message) {
                    Task { await load() }
                }
            case .loaded:
                contentView
            }
        }
        .navigationTitle("Documentos")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Toggle("Ver archivados", isOn: $includeArchived)
                    Divider()
                    Button {
                        showAttachPicker()
                    } label: {
                        Label("Adjuntar documento", systemImage: "paperclip")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .onChange(of: includeArchived) { _, _ in
            Task { await load() }
        }
        .sheet(isPresented: $isShowingAttach) {
            if let resource = pickedResource {
                AttachDocumentView(
                    resource: resource,
                    context: context,
                    container: container,
                    store: store
                )
            } else {
                ResourcePickerForAttach(context: context, container: container) { resource in
                    pickedResource = resource
                }
            }
        }
        .navigationDestination(item: $pushedDocumentId) { id in
            if let doc = store.contextDocuments.first(where: { $0.id == id }) {
                DocumentDetailView(document: doc, context: context, container: container, store: store)
            } else {
                RuulErrorState(message: "Documento no encontrado.")
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var contentView: some View {
        if store.contextDocuments.isEmpty {
            RuulEmptyState(
                title: "Sin documentos",
                systemImage: "doc",
                message: includeArchived
                    ? "No hay documentos en este contexto."
                    : "No hay documentos activos. Toca el menú para adjuntar uno o ver archivados."
            )
        } else {
            let filtered = filter(store.contextDocuments)
            let active = filtered.filter { !$0.isArchived }
            let archived = filtered.filter(\.isArchived)
            let groupedActive = Dictionary(grouping: active, by: { $0.documentType })
                .mapValues { $0.sorted { $0.title < $1.title } }
            List {
                heroSection(store.contextDocuments)
                ForEach(DocumentType.displayOrder, id: \.self) { type in
                    if let items = groupedActive[type], !items.isEmpty {
                        Section {
                            ForEach(items) { doc in row(doc) }
                        } header: {
                            HStack {
                                Label(type.label, systemImage: type.symbolName)
                                    .foregroundStyle(Theme.Text.secondary)
                                Spacer()
                                Text("\(items.count)")
                                    .foregroundStyle(Theme.Text.tertiary)
                            }
                        }
                    }
                }
                if !archived.isEmpty {
                    Section {
                        ForEach(archived) { doc in row(doc) }
                    } header: {
                        HStack {
                            Label("Archivados", systemImage: "archivebox.fill")
                                .foregroundStyle(Theme.Text.tertiary)
                            Spacer()
                            Text("\(archived.count)")
                                .foregroundStyle(Theme.Text.tertiary)
                        }
                    }
                }
                if groupedActive.isEmpty && archived.isEmpty {
                    Section {
                        Text("Sin coincidencias con \"\(query)\"")
                            .font(.callout)
                            .foregroundStyle(Theme.Text.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, Theme.Spacing.md)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $query, prompt: "Buscar documento")
            .searchToolbarBehavior(.minimize)
        }
    }

    // MARK: - Hero (Liquid Glass)

    @ViewBuilder
    private func heroSection(_ docs: [Document]) -> some View {
        let active = docs.filter { !$0.isArchived }
        let byType = Dictionary(grouping: active, by: { $0.documentType })
        let breakdown = DocumentType.displayOrder.compactMap { t -> (DocumentType, Int)? in
            guard let count = byType[t]?.count, count > 0 else { return nil }
            return (t, count)
        }
        Section {
            GlassEffectContainer(spacing: Theme.Spacing.sm) {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
                        Text("\(active.count)")
                            .font(.system(size: 36, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.Tint.primary)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(active.count == 1 ? "documento" : "documentos")
                                .font(.callout)
                                .foregroundStyle(Theme.Text.secondary)
                            if docs.count > active.count {
                                Text("\(docs.count - active.count) archivado\(docs.count - active.count == 1 ? "" : "s")")
                                    .font(.caption2)
                                    .foregroundStyle(Theme.Text.tertiary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    if !breakdown.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: Theme.Spacing.xs) {
                                ForEach(breakdown, id: \.0) { type, count in
                                    typeChip(type, count: count)
                                }
                            }
                        }
                    }
                }
                .padding(Theme.Spacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 18))
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: Theme.Spacing.md, leading: Theme.Spacing.lg, bottom: Theme.Spacing.md, trailing: Theme.Spacing.lg))
        }
    }

    @ViewBuilder
    private func typeChip(_ type: DocumentType, count: Int) -> some View {
        HStack(spacing: Theme.Spacing.xs) {
            Image(systemName: type.symbolName)
                .font(.caption.weight(.semibold))
            Text("\(count)")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
        }
        .foregroundStyle(documentTint(type))
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, Theme.Spacing.xs)
        .background(documentTint(type).opacity(Theme.Surface.badgeFillSubtle), in: Capsule())
    }

    // MARK: - Filter

    private func filter(_ docs: [Document]) -> [Document] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return docs }
        return docs.filter { d in
            d.title.lowercased().contains(q)
                || (d.resourceDisplayName?.lowercased().contains(q) ?? false)
        }
    }

    @ViewBuilder
    private func row(_ doc: Document) -> some View {
        Button {
            pushedDocumentId = doc.id
        } label: {
            HStack(spacing: Theme.Spacing.md) {
                Image(systemName: doc.documentType.symbolName)
                    .font(.body)
                    .foregroundStyle(documentTint(doc.documentType))
                    .frame(width: Theme.IconSize.sm)
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text(doc.title)
                        .font(.body)
                        .foregroundStyle(Theme.Text.primary)
                        .lineLimit(1)
                    Text(subtitle(for: doc))
                        .font(.caption)
                        .foregroundStyle(Theme.Text.secondary)
                        .lineLimit(2)
                }
                Spacer()
                if doc.isArchived {
                    RuulStatusBadge(.archived)
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.Text.tertiary)
            }
            .padding(.vertical, Theme.Spacing.xxs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func subtitle(for doc: Document) -> String {
        var parts: [String] = [doc.documentType.label]
        if let resource = doc.resourceDisplayName { parts.append(resource) }
        if let size = doc.fileSizeLabel { parts.append(size) }
        return parts.joined(separator: " · ")
    }

    // MARK: - Tint por tipo (UX Doctrine §4)

    private func documentTint(_ type: DocumentType) -> Color {
        switch type {
        case .contract:  return Theme.Tint.info        // legal/azul
        case .receipt:   return Theme.Tint.success     // gasto justificado/verde
        case .id:        return .purple                // identidad
        case .statement: return Theme.Tint.primary     // estado de cuenta
        case .photo:     return Theme.Tint.warning     // evidencia visual
        case .other:     return Theme.Text.tertiary
        }
    }

    // MARK: - Actions

    private func load() async {
        await store.loadContextDocuments(contextId: context.id, includeArchived: includeArchived)
    }

    private func showAttachPicker() {
        pickedResource = nil
        isShowingAttach = true
    }
}

// MARK: - Resource picker for attach

/// Picker mínimo para elegir el recurso al que se adjunta el documento.
/// AttachDocumentView (R.2N) requiere un recurso obligatorio.
private struct ResourcePickerForAttach: View {
    let context: AppContext
    let container: DependencyContainer
    let onPick: (Resource) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var resources: [ContextResource] = []
    @State private var phase: StorePhase = .idle

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .idle, .loading:
                    RuulLoadingState()
                case .failed(let m):
                    RuulErrorState(message: m) { Task { await load() } }
                case .loaded:
                    if resources.isEmpty {
                        RuulEmptyState(
                            title: "Sin recursos",
                            systemImage: "shippingbox",
                            message: "Este contexto no tiene recursos aún. Crea uno primero."
                        )
                    } else {
                        List {
                            Section("Elige el recurso") {
                                ForEach(resources) { r in
                                    Button {
                                        onPick(Resource(
                                            id: r.resourceId,
                                            resourceType: r.resourceType,
                                            displayName: r.displayName,
                                            status: r.status,
                                            estimatedValue: r.estimatedValue,
                                            currency: r.currency,
                                            canonicalOwnerActorId: r.canonicalOwnerActorId
                                        ))
                                    } label: {
                                        HStack(spacing: Theme.Spacing.md) {
                                            Image(systemName: r.type.symbolName)
                                                .foregroundStyle(Theme.Tint.primary)
                                                .frame(width: Theme.IconSize.sm)
                                            VStack(alignment: .leading) {
                                                Text(r.displayName)
                                                Text(r.type.label)
                                                    .font(.caption)
                                                    .foregroundStyle(Theme.Text.secondary)
                                            }
                                            Spacer()
                                            Image(systemName: "chevron.right")
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(Theme.Text.tertiary)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Adjuntar documento")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
            }
            .task { await load() }
        }
    }

    private func load() async {
        phase = .loading
        do {
            resources = try await container.rpc.listContextResources(contextId: context.id)
            phase = .loaded
        } catch {
            phase = .failed(message: UserFacingError.from(error).message)
        }
    }
}

// MARK: - DocumentType display order (R.5V v3 grouping)

private extension DocumentType {
    /// Orden de Sections: tipos más comunes primero (contratos / recibos),
    /// "Otros" al final antes de "Archivados".
    static let displayOrder: [DocumentType] = [
        .contract, .id, .statement, .receipt, .photo, .other
    ]
}

