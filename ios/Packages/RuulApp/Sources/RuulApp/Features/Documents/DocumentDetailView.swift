import SwiftUI
import QuickLook
import RuulCore

/// Documents V2 · D.4 — Detail View de un documento.
///
/// UX Doctrine §0.2 Patrón Detail: Hero → (Attention n/a) → Widgets (size,type) →
/// Sections (metadata, linked entities, versions) → Actions → Activity (preview).
///
/// UX Doctrine §4: documento inmutable. Acciones lectura + share + archive (FQ-1).
/// Sign/Approve/Versions están como `.comingSoon` (FQ-2/FQ-4 deferred).
///
/// QuickLook preview vía `.quickLookPreview($previewURL)` nativo (iOS 15+).
/// El signed URL se descarga a tmp dir on-demand para soportar TTL expiration.
public struct DocumentDetailView: View {
    let document: Document
    let context: AppContext
    let container: DependencyContainer
    let store: DocumentsStore

    @Environment(\.dismiss) private var dismiss
    @State private var previewURL: URL?
    @State private var shareURL: URL?
    @State private var isLoadingPreview = false
    @State private var loadError: String?
    @State private var isConfirmingArchive = false
    @State private var archiveError: String?
    @State private var didArchive = false

    public init(document: Document, context: AppContext, container: DependencyContainer, store: DocumentsStore) {
        self.document = document
        self.context = context
        self.container = container
        self.store = store
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.xl) {
                hero
                metadataSection
                linkedSection
                actionsSection
            }
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.top, Theme.Spacing.sm)
            .padding(.bottom, Theme.Spacing.xxl)
        }
        .background(Theme.Background.grouped)
        .navigationTitle("Documento")
        .navigationBarTitleDisplayMode(.inline)
        .quickLookPreview($previewURL)
        .alert("Archivar documento",
               isPresented: $isConfirmingArchive,
               actions: {
                   Button("Cancelar", role: .cancel) {}
                   Button("Archivar", role: .destructive) {
                       Task { await archive() }
                   }
               },
               message: {
                   Text("El documento se marcará como archivado. El archivo permanece en Storage para auditoría.")
               })
        .alert("No se pudo archivar",
               isPresented: Binding(
                   get: { archiveError != nil },
                   set: { if !$0 { archiveError = nil } }
               ),
               actions: { Button("OK", role: .cancel) {} },
               message: { Text(archiveError ?? "") })
        .onChange(of: didArchive) { _, archived in
            if archived { dismiss() }
        }
    }

    // MARK: - Hero (§0.2)

    @ViewBuilder
    private var hero: some View {
        RuulDetailHero(
            title: document.title,
            subtitle: heroSubtitle,
            systemImage: document.documentType.symbolName,
            tint: documentTint,
            status: document.isArchived ? .archived : .active
        )
    }

    private var heroSubtitle: String {
        var parts: [String] = [document.documentType.label]
        if let owner = document.ownerDisplayName {
            parts.append("Subido por \(owner)")
        }
        if let created = document.createdAt {
            parts.append(relativeDate(created))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Metadata section

    @ViewBuilder
    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            sectionHeader("Información")
            VStack(spacing: 0) {
                metadataRow(label: "Tipo", value: document.documentType.label)
                Divider().padding(.leading, Theme.Spacing.lg)
                if let mime = document.mimeType {
                    metadataRow(label: "Formato", value: mime)
                    Divider().padding(.leading, Theme.Spacing.lg)
                }
                if let size = document.fileSizeLabel {
                    metadataRow(label: "Tamaño", value: size)
                    Divider().padding(.leading, Theme.Spacing.lg)
                }
                if let created = document.createdAt {
                    metadataRow(label: "Creado", value: absoluteDate(created))
                }
                if let archived = document.archivedAt {
                    Divider().padding(.leading, Theme.Spacing.lg)
                    metadataRow(label: "Archivado", value: absoluteDate(archived))
                }
            }
            .background(Theme.Background.secondary, in: Theme.cardShape())
        }
    }

    @ViewBuilder
    private func metadataRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(Theme.Text.secondary)
            Spacer()
            Text(value)
                .font(.subheadline)
                .foregroundStyle(Theme.Text.primary)
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
    }

    // MARK: - Linked entities

    @ViewBuilder
    private var linkedSection: some View {
        if document.resourceId != nil || document.eventId != nil {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                sectionHeader("Asociado a")
                VStack(spacing: 0) {
                    if let resourceId = document.resourceId {
                        NavigationLink(value: resourceId) {
                            HStack(spacing: Theme.Spacing.md) {
                                Image(systemName: "shippingbox.fill")
                                    .foregroundStyle(Theme.Tint.primary)
                                    .frame(width: Theme.IconSize.sm)
                                VStack(alignment: .leading) {
                                    Text(document.resourceDisplayName ?? "Recurso")
                                        .font(.body)
                                        .foregroundStyle(Theme.Text.primary)
                                    Text("Recurso")
                                        .font(.caption)
                                        .foregroundStyle(Theme.Text.secondary)
                                }
                                Spacer()
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
                    if document.eventId != nil {
                        if document.resourceId != nil {
                            Divider().padding(.leading, Theme.Spacing.lg)
                        }
                        metadataRow(label: "Evento", value: "Vincular pronto…")
                    }
                }
                .background(Theme.Background.secondary, in: Theme.cardShape())
            }
            .navigationDestination(for: UUID.self) { resourceId in
                ResourceDetailViewV2(resourceId: resourceId, context: context, container: container)
            }
        }
    }

    // MARK: - Actions

    @ViewBuilder
    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            sectionHeader("Acciones")
            VStack(spacing: 0) {
                RuulActionRow(
                    "Ver completo",
                    systemImage: "eye.fill",
                    state: document.storagePath == nil ? .disabled(reason: "Sin archivo adjunto") : .enabled
                ) {
                    Task { await openPreview() }
                }
                Divider().padding(.leading, Theme.Spacing.lg)
                RuulActionRow(
                    "Compartir",
                    systemImage: "square.and.arrow.up",
                    state: document.storagePath == nil ? .disabled(reason: "Sin archivo adjunto") : .enabled
                ) {
                    Task { await prepareShare() }
                }
                Divider().padding(.leading, Theme.Spacing.lg)
                RuulActionRow(
                    document.isArchived ? "Ya archivado" : "Archivar",
                    systemImage: "archivebox",
                    state: document.isArchived ? .comingSoon : .dangerous
                ) {
                    isConfirmingArchive = true
                }
                Divider().padding(.leading, Theme.Spacing.lg)
                RuulActionRow(
                    "Firmar documento",
                    systemImage: "signature",
                    state: .comingSoon
                ) {}
                Divider().padding(.leading, Theme.Spacing.lg)
                RuulActionRow(
                    "Pedir aprobación",
                    systemImage: "checkmark.seal",
                    state: .comingSoon
                ) {}
                Divider().padding(.leading, Theme.Spacing.lg)
                RuulActionRow(
                    "Subir nueva versión",
                    systemImage: "arrow.up.doc",
                    state: .comingSoon
                ) {}
            }
            .background(Theme.Background.secondary, in: Theme.cardShape())

            if isLoadingPreview {
                ProgressView("Preparando vista previa…")
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, Theme.Spacing.sm)
            }
            if let loadError {
                Text(loadError)
                    .font(.caption)
                    .foregroundStyle(Theme.Tint.critical)
                    .padding(.top, Theme.Spacing.xs)
            }
        }
        .sheet(item: $shareURL) { url in
            ShareSheet(url: url)
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.Text.secondary)
            .padding(.leading, Theme.Spacing.xs)
    }

    // MARK: - Tint por tipo

    private var documentTint: Color {
        switch document.documentType {
        case .contract:  return Theme.Tint.info
        case .receipt:   return Theme.Tint.success
        case .id:        return .purple
        case .statement: return Theme.Tint.primary
        case .photo:     return Theme.Tint.warning
        case .other:     return Theme.Text.tertiary
        }
    }

    // MARK: - Preview / Share

    /// Descarga el blob a tmp dir y dispara QuickLook nativo.
    /// Re-genera signed URL on-demand (founder rationale: TTL 3600s puede expirar
    /// si el usuario abre el detail tarde — no cachear URL).
    private func openPreview() async {
        loadError = nil
        isLoadingPreview = true
        defer { isLoadingPreview = false }
        do {
            let localURL = try await downloadTemp()
            previewURL = localURL
        } catch {
            loadError = UserFacingError.from(error).message
        }
    }

    private func prepareShare() async {
        loadError = nil
        isLoadingPreview = true
        defer { isLoadingPreview = false }
        do {
            let localURL = try await downloadTemp()
            shareURL = localURL
        } catch {
            loadError = UserFacingError.from(error).message
        }
    }

    private func downloadTemp() async throws -> URL {
        guard let path = document.storagePath else {
            throw RuulError.unexpected(message: "Documento sin archivo adjunto.")
        }
        guard let signed = try await store.signedURL(for: document) else {
            throw RuulError.unexpected(message: "No se pudo obtener URL del archivo.")
        }
        _ = path  // path reservado para metadata futura
        let (data, _) = try await URLSession.shared.data(from: signed)
        // Filename sanitario para QuickLook
        let ext = (document.mimeType.flatMap(mimeExtension) ?? "")
        let safeTitle = document.title.replacingOccurrences(of: "/", with: "_")
        let suffix = ext.isEmpty ? "" : ".\(ext)"
        let local = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(document.id.uuidString)-\(safeTitle)\(suffix)")
        try? FileManager.default.removeItem(at: local) // overwrite if existed
        try data.write(to: local)
        return local
    }

    private func mimeExtension(_ mime: String) -> String? {
        // Mapping mínimo de MIMEs comunes en Ruul (PDF/img/text/CSV).
        switch mime.lowercased() {
        case "application/pdf":  return "pdf"
        case "image/jpeg",
             "image/jpg":        return "jpg"
        case "image/png":        return "png"
        case "image/heic":       return "heic"
        case "text/plain":       return "txt"
        case "text/csv":         return "csv"
        default:                 return nil
        }
    }

    // MARK: - Archive

    private func archive() async {
        do {
            try await store.archive(documentId: document.id, contextId: context.id)
            didArchive = true
        } catch {
            archiveError = UserFacingError.from(error).message
        }
    }

    // MARK: - Date formatting

    private func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.locale = Locale(identifier: "es")
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func absoluteDate(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}

// MARK: - ShareSheet

private struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

// MARK: - URL Identifiable conformance (para .sheet(item:))

extension URL: Identifiable {
    public var id: String { absoluteString }
}
