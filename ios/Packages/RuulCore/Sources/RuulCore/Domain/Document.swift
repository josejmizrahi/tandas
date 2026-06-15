import Foundation

/// Categoría de un documento. Coincide con el CHECK constraint del backend
/// (`documents.document_type` ∈ contract / receipt / id / statement / photo /
/// other / policy / certificate). R.12.G alineó el CHECK con el catálogo
/// resource_subtypes class='document' (5 subtypes con field schemas) +
/// preservó los legacy text values en uso.
public enum DocumentType: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case contract
    case receipt
    case id
    case statement
    case photo
    case other
    // R.12.G — catalog-aligned subtypes con field schemas (R.12.A populated).
    case policy
    case certificate

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .contract: return "Contrato"
        case .receipt: return "Recibo"
        case .id: return "Identificación"
        case .statement: return "Estado de cuenta"
        case .photo: return "Foto"
        case .other: return "Otro"
        case .policy: return "Póliza"
        case .certificate: return "Certificado"
        }
    }

    public var symbolName: String {
        switch self {
        case .contract: return "doc.text.fill"
        case .receipt: return "receipt.fill"
        case .id: return "person.text.rectangle.fill"
        case .statement: return "list.bullet.rectangle.portrait.fill"
        case .photo: return "photo.fill"
        case .other: return "doc.fill"
        case .policy: return "shield.lefthalf.filled"
        case .certificate: return "rosette"
        }
    }
}

/// Una fila de la tabla `documents`. Lectura PostgREST con RLS
/// (`documents_select`: owner / creator / miembro del contexto).
public struct Document: Decodable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let ownerActorId: UUID
    public let contextActorId: UUID?
    public let title: String
    public let documentType: DocumentType
    public let storagePath: String?
    public let mimeType: String?
    public let fileSizeBytes: Int64?
    public let resourceId: UUID?
    public let decisionId: UUID?
    public let eventId: UUID?
    public let createdAt: Date?

    // Documents V2 (D.1) — joins enriquecidos del `list_context_documents` RPC.
    /// Display name del owner (join en backend). Opcional en lecturas PostgREST directas.
    public let ownerDisplayName: String?
    /// Display name del resource asociado (si aplica).
    public let resourceDisplayName: String?
    /// Soft delete timestamp (FQ-1 founder firma: immutable + archived_at).
    public let archivedAt: Date?
    /// Metadata jsonb del documento (versionables, OCR future, etc.).
    public let metadata: JSONValue?

    enum CodingKeys: String, CodingKey {
        case id
        case ownerActorId = "owner_actor_id"
        case contextActorId = "context_actor_id"
        case title
        case documentType = "document_type"
        case storagePath = "storage_path"
        case mimeType = "mime_type"
        case fileSizeBytes = "file_size_bytes"
        case resourceId = "resource_id"
        case decisionId = "decision_id"
        case eventId = "event_id"
        case createdAt = "created_at"
        case ownerDisplayName = "owner_display_name"
        case resourceDisplayName = "resource_display_name"
        case archivedAt = "archived_at"
        case metadata
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.ownerActorId = try c.decode(UUID.self, forKey: .ownerActorId)
        self.contextActorId = try c.decodeIfPresent(UUID.self, forKey: .contextActorId)
        self.title = try c.decode(String.self, forKey: .title)
        let raw = try c.decodeIfPresent(String.self, forKey: .documentType) ?? "other"
        self.documentType = DocumentType(rawValue: raw) ?? .other
        self.storagePath = try c.decodeIfPresent(String.self, forKey: .storagePath)
        self.mimeType = try c.decodeIfPresent(String.self, forKey: .mimeType)
        self.fileSizeBytes = try c.decodeIfPresent(Int64.self, forKey: .fileSizeBytes)
        self.resourceId = try c.decodeIfPresent(UUID.self, forKey: .resourceId)
        self.decisionId = try c.decodeIfPresent(UUID.self, forKey: .decisionId)
        self.eventId = try c.decodeIfPresent(UUID.self, forKey: .eventId)
        self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        self.ownerDisplayName = try c.decodeIfPresent(String.self, forKey: .ownerDisplayName)
        self.resourceDisplayName = try c.decodeIfPresent(String.self, forKey: .resourceDisplayName)
        self.archivedAt = try c.decodeIfPresent(Date.self, forKey: .archivedAt)
        self.metadata = try c.decodeIfPresent(JSONValue.self, forKey: .metadata)
    }

    public init(
        id: UUID,
        ownerActorId: UUID,
        contextActorId: UUID? = nil,
        title: String,
        documentType: DocumentType = .other,
        storagePath: String? = nil,
        mimeType: String? = nil,
        fileSizeBytes: Int64? = nil,
        resourceId: UUID? = nil,
        decisionId: UUID? = nil,
        eventId: UUID? = nil,
        createdAt: Date? = nil,
        ownerDisplayName: String? = nil,
        resourceDisplayName: String? = nil,
        archivedAt: Date? = nil,
        metadata: JSONValue? = nil
    ) {
        self.id = id
        self.ownerActorId = ownerActorId
        self.contextActorId = contextActorId
        self.title = title
        self.documentType = documentType
        self.storagePath = storagePath
        self.mimeType = mimeType
        self.fileSizeBytes = fileSizeBytes
        self.resourceId = resourceId
        self.decisionId = decisionId
        self.eventId = eventId
        self.createdAt = createdAt
        self.ownerDisplayName = ownerDisplayName
        self.resourceDisplayName = resourceDisplayName
        self.archivedAt = archivedAt
        self.metadata = metadata
    }

    /// Tamaño formateado humano-legible (e.g., "1.2 MB").
    public var fileSizeLabel: String? {
        guard let bytes = fileSizeBytes else { return nil }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// UX Doctrine §4: documento archivado si `archived_at IS NOT NULL`.
    public var isArchived: Bool { archivedAt != nil }
}

/// Input de `register_document`. Title es lo único obligatorio del backend;
/// el resto es opcional y se rellena con la metadata del upload.
public struct RegisterDocumentInput: Sendable, Equatable {
    public var title: String
    public var contextActorId: UUID?
    public var documentType: DocumentType
    public var storagePath: String?
    public var mimeType: String?
    public var fileSizeBytes: Int64?
    public var resourceId: UUID?
    public var eventId: UUID?
    public var metadata: JSONValue?

    public init(
        title: String,
        contextActorId: UUID? = nil,
        documentType: DocumentType = .other,
        storagePath: String? = nil,
        mimeType: String? = nil,
        fileSizeBytes: Int64? = nil,
        resourceId: UUID? = nil,
        eventId: UUID? = nil,
        metadata: JSONValue? = nil
    ) {
        self.title = title
        self.contextActorId = contextActorId
        self.documentType = documentType
        self.storagePath = storagePath
        self.mimeType = mimeType
        self.fileSizeBytes = fileSizeBytes
        self.resourceId = resourceId
        self.eventId = eventId
        self.metadata = metadata
    }
}

/// Resultado de `register_document` → `{document_id: uuid}`.
public struct DocumentRegistered: Decodable, Sendable, Equatable {
    public let documentId: UUID

    enum CodingKeys: String, CodingKey {
        case documentId = "document_id"
    }

    public init(documentId: UUID) {
        self.documentId = documentId
    }
}
