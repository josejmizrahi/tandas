import Testing
@testable import RuulFeatures

@Suite("ResourceDetailTab")
struct ResourceDetailTabTests {
    @Test("allCases is exactly the 5 universal tabs in canonical order")
    func allCasesCanonicalOrder() {
        #expect(ResourceDetailTab.allCases.map(\.rawValue) == [
            "overview", "activity", "rules", "connections", "governance",
        ])
    }

    @Test("labels are Spanish display strings")
    func labelsAreSpanish() {
        #expect(ResourceDetailTab.overview.label == "General")
        #expect(ResourceDetailTab.activity.label == "Actividad")
        #expect(ResourceDetailTab.rules.label == "Reglas")
        #expect(ResourceDetailTab.connections.label == "Conexiones")
        #expect(ResourceDetailTab.governance.label == "Gobierno")
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
