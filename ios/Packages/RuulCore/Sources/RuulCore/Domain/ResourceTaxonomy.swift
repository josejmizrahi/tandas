import Foundation

/// R.5A.B.0 — Una class de recurso (top-level taxonomy de Ruul).
/// 17 classes seedeadas: real_estate, vehicle, financial, document, event, etc.
public struct ResourceClass: Decodable, Sendable, Equatable, Hashable, Identifiable {
    public let classKey: String
    public let displayName: String
    public let description: String?
    public let icon: String?

    public var id: String { classKey }

    enum CodingKeys: String, CodingKey {
        case classKey = "class_key"
        case displayName = "display_name"
        case description
        case icon
    }

    public init(classKey: String, displayName: String, description: String? = nil, icon: String? = nil) {
        self.classKey = classKey
        self.displayName = displayName
        self.description = description
        self.icon = icon
    }
}

/// R.5A.B.0 — Un subtype de recurso. 42 subtypes seedeados + actualizable.
/// Founder firma 2026-06-07: las pantallas que crean recursos DEBEN elegir
/// subtype explícito (no resource_type legacy).
public struct ResourceSubtype: Decodable, Sendable, Equatable, Hashable, Identifiable {
    public let subtypeKey: String
    public let classKey: String
    public let displayName: String
    public let description: String?

    public var id: String { subtypeKey }

    enum CodingKeys: String, CodingKey {
        case subtypeKey = "subtype_key"
        case classKey = "class_key"
        case displayName = "display_name"
        case description
    }

    public init(subtypeKey: String, classKey: String, displayName: String, description: String? = nil) {
        self.subtypeKey = subtypeKey
        self.classKey = classKey
        self.displayName = displayName
        self.description = description
    }
}
