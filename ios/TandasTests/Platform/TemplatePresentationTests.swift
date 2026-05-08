import Foundation
import XCTest
import RuulUI
import RuulCore
@testable import Tandas

/// Tests that `Template.config.presentation` + `defaultCategory`
/// round-trip cleanly against the jsonb shape written by migration 00037.
/// These are the fields that absorb legacy group-type presentation data
/// per audit doc § 5.3 item 7c.
final class TemplatePresentationTests: XCTestCase {

    func testTemplateConfigDecodesPresentationAndCategory() throws {
        let json = """
        {
          "id": "recurring_dinner",
          "availableInVersion": 1,
          "presentation": {
            "displayName": "Cena recurrente",
            "symbolName": "fork.knife",
            "description": "Cena semanal o mensual con anfitrión rotativo",
            "bullets": [
              "Anfitrión rota turno a turno",
              "Multa automática por llegar tarde"
            ],
            "defaultEventLabel": "Cena"
          },
          "defaultCategory": "socialRecurring"
        }
        """.data(using: .utf8)!

        let cfg = try JSONDecoder().decode(TemplateConfig.self, from: json)
        XCTAssertEqual(cfg.presentation?.displayName, "Cena recurrente")
        XCTAssertEqual(cfg.presentation?.symbolName, "fork.knife")
        XCTAssertEqual(cfg.presentation?.bullets?.count, 2)
        XCTAssertEqual(cfg.presentation?.defaultEventLabel, "Cena")
        XCTAssertEqual(cfg.defaultCategory, .socialRecurring)
    }

    func testTemplateConfigDecodesWithoutPresentationOrCategory() throws {
        // Backward compat — config seeded pre-00037 has neither field.
        let json = """
        {"id":"shared_resource","availableInVersion":2}
        """.data(using: .utf8)!
        let cfg = try JSONDecoder().decode(TemplateConfig.self, from: json)
        XCTAssertNil(cfg.presentation)
        XCTAssertNil(cfg.defaultCategory)
    }

    func testTemplateEffectiveAccessorsPreferPresentation() {
        let cfg = TemplateConfig(
            id: "x",
            availableInVersion: 1,
            presentation: TemplatePresentation(
                displayName: "Cena recurrente",
                symbolName: "fork.knife",
                description: "Long copy",
                bullets: ["one", "two"],
                defaultEventLabel: "Cena"
            ),
            defaultCategory: .socialRecurring
        )
        let template = Template(
            id: "x",
            version: 1,
            name: "Top-level name",
            description: "Top-level description",
            icon: "questionmark",
            config: cfg,
            available: true,
            createdAt: nil,
            updatedAt: nil
        )
        XCTAssertEqual(template.effectiveDisplayName, "Cena recurrente")
        XCTAssertEqual(template.effectiveSymbolName, "fork.knife")
        XCTAssertEqual(template.effectiveDescription, "Long copy")
        XCTAssertEqual(template.effectiveBullets, ["one", "two"])
        XCTAssertEqual(template.effectiveDefaultEventLabel, "Cena")
        XCTAssertEqual(template.effectiveDefaultCategory, .socialRecurring)
    }

    func testTemplateEffectiveAccessorsFallBackToTopLevel() {
        // Config without presentation — accessors fall back to
        // Template.name/icon/description.
        let cfg = TemplateConfig(id: "x", availableInVersion: 1)
        let template = Template(
            id: "x",
            version: 1,
            name: "Cena recurrente",
            description: "Top-level description",
            icon: "fork.knife",
            config: cfg,
            available: true,
            createdAt: nil,
            updatedAt: nil
        )
        XCTAssertEqual(template.effectiveDisplayName, "Cena recurrente")
        XCTAssertEqual(template.effectiveSymbolName, "fork.knife")
        XCTAssertEqual(template.effectiveDescription, "Top-level description")
        XCTAssertEqual(template.effectiveBullets, [])
        XCTAssertEqual(template.effectiveDefaultEventLabel, "evento")
        XCTAssertEqual(template.effectiveDefaultCategory, .socialRecurring)
    }

    func testTemplateEffectiveDefaultEventLabelReadsFromDefaultSettings() {
        // If presentation.defaultEventLabel is nil but defaultSettings
        // has eventVocabulary, accessor returns that.
        let settings: JSONConfig = .object([
            "eventVocabulary": .string("Tanda")
        ])
        let cfg = TemplateConfig(
            id: "rotating_savings",
            availableInVersion: 3,
            defaultSettings: settings,
            presentation: TemplatePresentation(displayName: "Tanda")
        )
        let template = Template(
            id: "rotating_savings",
            version: 1,
            name: "Tanda",
            description: "",
            icon: "x",
            config: cfg,
            available: false,
            createdAt: nil,
            updatedAt: nil
        )
        XCTAssertEqual(template.effectiveDefaultEventLabel, "Tanda")
    }
}
