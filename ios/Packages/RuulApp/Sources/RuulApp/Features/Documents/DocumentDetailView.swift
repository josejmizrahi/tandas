import SwiftUI
import QuickLook
import RuulCore

/// Documents V2 · D.4 — Detail View de un documento.
///
/// **Apple-native pattern (founder firma 2026-06-07):**
/// Usa `List` con `.listStyle(.insetGrouped)` + `Section`s para TODO el detail.
/// NO custom cards. Apple maneja background, padding, dividers, highlights.
///
/// Patrón canónico Ruul Detail View:
/// ```
/// List {
///   Section { heroRow }                            // Hero como row alto
///   Section("Información") { metadataRows }
///   Section("Asociado a") { linked rows }
///   Section("Acciones") {                          // Acciones primarias
///     Button { } label: { Label }                  // Native iOS row
///     Button(role: .destructive) { } label: { }    // Dangerous con role
///   }
///   Section { commingSoonRows }.disabled(true)    // System dimming automático
/// }
/// .listStyle(.insetGrouped)
/// ```
///
/// UX Doctrine §4: documento inmutable. Acciones lectura + share + archive (FQ-1).
/// Sign/Approve/Versions están coming soon (FQ-2/FQ-4 deferred).
///
/// QuickLook preview vía `.quickLookPreview($previewURL)` nativo (iOS 15+).
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
        List {
            heroSection
            metadataSection
            linkedSection
            actionsSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Documento")
        .navigationBarTitleDisplayMode(.inline)
        // P0 fix 2026-06-08 — toolbar Menu agrupado por section (Ver / Editar).
        // Acciones del body section "Acciones" replicadas para acceso rápido.
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Section("Ver") {
                        Button {
                            Task { await openPreview() }
                        } label: {
                            Label("Ver completo", systemImage: "eye.fill")
                        }
                        .disabled(document.storagePath == nil)
                        Button {
                            Task { await prepareShare() }
                        } label: {
                            Label("Compartir", systemImage: "square.and.arrow.up")
                        }
                        .disabled(document.storagePath == nil)
                        // Slice 7.A.6 (audit 2026-06-14) — antes "Ver completo"
                        // y "Compartir" quedaban disabled silenciosamente
                        // cuando faltaba el archivo binario. Ahora un footer
                        // explícito en el Menu deja claro por qué.
                        if document.storagePath == nil {
                            Text("Solo metadatos guardados. No hay archivo adjunto que abrir o compartir.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if !document.isArchived {
                        Section("Estado") {
                            Button(role: .destructive) {
                                isConfirmingArchive = true
                            } label: {
                                Label("Archivar", systemImage: "archivebox.fill")
                            }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Acciones del documento")
            }
        }
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
        .alert("No se pudo abrir",
               isPresented: Binding(
                   get: { loadError != nil },
                   set: { if !$0 { loadError = nil } }
               ),
               actions: { Button("OK", role: .cancel) {} },
               message: { Text(loadError ?? "") })
        .onChange(of: didArchive) { _, archived in
            if archived { dismiss() }
        }
        .sheet(item: $shareURL) { url in
            ShareSheet(url: url)
        }
    }

    // MARK: - Hero section (apple-native row)

    @ViewBuilder
    private var heroSection: some View {
        Section {
            HStack(alignment: .top, spacing: Theme.Spacing.md) {
                Image(systemName: document.documentType.symbolName)
                    .font(.system(size: 32))
                    .foregroundStyle(documentTint)
                    .frame(width: 56, height: 56)
                    .background(documentTint.badgeFill, in: Circle())

                VStack(alignment: .leading, spacing: 4) {
                    Text(document.title)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Theme.Text.primary)
                        .lineLimit(2)
                    Text(heroSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(Theme.Text.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                if document.isArchived {
                    RuulStatusBadge(.archived)
                }
            }
            .padding(.vertical, 6)
        }
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

    // MARK: - Metadata section (LabeledContent nativo)

    @ViewBuilder
    private var metadataSection: some View {
        Section("Información") {
            LabeledContent("Tipo", value: document.documentType.label)
            if let mime = document.mimeType {
                LabeledContent("Formato", value: mime)
            }
            if let size = document.fileSizeLabel {
                LabeledContent("Tamaño", value: size)
            }
            if let created = document.createdAt {
                LabeledContent("Creado", value: absoluteDate(created))
            }
            if let archived = document.archivedAt {
                LabeledContent("Archivado", value: absoluteDate(archived))
            }
        }
    }

    // MARK: - Linked entities (NavigationLink nativo)

    @ViewBuilder
    private var linkedSection: some View {
        if document.resourceId != nil {
            Section("Asociado a") {
                if let resourceId = document.resourceId {
                    NavigationLink(value: resourceId) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(document.resourceDisplayName ?? "Recurso")
                                Text("Recurso")
                                    .font(.caption)
                                    .foregroundStyle(Theme.Text.secondary)
                            }
                        } icon: {
                            Image(systemName: "shippingbox.fill")
                                .foregroundStyle(Theme.Tint.primary)
                        }
                    }
                }
            }
            .navigationDestination(for: UUID.self) { resourceId in
                ResourceDetailViewV2(resourceId: resourceId, context: context, container: container)
            }
        }
    }

    // MARK: - Actions section (Button rows nativos)
    //
    // Apple HIG: usar Button con Label dentro de List/Section.
    // Dangerous: `role: .destructive` o `.foregroundStyle(.red)` solo en label.
    // Disabled: `.disabled(true)` — sistema dim automático.

    @ViewBuilder
    private var actionsSection: some View {
        Section("Acciones") {
            Button {
                Task { await openPreview() }
            } label: {
                Label("Ver completo", systemImage: "eye.fill")
            }
            .disabled(document.storagePath == nil)

            Button {
                Task { await prepareShare() }
            } label: {
                Label("Compartir", systemImage: "square.and.arrow.up")
            }
            .disabled(document.storagePath == nil)

            if !document.isArchived {
                Button(role: .destructive) {
                    isConfirmingArchive = true
                } label: {
                    Label("Archivar", systemImage: "archivebox")
                }
            }
        }
    }

    // R.13.A (founder lock 2026-06-16) — eliminada `comingSoonSection`
    // (Firmar / Pedir aprobación / Subir nueva versión). Doctrina "nada que no
    // tenga que estar". FQ-2 firma electrónica deferred a Decisions templates
    // `document_approval`/`document_signing`; FQ-4 versions = nuevo doc +
    // supersedes (ya shipped). Cuando se implementen, vuelven al body.

    // MARK: - Tint por tipo

    private var documentTint: Color {
        switch document.documentType {
        case .contract:    return Theme.Tint.info
        case .receipt:     return Theme.Tint.success
        case .id:          return .purple
        case .statement:   return Theme.Tint.primary
        case .photo:       return Theme.Tint.warning
        case .other:       return Theme.Text.tertiary
        // R.12.G — nuevos subtypes alineados con catalog.
        case .policy:      return Theme.Tint.warning
        case .certificate: return Theme.Tint.success
        }
    }

    // MARK: - Preview / Share

    /// Descarga el blob a tmp dir y dispara QuickLook nativo.
    /// Re-genera signed URL on-demand (TTL 3600s puede expirar si el usuario
    /// abre el detail tarde — no cachear URL).
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
        guard document.storagePath != nil else {
            throw RuulError.unexpected(message: "Documento sin archivo adjunto.")
        }
        guard let signed = try await store.signedURL(for: document) else {
            throw RuulError.unexpected(message: "No se pudo obtener URL del archivo.")
        }
        let (data, _) = try await URLSession.shared.data(from: signed)
        let ext = (document.mimeType.flatMap(mimeExtension) ?? "")
        let safeTitle = document.title.replacingOccurrences(of: "/", with: "_")
        let suffix = ext.isEmpty ? "" : ".\(ext)"
        let local = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(document.id.uuidString)-\(safeTitle)\(suffix)")
        try? FileManager.default.removeItem(at: local)
        try data.write(to: local)
        return local
    }

    private func mimeExtension(_ mime: String) -> String? {
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
