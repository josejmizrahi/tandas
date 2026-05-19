import Testing
@testable import RuulFeatures

@Suite("ResourceDetailTab")
struct ResourceDetailTabTests {
    @Test("allCases is exactly the 6 universal tabs in canonical order")
    func allCasesCanonicalOrder() {
        // Per V2 Human-Layer doctrine (Plans/Active/ProductCompression.md):
        // General · Gente · Dinero · Reglas · Actividad · Relacionado.
        // Gente/Dinero/Relacionado are content-gated by the host view, so
        // a typical resource still surfaces 3-5 tabs on screen.
        #expect(ResourceDetailTab.allCases.map(\.rawValue) == [
            "overview", "people", "money", "rules", "activity", "connections",
        ])
    }

    @Test("labels are Spanish display strings")
    func labelsAreSpanish() {
        #expect(ResourceDetailTab.overview.label == "General")
        #expect(ResourceDetailTab.people.label == "Gente")
        #expect(ResourceDetailTab.money.label == "Dinero")
        #expect(ResourceDetailTab.rules.label == "Reglas")
        #expect(ResourceDetailTab.activity.label == "Actividad")
        // "Relacionado" replaces the older "Vínculos" (graph-model leak)
        // per V1 §C.1. Host hides the tab when empty.
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
