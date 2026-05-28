import Foundation

/// Primitiva 4: las reglas del grupo. Each row maps to one
/// `public.group_rules` × current `public.group_rule_versions` join
/// returned by `group_rules_active(...)`. Foundation only renders
/// `executionMode == .text`; engine rules live in the same tables but
/// are filtered out by the read RPC.
public enum GroupRuleType: String, Codable, CaseIterable, Identifiable, Sendable, Hashable {
    case norm
    case requirement
    case prohibition
    case process
    case principle

    public var id: String { rawValue }

    public static let displayOrder: [GroupRuleType] = [
        .principle, .norm, .requirement, .prohibition, .process
    ]

    public var label: LocalizedStringResource {
        switch self {
        case .norm:        return L10n.Rules.normLabel
        case .requirement: return L10n.Rules.requirementLabel
        case .prohibition: return L10n.Rules.prohibitionLabel
        case .process:     return L10n.Rules.processLabel
        case .principle:   return L10n.Rules.principleLabel
        }
    }

    public var systemImageName: String {
        switch self {
        case .norm:        return "checkmark.seal"
        case .requirement: return "exclamationmark.square"
        case .prohibition: return "hand.raised"
        case .process:     return "arrow.triangle.2.circlepath"
        case .principle:   return "sparkles"
        }
    }
}

public enum GroupRuleExecutionMode: String, Codable, Sendable, Hashable {
    case text
    case engine
}

public struct GroupRule: Identifiable, Codable, Equatable, Sendable, Hashable {
    public let id: UUID                            // rule_id
    public let currentVersionId: UUID?
    public let groupId: UUID
    public let title: String
    public let body: String
    public let ruleType: GroupRuleType
    public let severity: Int
    public let executionMode: GroupRuleExecutionMode
    public let status: String
    public let createdBy: UUID?
    public let effectiveFrom: Date?
    public let createdAt: Date?
    public let updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id                = "rule_id"
        case currentVersionId  = "current_version_id"
        case groupId           = "group_id"
        case title
        case body
        case ruleType          = "rule_type"
        case severity
        case executionMode     = "execution_mode"
        case status
        case createdBy         = "created_by"
        case effectiveFrom     = "effective_from"
        case createdAt         = "created_at"
        case updatedAt         = "updated_at"
    }

    public init(
        id: UUID,
        currentVersionId: UUID? = nil,
        groupId: UUID,
        title: String,
        body: String,
        ruleType: GroupRuleType = .norm,
        severity: Int = 1,
        executionMode: GroupRuleExecutionMode = .text,
        status: String = "active",
        createdBy: UUID? = nil,
        effectiveFrom: Date? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.currentVersionId = currentVersionId
        self.groupId = groupId
        self.title = title
        self.body = body
        self.ruleType = ruleType
        self.severity = severity
        self.executionMode = executionMode
        self.status = status
        self.createdBy = createdBy
        self.effectiveFrom = effectiveFrom
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.currentVersionId = try c.decodeIfPresent(UUID.self, forKey: .currentVersionId)
        self.groupId = try c.decode(UUID.self, forKey: .groupId)
        self.title = try c.decode(String.self, forKey: .title)
        self.body = (try c.decodeIfPresent(String.self, forKey: .body)) ?? ""
        let rawType = try c.decode(String.self, forKey: .ruleType)
        self.ruleType = GroupRuleType(rawValue: rawType) ?? .norm
        self.severity = (try c.decodeIfPresent(Int.self, forKey: .severity)) ?? 1
        let rawMode = try c.decode(String.self, forKey: .executionMode)
        self.executionMode = GroupRuleExecutionMode(rawValue: rawMode) ?? .text
        self.status = try c.decode(String.self, forKey: .status)
        self.createdBy = try c.decodeIfPresent(UUID.self, forKey: .createdBy)
        self.effectiveFrom = try c.decodeIfPresent(Date.self, forKey: .effectiveFrom)
        self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        self.updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
    }
}

public extension GroupRule {
    var isHighSeverity: Bool { severity >= 3 }

    /// Localised "Severidad: N" — backend stores integers 0..5; we
    /// surface them as a short label rather than naming each level.
    var severityLabel: String { "·\(severity)" }

    /// Single-line preview of the body for compact lists.
    var previewText: String {
        body
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Result of `create_text_rule(...)`: the new rule id + the first
/// published version id.
public struct CreateTextRuleResult: Codable, Equatable, Sendable {
    public let ruleId: UUID
    public let versionId: UUID

    enum CodingKeys: String, CodingKey {
        case ruleId    = "rule_id"
        case versionId = "version_id"
    }

    public init(ruleId: UUID, versionId: UUID) {
        self.ruleId = ruleId
        self.versionId = versionId
    }
}

/// Result of `promote_norm_to_rule(...)`: the new rule id + first
/// version id + the retired norm id.
public struct PromoteNormToRuleResult: Codable, Equatable, Sendable {
    public let ruleId: UUID
    public let versionId: UUID
    public let normId: UUID

    enum CodingKeys: String, CodingKey {
        case ruleId    = "rule_id"
        case versionId = "version_id"
        case normId    = "norm_id"
    }

    public init(ruleId: UUID, versionId: UUID, normId: UUID) {
        self.ruleId = ruleId
        self.versionId = versionId
        self.normId = normId
    }
}
