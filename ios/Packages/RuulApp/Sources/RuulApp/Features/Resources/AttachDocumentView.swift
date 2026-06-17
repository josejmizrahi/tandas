import SwiftUI
import UniformTypeIdentifiers
import RuulCore

/// Sheet para adjuntar un documento. Flujo:
/// 1. Pickea un archivo (PDF/imagen) con `.fileImporter`.
/// 2. Captura título + tipo de documento.
/// 3. Sube binario al bucket `documents` de Storage + `register_document`.
///
/// R.5Z.fix.10.b — `resource` opcional. Cuando es nil, el documento se
/// adjunta al contexto (sin atar a un resource específico). Caso uso:
/// estatutos, contratos macro, comprobantes admin.
public struct AttachDocumentView: View {
    let resource: Resource?
    let context: AppContext
    let container: DependencyContainer
    let store: DocumentsStore

    @Environment(\.dismiss) private var dismiss
    @State private var runner = ActionRunner()
    @State private var isShowingFileImporter = false

    @State private var pickedFileURL: URL?
    @State private var pickedFileName: String = ""
    @State private var pickedData: Data?
    @State private var pickedMimeType: String = ""

    @State private var title: String = ""
    @State private var documentType: DocumentType = .other
    @State private var pickerError: String?
    /// R.12.G — schema + values del document subtype matching documentType.
    /// Carga del catalog `resource_subtypes` class='document'. Reset al cambiar tipo.
    @State private var subtypeFields: [FormFieldSpec] = []
    @State private var subtypeDisplayName: String = ""
    @State private var subtypeMetadata: [String: JSONValue] = [:]
    /// D.CATALOG.A — document_type keys priorizados del subtype del resource
    /// destino. Se resuelven on appear; mientras tanto, picker muestra todos.
    @State private var recommendedTypeKeys: [String] = []

