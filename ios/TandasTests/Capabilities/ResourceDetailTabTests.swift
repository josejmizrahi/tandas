import Testing
@testable import RuulFeatures

@Suite("ResourceDetailTab")
struct ResourceDetailTabTests {
    @Test("allCases is exactly the 4 universal tabs in canonical order")
    func allCasesCanonicalOrder() {
        // Per ResourceDetailTab.swift doctrine: no "Gobierno" tab —
        // capabilities are auto-on and never user-visible. Governance
        // sub-surfaces live behind Settings → Governance → Advanced.
        #expect(ResourceDetailTab.allCases.map(\.rawValue) == [
            "overview", "activity", "rules", "connections",
        ])
    }

    @Test("labels are Spanish display strings")
    func labelsAreSpanish() {
        #expect(ResourceDetailTab.overview.label == "General")
        #expect(ResourceDetailTab.activity.label == "Actividad")
        #expect(ResourceDetailTab.rules.label == "Reglas")
        // "Vínculos" instead of "Conexiones" so the four segments fit on
        // iPhone SE width (see ResourceDetailTab.label docstring).
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
