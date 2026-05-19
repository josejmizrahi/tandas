import Foundation

/// Draft of a rule shown in the founder onboarding step 4. Mutable as the
/// user toggles activeness and edits the amount. Slice E.2 collapsed this
/// onto the platform shape — `slug`, `trigger`, `conditions`, and
/// `consequences` are now stored fields and the LiveRuleRepository sends
/// them straight to `create_initial_rule`.
public struct OnboardingRuleDraft: Identifiable, Codable, Sendable, Hashable {
    public let id: UUID
    /// Stable cross-group identifier (e.g. `dinner_late_arrival`). Persisted
    /// in `rules.slug`. The 5 dinner-template values are defined under
    /// `DinnerRecurringTemplate.RuleSlug.*`.
    public let slug: String
    public var name: String
    /// Static description shown in the onboarding info sheet. Not persisted
    /// per-rule (E.2 dropped `rules.description`); template-level copy lives
    /// in `templates.config.defaultRules`.
    public var description: String
    public var isActive: Bool
    public let trigger: RuleTrigger
    public let conditions: [RuleCondition]
    public var consequences: [RuleConsequence]

    public init(
        id: UUID = UUID(),
        slug: String,
        name: String,
        description: String,
        isActive: Bool,
        trigger: RuleTrigger,
        conditions: [RuleCondition],
        consequences: [RuleConsequence]
    ) {
        self.id = id
        self.slug = slug
        self.name = name
        self.description = description
        self.isActive = isActive
        self.trigger = trigger
        self.conditions = conditions
        self.consequences = consequences
    }

}

/// Default 5 rules for the founder onboarding step 4. 4 active + 1 off.
/// Mirrors `templates.config.defaultRules` (the canonical jsonb seeded by
/// migration 00038) and `seed_dinner_template_rules`. Consequences match
/// the values the rule engine expects: rule 1 escalating, rules 2–5 flat.
public extension OnboardingRuleDraft {
    static let defaults: [OnboardingRuleDraft] = [
        OnboardingRuleDraft(
            slug: DinnerRecurringTemplate.RuleSlug.lateArrival,
            name: "Llegar tarde",
            description: "$200 base + $50 por cada 30 min después.",
            isActive: true,
            trigger: RuleTrigger(eventType: .checkInRecorded),
            conditions: [
                RuleCondition(
                    type: .checkInMinutesLate,
                    config: .object(["thresholdMinutes": .int(0)])
                )
            ],
            consequences: [
                RuleConsequence(
                    type: .fine,
                    config: .object([
                        "baseAmount":  .int(200),
                        "stepAmount":  .int(50),
                        "stepMinutes": .int(30)
                    ])
                )
            ]
        ),
        OnboardingRuleDraft(
            slug: DinnerRecurringTemplate.RuleSlug.noResponse,
            name: "No confirmar antes del día anterior",
            description: "Si no confirmas asistencia antes de las 20:00 del día anterior.",
            isActive: true,
            trigger: RuleTrigger(eventType: .eventClosed),
            conditions: [
                RuleCondition(
                    type: .responseStatusIs,
                    config: .object(["status": .string("pending")])
                )
            ],
            consequences: [
                RuleConsequence(
                    type: .fine,
                    config: .object(["amount": .int(200)])
                )
            ]
        ),
        OnboardingRuleDraft(
            slug: DinnerRecurringTemplate.RuleSlug.sameDayCancel,
            name: "Cancelar el mismo día",
            description: "Si cancelas tu asistencia el día del evento.",
            isActive: true,
            trigger: RuleTrigger(eventType: .rsvpChangedSameDay),
            conditions: [RuleCondition(type: .alwaysTrue)],
            consequences: [
                RuleConsequence(
                    type: .fine,
                    config: .object(["amount": .int(200)])
                )
            ]
        ),
        OnboardingRuleDraft(
            slug: DinnerRecurringTemplate.RuleSlug.noShow,
            name: "No-show",
            description: "Si confirmaste y no llegaste sin avisar.",
            isActive: true,
            trigger: RuleTrigger(eventType: .eventClosed),
            conditions: [
                RuleCondition(
                    type: .responseStatusIs,
                    config: .object(["status": .string("going")])
                ),
                RuleCondition(
                    type: .checkInExists,
                    config: .object(["exists": .bool(false)])
                )
            ],
            consequences: [
                RuleConsequence(
                    type: .fine,
                    config: .object(["amount": .int(300)])
                )
            ]
        ),
        OnboardingRuleDraft(
            slug: DinnerRecurringTemplate.RuleSlug.hostNoMenu,
            name: "Anfitrión sin avisar el menú",
            description: "Si eres host y no avisas el menú con 24h de anticipación.",
            isActive: false,
            trigger: RuleTrigger(
                eventType: .hoursBeforeEvent,
                config: .object(["hours": .int(24)])
            ),
            conditions: [RuleCondition(type: .eventDescriptionMissing)],
            consequences: [
                RuleConsequence(
                    type: .fine,
                    config: .object(["amount": .int(200)])
                )
            ]
        )
    ]
}
