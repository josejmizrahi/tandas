import Testing
@testable import RuulFeatures

@Suite("ResourceDetailTab")
struct ResourceDetailTabTests {
    @Test("allCases is exactly the 5 universal tabs in canonical order")
    func allCasesCanonicalOrder() {
        // Per ResourceDetailTab.swift doctrine: no "Gobierno" tab —
        // capabilities are auto-on and never user-visible. Governance
        // sub-surfaces live behind Settings → Governance → Advanced.
        //
        // Slice 2A (Plans/Active/HumanLayerSimplification.md §C.1) added
        // .people between overview and activity. Slice 2B will insert
        // .money between people and activity; Slice 2C revisits
        // connections naming/fold.
        #expect(ResourceDetailTab.allCases.map(\.rawValue) == [
            "overview", "people", "activity", "rules", "connections",
        ])
    }

    @Test("labels are Spanish display strings")
    func labelsAreSpanish() {
        #expect(ResourceDetailTab.overview.label == "General")
        #expect(ResourceDetailTab.people.label == "Gente")
        #expect(ResourceDetailTab.activity.label == "Actividad")
        #expect(ResourceDetailTab.rules.label == "Reglas")
        // "Vínculos" instead of "Conexiones" so the segments fit on
        // iPhone SE width (see ResourceDetailTab.label docstring).
        // Slice 2C revisits this naming.
        #expect(ResourceDetailTab.connections.label == "Vínculos")
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
