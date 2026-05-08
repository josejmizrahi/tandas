import Foundation

/// One consequence in a rule. All consequences execute when the rule's
/// conditions match. V1 only implements `ConsequenceType.fine`; others
/// are scaffolded but throw on the server when invoked.
public struct RuleConsequence: Sendable, Hashable, Codable {
    public let type: ConsequenceType
    public let config: JSONConfig

    public init(type: ConsequenceType, config: JSONConfig = .empty) {
        self.type = type
        self.config = config
    }
}
