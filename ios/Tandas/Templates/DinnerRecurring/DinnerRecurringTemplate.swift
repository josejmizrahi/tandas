import Foundation
import RuulCore

/// Static configuration + factory for the V1 template "Cena recurrente".
///
/// Holds the 5 default rules pre-loaded when a founder picks this template
/// in onboarding. Each rule is a Platform `Rule` (with trigger / conditions
/// / consequences) so the rule engine in `_shared/ruleEngine.ts` evaluates
/// them on the matching SystemEvents.
///
/// Sprint 1b wires this from the founder onboarding coordinator: after the
/// group is created, the iOS app calls `seed_dinner_template_rules` RPC
/// which inserts these rules atomically.
public enum DinnerRecurringTemplate {

    /// Canonical stable slugs for the 5 dinner_recurring rules.
    /// Mirror the `code` column written by `seed_dinner_template_rules`
    /// (migration 00015). Referenced by `GroupModule.providedRules` so
    /// the link survives display rename + i18n.
    public enum RuleSlug {
        public static let lateArrival       = "dinner_late_arrival"
        public static let noResponse        = "dinner_no_response"
        public static let sameDayCancel     = "dinner_same_day_cancel"
        public static let noShow            = "dinner_no_show"
        public static let hostNoMenu        = "dinner_host_no_menu"
    }

    /// The 5 default rules for "Cena recurrente". All MXN amounts; the
    /// template-specific UI in Sprint 1c will let founders edit amounts +
    /// toggle activeness before the group goes live.
    public static func defaultRules(groupId: UUID) -> [Rule] {
        [
            // Rule 1 — Llegada tardía (escalating fine)
            //   trigger:   checkInRecorded
            //   condition: checkInMinutesLate(threshold: 0)
            //   action:    fine(base 200 + step 50 every 30 min late)
            Rule(
                groupId: groupId,
                slug: RuleSlug.lateArrival,
                name: "Llegada tardía",
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

            // Rule 2 — No confirmó a tiempo
            //   trigger:   eventClosed
            //   condition: responseStatusIs(pending)
            //   action:    fine(200)
            Rule(
                groupId: groupId,
                slug: RuleSlug.noResponse,
                name: "No confirmó a tiempo",
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

            // Rule 3 — Cancelación mismo día
            //   trigger:   rsvpChangedSameDay
            //   condition: alwaysTrue
            //   action:    fine(200)
            Rule(
                groupId: groupId,
                slug: RuleSlug.sameDayCancel,
                name: "Cancelación mismo día",
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

            // Rule 4 — No-show
            //   trigger:    eventClosed
            //   conditions: responseStatusIs(going) AND checkInExists(false)
            //   action:     fine(300)
            Rule(
                groupId: groupId,
                slug: RuleSlug.noShow,
                name: "No-show",
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

            // Rule 5 — Anfitrión sin menú (default OFF)
            //   trigger:   hoursBeforeEvent(24)
            //   condition: eventDescriptionMissing
            //   action:    fine(200)
            Rule(
                groupId: groupId,
                slug: RuleSlug.hostNoMenu,
                name: "Anfitrión sin menú",
                isActive: false,  // off by default
                trigger: RuleTrigger(
                    eventType: .hoursBeforeEvent,
                    config: .object(["hours": .int(24)])
                ),
                conditions: [
                    RuleCondition(type: .eventDescriptionMissing)
                ],
                consequences: [
                    RuleConsequence(
                        type: .fine,
                        config: .object(["amount": .int(200)])
                    )
                ]
            )
        ]
    }
}
