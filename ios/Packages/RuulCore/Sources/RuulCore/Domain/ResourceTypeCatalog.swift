import Foundation

/// Una entrada del `resource_type_catalog()`. El backend es la autoridad sobre
/// qué tipos de recursos existen, sus labels, iconos, metadata esperada y
/// capabilities. iOS sólo renderiza — no decide comportamiento por type_key.
public struct ResourceTypeCatalogEntry: Decodable, Sendable, Equatable, Identifiable {
    public let typeKey: String
    public let displayName: String
    public let description: String?
    public let icon: String?
    public let expectedMetadata: JSONValue?
    public let capabilities: [String]

    public var id: String { typeKey }

    enum CodingKeys: String, CodingKey {
        case typeKey = "type_key"
        case displayName = "display_name"
        case description
        case icon
        case expectedMetadata = "expected_metadata"
        case capabilities
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.typeKey = try c.decode(String.self, forKey: .typeKey)
        self.displayName = try c.decode(String.self, forKey: .displayName)
        self.description = try c.decodeIfPresent(String.self, forKey: .description)
        self.icon = try c.decodeIfPresent(String.self, forKey: .icon)
        self.expectedMetadata = try c.decodeIfPresent(JSONValue.self, forKey: .expectedMetadata)
        self.capabilities = try c.decodeIfPresent([String].self, forKey: .capabilities) ?? []
    }

    public init(
        typeKey: String,
        displayName: String,
        description: String? = nil,
        icon: String? = nil,
        expectedMetadata: JSONValue? = nil,
        capabilities: [String] = []
    ) {
        self.typeKey = typeKey
        self.displayName = displayName
        self.description = description
        self.icon = icon
        self.expectedMetadata = expectedMetadata
        self.capabilities = capabilities
    }

    public func has(_ capability: String) -> Bool {
        capabilities.contains(capability)
    }
}

/// Wrapper del resultado `resource_type_catalog()` — es una raíz array, pero
/// el wrapper permite añadir helpers + persistencia stable.
public struct ResourceTypeCatalog: Sendable, Equatable {
    public let entries: [ResourceTypeCatalogEntry]

    public init(entries: [ResourceTypeCatalogEntry]) {
        self.entries = entries
    }

    public func entry(for typeKey: String) -> ResourceTypeCatalogEntry? {
        entries.first { $0.typeKey == typeKey }
    }

    public func entry(for type: ResourceType) -> ResourceTypeCatalogEntry? {
        entry(for: type.rawValue)
    }
}

extension ResourceTypeCatalog: Decodable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let arr = try container.decode([ResourceTypeCatalogEntry].self)
        self.init(entries: arr)
    }
}
