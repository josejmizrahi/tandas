import Foundation

/// A rule shipped as part of a template. When a group is created with a
/// template, each `TemplateRule` is materialized into a `Rule` row in the
/// `rules` table.
///
/// Stored inside `templates.config.defaultRules`. The body mirrors `Rule`'s
/// shape (trigger / conditions / consequences) so the rule engine can run
/// it without translation.
public struct TemplateRule: Sendable, Codable, Hashable {
    public let name: String
    public let description: String
    public let module: String
    public let isActive: Bool
    public let trigger: RuleTrigger
    public let conditions: [RuleCondition]
    public let consequences: [RuleConsequence]

    public init(
        name: String,
        description: String,
        module: String,
        isActive: Bool,
        trigger: RuleTrigger,
        conditions: [RuleCondition],
        consequences: [RuleConsequence]
    ) {
        self.name = name
        self.description = description
        self.module = module
        self.isActive = isActive
        self.trigger = trigger
        self.conditions = conditions
        self.consequences = consequences
    }
}
