import SwiftUI
import UniformTypeIdentifiers
import RuulCore

/// Sheet para adjuntar un documento a un recurso. Flujo:
/// 1. Pickea un archivo (PDF/imagen) con `.fileImporter`.
/// 2. Captura título + tipo de documento.
/// 3. Sube binario al bucket `documents` de Storage + `register_document`.
public struct AttachDocumentView: View {
    let resource: Resource
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

    public init(
        resource: Resource,
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
                        ForEach(DocumentType.allCases) { type in
                            Label(type.label, systemImage: type.symbolName).tag(type)
                        }
                    }
                }

                Section {
                    Button {
                        Task { await attach() }
                    } label: {
                        if runner.isRunning {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Label("Adjuntar al recurso", systemImage: "tray.and.arrow.down")
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
        }
        .ruulSheet()
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
            _ = try await store.attachToResource(
                resource: resource,
                contextActorId: context.id,
                fileData: data,
                fileName: pickedFileName,
                title: title.trimmingCharacters(in: .whitespaces),
                documentType: documentType,
                mimeType: pickedMimeType.isEmpty ? "application/octet-stream" : pickedMimeType
            )
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
