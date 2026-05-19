import Testing
import Foundation
import RuulCore

@Suite("StateHeadlineResolver invariants")
struct StateHeadlineResolverTests {
    @Test("headline is never empty after normalization")
    func nonEmptyHeadline() {
        let raw = StateHeadline(
            headline: "   ",
            supportingFacts: ["fallback fact"],
            primaryAction: nil,
            urgency: .ambient
        )
        let resolved = StateHeadlineResolver.normalize(raw, fallback: "Recurso activo")
        #expect(resolved.headline == "Recurso activo")
    }

    @Test("trims headline whitespace but preserves non-empty text")
    func trimsWhitespace() {
        let raw = StateHeadline(
            headline: "  Ana hospeda mañana  ",
            supportingFacts: [],
            primaryAction: nil,
            urgency: .actionable
        )
        let resolved = StateHeadlineResolver.normalize(raw, fallback: "x")
        #expect(resolved.headline == "Ana hospeda mañana")
    }

    @Test("removes supporting facts that are empty or whitespace")
    func dropsEmptyFacts() {
        let raw = StateHeadline(
            headline: "x",
            supportingFacts: ["20:00", "", "  ", "Casa de Ana"],
            primaryAction: nil,
            urgency: .ambient
        )
        let resolved = StateHeadlineResolver.normalize(raw, fallback: "x")
        #expect(resolved.supportingFacts == ["20:00", "Casa de Ana"])
    }
}
