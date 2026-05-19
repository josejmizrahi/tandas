import Testing
@testable import RuulFeatures

@Suite("ResourceDetailTab")
struct ResourceDetailTabTests {
    @Test("allCases is exactly the 6 universal tabs in canonical order")
    func allCasesCanonicalOrder() {
        // Per ResourceDetailTab.swift doctrine: no "Gobierno" tab —
        // capabilities are auto-on and never user-visible. Governance
        // sub-surfaces live behind Settings → Governance → Advanced.
        //
        // Slice 2A (Plans/Active/HumanLayerSimplification.md §C.1) added
        // .people between overview and activity. Slice 2B inserted .money
        // between people and activity. Slice 2C revisits connections
        // naming/fold. Activity / rules positions preserved across slices
        // per the "one cognitive decision per slice" rule.
        #expect(ResourceDetailTab.allCases.map(\.rawValue) == [
            "overview", "people", "money", "activity", "rules", "connections",
        ])
    }

    @Test("labels are Spanish display strings")
    func labelsAreSpanish() {
        #expect(ResourceDetailTab.overview.label == "General")
        #expect(ResourceDetailTab.people.label == "Gente")
        #expect(ResourceDetailTab.money.label == "Dinero")
        #expect(ResourceDetailTab.activity.label == "Actividad")
        #expect(ResourceDetailTab.rules.label == "Reglas")
        // Slice 2C renamed "Vínculos" → "Relacionado". "Vínculo" was on
        // the forbidden-vocab list (Plans/Active/HumanLayerSimplification.md
        // §D) because it exposes the resource_links graph model.
        #expect(ResourceDetailTab.connections.label == "Relacionado")
    }

    @Test("id mirrors rawValue")
    func idMirrorsRawValue() {
        for tab in ResourceDetailTab.allCases {
            #expect(tab.id == tab.rawValue)
        }
    }

    @Test("symbol returns non-empty SF Symbol per tab")
    func symbolNonEmpty() {
        for tab in ResourceDetailTab.allCases {
            #expect(!tab.symbol.isEmpty)
        }
    }
}
