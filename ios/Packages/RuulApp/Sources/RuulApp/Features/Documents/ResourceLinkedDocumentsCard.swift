import SwiftUI
import RuulCore

/// Documents V2 · D.5 — card de documentos asociados a un recurso.
///
/// Cierra el dead struct `descriptor.linkedDocuments` (R.5V.0 audit confirmó:
/// decoded but never rendered). Se inserta en `ResourceDetailViewV2` entre
/// `relationsCard` y `linkedEventsCard`.
///
/// Estrategia: hace su propio fetch via `loadResourceDocuments(resourceId:)`
/// para tener Documents completos (con `storage_path` para tap → DocumentDetailView).
/// Si está vacío post-load → no se renderiza (silent skip).
public struct ResourceLinkedDocumentsCard: View {
    let resourceId: UUID
    let context: AppContext
    let container: DependencyContainer

    @State private var store: DocumentsStore
    @State private var pushedDocumentId: UUID?
    @State private var isShowingAll: Bool = false

    public init(resourceId: UUID, context: AppContext, container: DependencyContainer) {
        self.resourceId = resourceId
        self.context = context
        self.container = container
        _store = State(initialValue: DocumentsStore(rpc: container.rpc))
    }

    public var body: some View {
        Group {
            if !store.documents.isEmpty {
                cardBody
            }
        }
        .task { await store.loadResourceDocuments(resourceId: resourceId) }
        .navigationDestination(item: $pushedDocumentId) { id in
            if let doc = store.documents.first(where: { $0.id == id }) {
                DocumentDetailView(document: doc, context: context, container: container, store: store)
            } else {
                RuulErrorState(message: "Documento no encontrado.")
            }
        }
        .sheet(isPresented: $isShowingAll) {
            NavigationStack {
                ContextDocumentsListView(context: context, container: container)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cerrar") { isShowingAll = false }
                        }
                    }
            }
        }
    }

    @ViewBuilder
    private var cardBody: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            header
            VStack(spacing: 0) {
                ForEach(Array(store.documents.prefix(3))) { doc in
                    documentRow(doc)
                    if doc.id != store.documents.prefix(3).last?.id {
                        Divider().padding(.leading, Theme.Spacing.lg)
                    }
                }
            }
            .background(Theme.Background.secondary, in: Theme.cardShape())

            if store.documents.count > 3 {
                Button {
                    isShowingAll = true
                } label: {
                    HStack(spacing: Theme.Spacing.xs) {
                        Text("Ver todos (\(store.documents.count))")
                            .font(.subheadline.weight(.medium))
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                    }
                    .foregroundStyle(Theme.Tint.primary)
                }
                .buttonStyle(.plain)
                .padding(.top, Theme.Spacing.xs)
            }
        }
    }

    private var header: some View {
        HStack {
            Label("Documentos", systemImage: "doc.text")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.Text.secondary)
            Spacer()
            Text("\(store.documents.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(Theme.Text.tertiary)
        }
        .padding(.leading, Theme.Spacing.xs)
    }

    @ViewBuilder
    private func documentRow(_ doc: Document) -> some View {
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
                    Text(doc.documentType.label)
                        .font(.caption)
                        .foregroundStyle(Theme.Text.secondary)
                }
                Spacer()
                if doc.isArchived {
                    RuulStatusBadge(.archived)
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.Text.tertiary)
            }
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.vertical, Theme.Spacing.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func documentTint(_ type: DocumentType) -> Color {
        switch type {
        case .contract:  return Theme.Tint.info
        case .receipt:   return Theme.Tint.success
        case .id:        return .purple
        case .statement: return Theme.Tint.primary
        case .photo:     return Theme.Tint.warning
        case .other:     return Theme.Text.tertiary
        }
    }
}
