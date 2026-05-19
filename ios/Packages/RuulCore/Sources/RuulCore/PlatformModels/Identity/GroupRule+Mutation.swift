import Foundation

public extension GroupRule {
    /// Returns a copy of this rule with `isActive` set to the given value.
    /// Used by EditRulesCoordinator for the optimistic-toggle path. Since
    /// `GroupRule` properties are `let`, this constructs a new instance.
    func withIsActive(_ isActive: Bool) -> GroupRule {
        GroupRule(
            id: id,
            groupId: groupId,
            slug: slug,
            name: name,
            isActive: isActive,
            trigger: trigger,
            conditions: conditions,
            consequences: consequences,
            exceptions: exceptions,
            conditionsTree: conditionsTree,
            moduleKey: moduleKey,
            resourceId: resourceId,
            seriesId: seriesId,
            membershipId: membershipId
        )
    }
}
