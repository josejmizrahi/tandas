import Foundation

/// One condition in a rule. All conditions on a rule are evaluated and
/// combined with AND.
public struct RuleCondition: Sendable, Hashable, Codable {
    public let type: ConditionType
    public let config: JSONConfig

    public init(type: ConditionType, config: JSONConfig = .empty) {
        self.type = type
        self.config = config
    }
}
