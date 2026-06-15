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
    /// Documents V2 (D.2) — lista por contexto (separado de `documents` que es por recurso).
    public private(set) var contextDocuments: [Document] = []
    public private(set) var contextPhase: StorePhase = .idle

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

    /// Documents V2 (D.2) — carga documentos del contexto (cross-resource).
    /// Vía `list_context_documents` RPC con joins enriquecidos (owner/resource display_name).
    public func loadContextDocuments(contextId: UUID, includeArchived: Bool = false) async {
        if contextDocuments.isEmpty { contextPhase = .loading }
        do {
            contextDocuments = try await rpc.listContextDocuments(
                contextId: contextId,
                includeArchived: includeArchived
            )
            contextPhase = .loaded
        } catch {
            contextPhase = .failed(message: UserFacingError.from(error).message)
        }
    }

    /// Documents V2 (D.0) — soft delete vía `archive_document` RPC.
    /// Refresh granular: si el doc estaba en contextDocuments lo marca archived inline
    /// (evita full reload). El caller decide si recarga lista completa.
    public func archive(documentId: UUID, contextId: UUID? = nil) async throws {
        try await rpc.archiveDocument(documentId: documentId)
        // Refresh contexto si lo tenemos cargado.
        if let contextId, !contextDocuments.isEmpty {
            await loadContextDocuments(contextId: contextId, includeArchived: false)
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
        mimeType: String,
        metadata: JSONValue? = nil
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
            resourceId: resource.id,
            metadata: metadata
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
