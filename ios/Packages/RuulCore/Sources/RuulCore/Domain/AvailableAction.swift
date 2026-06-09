import Foundation

/// R.7.D — Cómo el backend espera que el cliente ejecute la acción.
/// `direct`: invocar el RPC canónico directo (comportamiento default histórico).
/// `requestDecision`: la acción requiere aprobación colectiva — el cliente debe
/// abrir el flow de governance (sheet "Esta acción requiere aprobación" →
/// `request_governance_action` → push DecisionDetailView).
public enum ActionMode: String, Codable, Sendable, Hashable {
    case direct
    case requestDecision = "request_decision"
}

/// R.2S-FIX — forma canónica de una acción disponible para un actor en
/// cualquier dominio (resource / decision / reservation / obligation).
/// El backend la calcula vía `_aa(...)` y la inyecta en cada `*_detail` RPC.
/// R.7.D — opcionalmente trae `mode` cuando el descriptor pasó por
/// `_aa_apply_governance_mode` (member/context descriptors). `mode == nil`
/// significa `direct` (default histórico).
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
    /// R.7.D — `nil` cuando el descriptor no aplica governance mode (default `direct`).
    public let mode: ActionMode?

    enum CodingKeys: String, CodingKey {
        case actionKey = "action_key"
        case label
        case section
        case enabled
        case reason
        case requiredRights = "required_rights"
        case requiredCapabilities = "required_capabilities"
        case mode
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
        self.mode = try c.decodeIfPresent(ActionMode.self, forKey: .mode)
    }

    public init(
        actionKey: String,
        label: String,
        section: String,
        enabled: Bool = true,
        reason: String? = nil,
        requiredRights: [String] = [],
        requiredCapabilities: [String] = [],
        mode: ActionMode? = nil
    ) {
        self.actionKey = actionKey
        self.label = label
        self.section = section
        self.enabled = enabled
        self.reason = reason
        self.requiredRights = requiredRights
        self.requiredCapabilities = requiredCapabilities
        self.mode = mode
    }

    public var id: String { actionKey }

    /// R.7.D — `true` si la acción requiere aprobación colectiva.
    public var requiresDecision: Bool { mode == .requestDecision }
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
