import Foundation

/// Primitivas 6 (Poder/Autoridad), 16 (Decisiones) y 22 (Legitimidad).
/// Mirrors the canonical `groups.decision_rules` jsonb (read via the
/// `group_decision_rules(p_group_id)` RPC, written via
/// `set_decision_rules(...)`). Foundation V1 surfaces a single
/// declared "decision style" + optional quorum + free-form notes —
/// per-action overrides remain in the jsonb shape for future slices
/// without changing this surface.
public enum DecisionStyle: String, Codable, CaseIterable, Identifiable, Sendable, Hashable {
    case adminOnly     = "admin_only"
    case majority
    case supermajority
    case unanimity
    case consensus

    public var id: String { rawValue }

    /// Fixed render order for pickers; mirrors the doctrine ladder
    /// from "single decider" to "everyone must agree".
    public static let displayOrder: [DecisionStyle] = [
        .adminOnly, .majority, .supermajority, .unanimity, .consensus
    ]

    public var label: LocalizedStringResource {
        switch self {
        case .adminOnly:     return L10n.DecisionRules.styleAdminOnly
        case .majority:      return L10n.DecisionRules.styleMajority
        case .supermajority: return L10n.DecisionRules.styleSupermajority
        case .unanimity:     return L10n.DecisionRules.styleUnanimity
        case .consensus:     return L10n.DecisionRules.styleConsensus
        }
    }

    public var subtitle: LocalizedStringResource {
        switch self {
        case .adminOnly:     return L10n.DecisionRules.styleAdminOnlySubtitle
        case .majority:      return L10n.DecisionRules.styleMajoritySubtitle
        case .supermajority: return L10n.DecisionRules.styleSupermajoritySubtitle
        case .unanimity:     return L10n.DecisionRules.styleUnanimitySubtitle
        case .consensus:     return L10n.DecisionRules.styleConsensusSubtitle
        }
    }

    public var systemImageName: String {
        switch self {
        case .adminOnly:     return "person.crop.circle.badge.checkmark"
        case .majority:      return "chart.bar.fill"
        case .supermajority: return "chart.bar.doc.horizontal"
        case .unanimity:     return "hand.thumbsup"
        case .consensus:     return "person.3.sequence"
        }
    }
}

/// Decoded shape of `group_decision_rules(...)` / `set_decision_rules(...)`.
public struct GroupDecisionRules: Codable, Equatable, Sendable, Hashable {
    public let groupId: UUID
    public let defaultStyle: DecisionStyle
    public let quorumMin: Int?
    public let notes: String?
    /// `true` when the underlying jsonb is empty (`{}`) — the group has
    /// not yet picked a decision style. The Edit sheet uses this to
    /// distinguish "first time" vs "edit".
    public let isDefault: Bool

    enum CodingKeys: String, CodingKey {
        case groupId      = "group_id"
        case defaultStyle = "default_style"
        case quorumMin    = "quorum_min"
        case notes
        case isDefault    = "is_default"
    }

    public init(
        groupId: UUID,
        defaultStyle: DecisionStyle,
        quorumMin: Int? = nil,
        notes: String? = nil,
        isDefault: Bool
    ) {
        self.groupId = groupId
        self.defaultStyle = defaultStyle
        self.quorumMin = quorumMin
        self.notes = notes
        self.isDefault = isDefault
    }

    /// Tolerant decode: unknown `default_style` values fall back to
    /// `.majority` so a forward-compatible backend never crashes the
    /// client.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.groupId = try c.decode(UUID.self, forKey: .groupId)
        let raw = try c.decode(String.self, forKey: .defaultStyle)
        self.defaultStyle = DecisionStyle(rawValue: raw) ?? .majority
        self.quorumMin = try c.decodeIfPresent(Int.self, forKey: .quorumMin)
        self.notes = try c.decodeIfPresent(String.self, forKey: .notes)
        self.isDefault = try c.decodeIfPresent(Bool.self, forKey: .isDefault) ?? true
    }
}

public extension GroupDecisionRules {
    var trimmedNotes: String? {
        guard let notes else { return nil }
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
