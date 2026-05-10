import Testing
import Foundation
import RuulCore
@testable import Tandas

@Suite("CapabilityCatalog")
struct CapabilityCatalogTests {
    @Test("v1 catalog has the expected V1 blocks")
    func v1HasV1Blocks() {
        let c = CapabilityCatalog.v1
        for id in ["rsvp", "check_in", "schedule", "recurrence", "rotation",
                   "assignment", "participants", "attendance", "deadline",
                   "approval", "money", "ledger", "voting", "rules",
                   "consequence", "appeal", "swap"] {
            #expect(c[id] != nil, "missing \(id)")
        }
    }

    @Test("byId map is unique on id")
    func byIdUniqueness() {
        let c = CapabilityCatalog.v1
        #expect(c.byId.count == c.blocks.count)
    }

    @Test("transitiveDependencies returns block + transitive deps")
    func transitiveDeps() {
        let c = CapabilityCatalog.v1
        let appealDeps = c.transitiveDependencies(of: "appeal")
        #expect(appealDeps.contains("appeal"))
        #expect(appealDeps.contains("voting"))
        #expect(appealDeps.contains("consequence"))
        // consequence depends on rules
        #expect(appealDeps.contains("rules"))
    }

    @Test("blocks(for:) filters by enabledResourceTypes")
    func blocksForResourceType() {
        let c = CapabilityCatalog.v1
        let eventBlocks = c.blocks(for: .event).map(\.id)
        #expect(eventBlocks.contains("rsvp"))
        #expect(eventBlocks.contains("check_in"))
        #expect(!eventBlocks.contains("swap"), "swap is for slot/booking, not event")
    }
}
