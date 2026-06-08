import SwiftUI
import RuulCore

/// Documents V2 · D.3 — lista cross-resource de documentos del contexto.
///
/// Reemplaza el fallback `ActivityFeedView` que ContextDetailViewV2 More tab
/// `documents` row usaba antes (R.5X audit P1-01 founder priority #1).
///
/// Usa componentes Ruul* V.2:
/// - `RuulLoadingState` / `RuulErrorState` / `RuulEmptyState` para phases
/// - `RuulActionRow` para cada document row (state `.enabled` push detail)
///
/// UX Doctrine §4 (documento): 6 tipos canónicos · inmutables · `archived_at`
/// determina active vs archived. Soft toggle "Ver archivados" extiende la lista.
public struct ContextDocumentsListView: View {
    let context: AppContext
    let container: DependencyContainer

    @State private var store: DocumentsStore
    @State private var includeArchived: Bool = false
    @State private var isShowingAttach: Bool = false
    @State private var pickedResource: Resource?
    @State private var pushedDocumentId: UUID?

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
            List {
                let groups = grouped(store.contextDocuments)
                if !groups.active.isEmpty {
                    Section("Activos") {
                        ForEach(groups.active) { doc in row(doc) }
                    }
                }
                if !groups.archived.isEmpty {
                    Section("Archivados") {
                        ForEach(groups.archived) { doc in row(doc) }
                    }
                }
            }
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

    // MARK: - Grouping

    private struct Groups {
        var active: [Document]
        var archived: [Document]
    }

    private func grouped(_ docs: [Document]) -> Groups {
        var active: [Document] = []
        var archived: [Document] = []
        for doc in docs {
            if doc.isArchived { archived.append(doc) } else { active.append(doc) }
        }
        return Groups(active: active, archived: archived)
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