    public init(
        resource: Resource?,
        context: AppContext,
        container: DependencyContainer,
        store: DocumentsStore
    ) {
        self.resource = resource
        self.context = context
        self.container = container
        self.store = store
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("Archivo") {
                    if let pickedFileName = pickedData == nil ? nil : pickedFileName {
                        HStack(spacing: 12) {
                            Image(systemName: documentType.symbolName)
                                .foregroundStyle(.tint)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(pickedFileName)
                                    .font(.body)
                                    .lineLimit(1)
                                if let bytes = pickedData?.count {
                                    Text(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button("Cambiar") {
                                isShowingFileImporter = true
                            }
                            .buttonStyle(.borderless)
                        }
                    } else {
                        Button {
                            isShowingFileImporter = true
                        } label: {
                            Label("Seleccionar archivo", systemImage: "paperclip")
                        }
                    }
                    if let pickerError {
                        Text(pickerError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                Section("Detalles") {
                    TextField("Título", text: $title)
                    Picker("Tipo", selection: $documentType) {
                        // D.CATALOG.A — recommended types primero (si hay),
                        // después el resto. iOS prioriza coherencia con el
                        // resource_subtype (casa → escritura/contrato; auto
                        // → tarjeta circulación/póliza; etc).
                        if !recommendedTypes.isEmpty {
                            Section {
                                ForEach(recommendedTypes) { type in
                                    Label(type.label, systemImage: type.symbolName).tag(type)
                                }
                            } header: {
                                Text("Recomendados")
                            }
                            Section {
                                ForEach(otherTypes) { type in
                                    Label(type.label, systemImage: type.symbolName).tag(type)
                                }
                            } header: {
                                Text("Otros")
                            }
                        } else {
                            ForEach(DocumentType.allCases) { type in
                                Label(type.label, systemImage: type.symbolName).tag(type)
                            }
                        }
                    }
                    .pickerStyle(.navigationLink)
                }

                // R.12.G — campos específicos del subtype (driven by
                // resource_subtypes.metadata.fields class='document').
                // policy → policy_number/provider/dates/coverage; contract →
                // party_a/party_b/dates; etc.
                if !subtypeFields.isEmpty {
                    Section {
                        DynamicForm(
                            schema: FormSchema(fields: subtypeFields),
                            values: $subtypeMetadata
                        )
                    } header: {
                        Text("Detalles \(subtypeDisplayName.lowercased())")
                    }
                }

                Section {
                    Button {
                        Task { await attach() }
                    } label: {
                        if runner.isRunning {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Label(resource == nil ? "Adjuntar al espacio" : "Adjuntar al recurso",
                                  systemImage: "tray.and.arrow.down")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(!canSubmit || runner.isRunning)
                } footer: {
                    // 7.E.2 (audit 2026-06-14) — hint inline cuando falta algo +
                    // copy sin "fila" (jerga DB) cuando todo está OK.
                    if let hint = validationHint {
                        Label(hint, systemImage: "exclamationmark.circle")
                            .font(.caption)
                            .foregroundStyle(Theme.Tint.warning)
                    } else {
                        Text("El documento quedará guardado en \(context.displayName) — visible a los miembros con permiso para verlo.")
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
            .fileImporter(
                isPresented: $isShowingFileImporter,
                allowedContentTypes: [.pdf, .image, .text, .plainText, .commaSeparatedText],
                allowsMultipleSelection: false
            ) { result in
                handleFilePick(result)
            }
            .actionErrorAlert(runner)
            .task(id: documentType.rawValue) { await loadSubtypeFields() }
            .task { await loadRecommendedTypes() }
        }
        .ruulSheet()
    }

    // MARK: - D.CATALOG.A — Recommended types per resource_subtype

    /// Tipos priorizados del subtype del resource destino. Vacíos cuando
    /// adjuntamos al contexto (sin resource), cuando el subtype no tiene
    /// seeded, o cuando el lookup falla.
    private var recommendedTypes: [DocumentType] {
        guard !recommendedTypeKeys.isEmpty else { return [] }
        return recommendedTypeKeys.compactMap(DocumentType.init(rawValue:))
    }

    private var otherTypes: [DocumentType] {
        let recommended = Set(recommendedTypes)
        return DocumentType.allCases.filter { !recommended.contains($0) }
    }

    /// Resuelve `recommended_document_types` del resource subtype del catalog.
    /// 2 RPCs: resourceSubtypeKey → listResourceSubtypes → extract array.
    private func loadRecommendedTypes() async {
        guard let resource else { return }
        do {
            let key = try await container.rpc.resourceSubtypeKey(resourceId: resource.id)
            guard let key else { return }
            let all = try await container.rpc.listResourceSubtypes(classKey: nil)
            if let match = all.first(where: { $0.subtypeKey == key }) {
                recommendedTypeKeys = match.recommendedDocumentTypes
                // Default selection al primer recomendado si user no tocó.
                if let first = recommendedTypes.first, documentType == .other {
                    documentType = first
                }
            }
        } catch {
            recommendedTypeKeys = []
        }
    }

    /// R.12.G — carga el subtype del catalog matching documentType.rawValue
    /// (contract/policy/certificate/receipt/statement en resource_subtypes
    /// class='document'). photo/id/other no tienen schema dedicado → no
    /// aparece la section. Reset de values al cambiar tipo.
    private func loadSubtypeFields() async {
        subtypeMetadata = [:]
        do {
            let all = try await container.rpc.listResourceSubtypes(classKey: "document")
            if let match = all.first(where: { $0.subtypeKey == documentType.rawValue }) {
                subtypeFields = match.fields
                subtypeDisplayName = match.displayName
            } else {
                subtypeFields = []
                subtypeDisplayName = ""
            }
        } catch {
            subtypeFields = []
            subtypeDisplayName = ""
        }
    }

    private var canSubmit: Bool {
        validationHint == nil
    }

    /// 7.E.2 — describe POR QUÉ el botón está disabled. Antes el usuario
    /// veía "Adjuntar al recurso" disabled sin saber qué le faltaba.
    private var validationHint: String? {
        if pickedData == nil {
            return "Falta elegir el archivo a adjuntar."
        }
        if title.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Ponle un título al documento."
        }
        return nil
    }

    private func handleFilePick(_ result: Result<[URL], Error>) {
        pickerError = nil
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let security = url.startAccessingSecurityScopedResource()
            defer { if security { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                pickedFileURL = url
                pickedFileName = url.lastPathComponent
                pickedData = data
                pickedMimeType = url.guessedMimeType
                if title.isEmpty {
                    title = url.deletingPathExtension().lastPathComponent
                }
                documentType = inferType(from: pickedMimeType, fileName: pickedFileName)
            } catch {
                pickerError = "No pudimos leer el archivo."
            }
        case .failure:
            pickerError = "No pudimos abrir el archivo."
        }
    }

    private func inferType(from mime: String, fileName: String) -> DocumentType {
        if mime.hasPrefix("image/") { return .photo }
        if mime == "application/pdf" {
            let lower = fileName.lowercased()
            if lower.contains("contrato") || lower.contains("contract") { return .contract }
            if lower.contains("recibo") || lower.contains("receipt") { return .receipt }
            if lower.contains("estado") || lower.contains("statement") { return .statement }
        }
        return .other
    }

    private func attach() async {
        await runner.run {
            guard let data = pickedData else { return }
            let metadataPayload: JSONValue? = subtypeMetadata.isEmpty
                ? nil
                : .object(subtypeMetadata)
            let mime = pickedMimeType.isEmpty ? "application/octet-stream" : pickedMimeType
            let trimmed = title.trimmingCharacters(in: .whitespaces)
            if let resource {
                _ = try await store.attachToResource(
                    resource: resource,
                    contextActorId: context.id,
                    fileData: data,
                    fileName: pickedFileName,
                    title: trimmed,
                    documentType: documentType,
                    mimeType: mime,
                    metadata: metadataPayload
                )
            } else {
                // R.5Z.fix.10.b — sin resource → adjunta al contexto.
                _ = try await store.attachToContext(
                    contextActorId: context.id,
                    fileData: data,
                    fileName: pickedFileName,
                    title: trimmed,
                    documentType: documentType,
                    mimeType: mime,
                    metadata: metadataPayload
                )
            }
            dismiss()
        }
    }
}

private extension URL {
    var guessedMimeType: String {
        if let type = UTType(filenameExtension: self.pathExtension)?.preferredMIMEType {
            return type
        }
        return "application/octet-stream"
    }
}

#Preview("Adjuntar documento") {
    AttachDocumentView(
        resource: Resource(
            id: MockRuulRPCClient.DemoIds.casaValle,
            resourceType: "house",
            displayName: "Casa Valle",
            description: nil,
            estimatedValue: nil,
            currency: nil,
            canonicalOwnerActorId: MockRuulRPCClient.DemoIds.familia,
            createdAt: Date()
        ),
        context: AppContext(
            id: MockRuulRPCClient.DemoIds.familia,
            kind: .collective,
            subtype: "family",
            displayName: "Familia Mizrahi"
        ),
        container: .demo(),
        store: DocumentsStore(rpc: MockRuulRPCClient.demo())
    )
}
