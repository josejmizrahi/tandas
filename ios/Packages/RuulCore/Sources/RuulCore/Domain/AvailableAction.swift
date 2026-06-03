import Foundation

/// R.2S-FIX — forma canónica de una acción disponible para un actor en
/// cualquier dominio (resource / decision / reservation / obligation).
/// El backend la calcula vía `_aa(...)` y la inyecta en cada `*_detail` RPC.
public struct AvailableAction: Codable, Sendable, Equatable, Hashable, Identifiable {
    public let actionKey: String
    public let label: String
    public let section: String
    /// `true` si el actor puede ejecutar la acción ahora mismo.
    /// `false` muestra la affordance deshabilitada con `reason`.
    public let enabled: Bool
    /// Explicación humana (en español) de por qué está enabled o disabled.
    public let reason: String?
    public let requiredRights: [String]
    public let requiredCapabilities: [String]

    enum CodingKeys: String, CodingKey {
        case actionKey = "action_key"
        case label
        case section
        case enabled
        case reason
        case requiredRights = "required_rights"
        case requiredCapabilities = "required_capabilities"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.actionKey = try c.decode(String.self, forKey: .actionKey)
        self.label = try c.decode(String.self, forKey: .label)
        self.section = try c.decode(String.self, forKey: .section)
        self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        self.reason = try c.decodeIfPresent(String.self, forKey: .reason)
        self.requiredRights = try c.decodeIfPresent([String].self, forKey: .requiredRights) ?? []
        self.requiredCapabilities = try c.decodeIfPresent([String].self, forKey: .requiredCapabilities) ?? []
    }

    public init(
        actionKey: String,
        label: String,
        section: String,
        enabled: Bool = true,
        reason: String? = nil,
        requiredRights: [String] = [],
        requiredCapabilities: [String] = []
    ) {
        self.actionKey = actionKey
        self.label = label
        self.section = section
        self.enabled = enabled
        self.reason = reason
        self.requiredRights = requiredRights
        self.requiredCapabilities = requiredCapabilities
    }

    public var id: String { actionKey }
}

extension Array where Element == AvailableAction {
    /// Devuelve la acción habilitada con ese key, si existe.
    public func enabled(_ key: String) -> AvailableAction? {
        first { $0.actionKey == key && $0.enabled }
    }

    /// ¿El backend ofrece esta acción habilitada?
    public func can(_ key: String) -> Bool {
        enabled(key) != nil
    }

    /// Acciones de una sección (e.g. "decisions", "reservations").
    public func inSection(_ section: String) -> [AvailableAction] {
        filter { $0.section == section }
    }
}
