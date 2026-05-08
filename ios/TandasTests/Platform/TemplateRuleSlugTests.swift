import Foundation
import XCTest
import RuulCore
@testable import Tandas

/// Tests the slug field on `TemplateRule` and `Rule` round-trips correctly
/// against the jsonb shape written by migration 00035 (templates.config.
/// defaultRules + rules table). Critical contract: the slug column carries
/// the cross-group identifier that `GroupModule.providedRules` references.
final class TemplateRuleSlugTests: XCTestCase {

    func testTemplateRuleDecodesSlug() throws {
        let json = """
        {
          "slug": "dinner_late_arrival",
          "name": "Llegada tardía",
          "description": "Multa por llegar tarde.",
          "module": "basic_fines",
          "isActive": true,
          "trigger": { "eventType": "checkInRecorded", "config": {} },
          "conditions": [
            { "type": "checkInMinutesLate", "config": { "thresholdMinutes": 0 } }
          ],
          "consequences": [
            { "type": "fine", "config": { "amount": 200 } }
          ]
        }
        """.data(using: .utf8)!

        let rule = try JSONDecoder().decode(TemplateRule.self, from: json)
        XCTAssertEqual(rule.slug, "dinner_late_arrival")
        XCTAssertEqual(rule.name, "Llegada tardía")
        XCTAssertEqual(rule.module, "basic_fines")
    }

    func testTemplateRuleDecodesWithoutSlug() throws {
        // Backward compat: rows seeded before 00035 have no slug.
        let json = """
        {
          "name": "User-authored rule",
          "description": "no slug needed",
          "module": "basic_fines",
          "isActive": true,
          "trigger": { "eventType": "eventClosed", "config": {} },
          "conditions": [],
          "consequences": []
        }
        """.data(using: .utf8)!

        let rule = try JSONDecoder().decode(TemplateRule.self, from: json)
        XCTAssertNil(rule.slug)
        XCTAssertEqual(rule.name, "User-authored rule")
    }

    func testDinnerTemplateDeclaresAllSlugs() {
        // The 5 dinner_recurring rules MUST carry their canonical slugs —
        // V1Modules.basicFines.providedRules references them by slug.
        let rules = DinnerRecurringTemplate.defaultRules(groupId: UUID())
        let slugs = rules.compactMap(\.slug)
        XCTAssertEqual(slugs.count, 5, "all 5 rules must carry a slug")
        XCTAssertEqual(Set(slugs), [
            DinnerRecurringTemplate.RuleSlug.lateArrival,
            DinnerRecurringTemplate.RuleSlug.noResponse,
            DinnerRecurringTemplate.RuleSlug.sameDayCancel,
            DinnerRecurringTemplate.RuleSlug.noShow,
            DinnerRecurringTemplate.RuleSlug.hostNoMenu,
        ])
    }

    func testBasicFinesModuleProvidedRulesAreSlugs() {
        // V1Modules.basicFines.providedRules MUST be slugs (not display
        // strings). Each one MUST appear in DinnerRecurringTemplate's
        // declared slugs.
        let mod = ModuleRegistry.module(id: "basic_fines")
        let provided = mod?.providedRules ?? []
        XCTAssertEqual(provided.count, 5)

        let templateSlugs = Set(
            DinnerRecurringTemplate.defaultRules(groupId: UUID())
                .compactMap(\.slug)
        )
        for slug in provided {
            XCTAssertTrue(
                templateSlugs.contains(slug),
                "providedRule '\(slug)' must match a TemplateRule slug"
            )
        }
    }

    func testRuleEncodesSlugAsSnakeCase() throws {
        // Rule.slug encodes as 'slug' (no key transform needed) per
        // CodingKeys. Verifies the rules table column name match.
        let rule = Rule(
            id: UUID(),
            groupId: UUID(),
            slug: "dinner_no_show",
            name: "No-show",
            isActive: true,
            trigger: RuleTrigger(eventType: .eventClosed),
            conditions: [],
            consequences: []
        )
        let data = try JSONEncoder().encode(rule)
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(json["slug"] as? String, "dinner_no_show")
    }
}
