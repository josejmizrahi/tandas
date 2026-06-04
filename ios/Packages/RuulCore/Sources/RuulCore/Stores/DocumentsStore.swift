import Foundation
import Observation

/// Documentos adjuntos a un recurso. Coordina upload a Supabase Storage +
/// `register_document` para registrar la metadata. La RLS server-side decide
/// quién puede ver/registrar; el frontend solo gatea botones por permisos.
@MainActor
@Observable
public final class DocumentsStore {
    public private(set) var documents: [Document] = []
    public private(set) var phase: StorePhase = .idle

    private let rpc: any RuulRPCClient

    public init(rpc: any RuulRPCClient) {
        self.rpc = rpc
    }

    /// Preview init.
    public init(rpc: any RuulRPCClient, previewDocuments: [Document]) {
        self.rpc = rpc
        self.documents = previewDocuments
        self.phase = .loaded
    }

    public func loadResourceDocuments(resourceId: UUID) async {
        if documents.isEmpty { phase = .loading }
        do {
            documents = try await rpc.listResourceDocuments(resourceId: resourceId)
            phase = .loaded
        } catch {
            phase = .failed(message: UserFacingError.from(error).message)
        }
    }

    /// Sube el binario + registra metadata + refresca la lista. Devuelve el id
    /// del documento creado.
    public func attachToResource(
        resource: Resource,
        contextActorId: UUID?,
        fileData: Data,
        fileName: String,
        title: String,
        documentType: DocumentType,
        mimeType: String
    ) async throws -> UUID {
        let scopeId = contextActorId ?? resource.canonicalOwnerActorId ?? resource.id
        let path = Self.makeStoragePath(scope: scopeId, fileName: fileName)
        try await rpc.uploadDocumentFile(path: path, data: fileData, contentType: mimeType)
        let result = try await rpc.registerDocument(RegisterDocumentInput(
            title: title,
            contextActorId: contextActorId,
            documentType: documentType,
            storagePath: path,
            mimeType: mimeType,
            fileSizeBytes: Int64(fileData.count),
            resourceId: resource.id
        ))
        await loadResourceDocuments(resourceId: resource.id)
        return result.documentId
    }

    public func signedURL(for document: Document, expiresIn: Int = 3600) async throws -> URL? {
        guard let path = document.storagePath else { return nil }
        return try await rpc.documentSignedURL(path: path, expiresIn: expiresIn)
    }

    /// Convención de path: `<scope_actor_id>/<random_uuid>-<safe_filename>`.
    /// El UUID prefix evita colisiones cuando dos personas suben "contrato.pdf".
    static func makeStoragePath(scope: UUID, fileName: String) -> String {
        let safe = sanitize(fileName)
        return "\(scope.uuidString)/\(UUID().uuidString)-\(safe)"
    }

    private static func sanitize(_ fileName: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        return fileName.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }.reduce(into: "") { $0.append($1) }
    }
}
