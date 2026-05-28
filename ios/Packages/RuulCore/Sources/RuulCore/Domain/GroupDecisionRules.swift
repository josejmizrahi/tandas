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
///
/// V2-G2 sub-slice 8 — `defaultMethod` + `defaultLegitimacySource` are the
/// canonical surface; `defaultStyle` is the legacy shadow column kept for
/// backward compatibility until a future cleanup. New code should read
/// method + legitimacy.
public struct GroupDecisionRules: Codable, Equatable, Sendable, Hashable {
    public let groupId: UUID
    public let defaultStyle: DecisionStyle
    public let defaultMethod: DecisionMethod
    public let defaultLegitimacySource: LegitimacySource
    public let quorumMin: Int?
    public let notes: String?
    /// `true` when the underlying jsonb is empty (`{}`) — the group has
    /// not yet picked a decision style. The Edit sheet uses this to
    /// distinguish "first time" vs "edit".
    public let isDefault: Bool

    enum CodingKeys: String, CodingKey {
        case groupId                 = "group_id"
        case defaultStyle            = "default_style"
        case defaultMethod           = "default_method"
        case defaultLegitimacySource = "default_legitimacy_source"
        case quorumMin               = "quorum_min"
        case notes
        case isDefault               = "is_default"
    }

    public init(
        groupId: UUID,
        defaultStyle: DecisionStyle,
        defaultMethod: DecisionMethod? = nil,
        defaultLegitimacySource: LegitimacySource? = nil,
        quorumMin: Int? = nil,
        notes: String? = nil,
        isDefault: Bool
    ) {
        self.groupId = groupId
        self.defaultStyle = defaultStyle
        let method = defaultMethod ?? DecisionMethod.forStyle(defaultStyle)
        self.defaultMethod = method
        self.defaultLegitimacySource = defaultLegitimacySource ?? LegitimacySource.defaultFor(method: method)
        self.quorumMin = quorumMin
        self.notes = notes
        self.isDefault = isDefault
    }

    /// Tolerant decode: unknown `default_style` / `default_method` /
    /// `default_legitimacy_source` values fall back to derived defaults
    /// so a forward-compatible backend never crashes the client.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.groupId = try c.decode(UUID.self, forKey: .groupId)
        let styleRaw = try c.decode(String.self, forKey: .defaultStyle)
        let style = DecisionStyle(rawValue: styleRaw) ?? .majority
        self.defaultStyle = style

        let methodRaw = try c.decodeIfPresent(String.self, forKey: .defaultMethod)
        let method = methodRaw.flatMap { DecisionMethod(rawValue: $0) } ?? DecisionMethod.forStyle(style)
        self.defaultMethod = method

        let legitimacyRaw = try c.decodeIfPresent(String.self, forKey: .defaultLegitimacySource)
        self.defaultLegitimacySource = legitimacyRaw.flatMap { LegitimacySource(rawValue: $0) }
            ?? LegitimacySource.defaultFor(method: method)

        self.quorumMin = try c.decodeIfPresent(Int.self, forKey: .quorumMin)
        self.notes = try c.decodeIfPresent(String.self, forKey: .notes)
        self.isDefault = try c.decodeIfPresent(Bool.self, forKey: .isDefault) ?? true
    }
}

public extension DecisionMethod {
    /// V2-G2 sub-slice 8 — legacy `DecisionStyle` → canonical
    /// `DecisionMethod` projection. Mirrors the backfill in
    /// `set_decision_rules` so iOS-derived defaults stay coherent with
    /// what the backend writes.
    static func forStyle(_ style: DecisionStyle) -> DecisionMethod {
        switch style {
        case .adminOnly:     return .admin
        case .majority:      return .majority
        case .supermajority: return .supermajority
        case .unanimity:     return .consensus
        case .consensus:     return .consent
        }
    }

    /// Inverse projection for the legacy column. Used when iOS writes a
    /// non-legacy method (`ranked_choice`, `weighted`, `veto`) — those
    /// collapse onto the closest legacy style for `default_style`.
    var legacyStyle: DecisionStyle {
        switch self {
        case .admin:         return .adminOnly
        case .majority:      return .majority
        case .supermajority: return .supermajority
        case .consensus:     return .unanimity
        case .consent:       return .consensus
        case .rankedChoice:  return .majority
        case .weighted:      return .majority
        case .veto:          return .consensus
        case .other:         return .majority
        }
    }
}

public extension GroupDecisionRules {
    var trimmedNotes: String? {
        guard let notes else { return nil }
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
