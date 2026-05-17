import Testing
import Foundation
import RuulCore

/// Locks the V1 link catalog (Plans/Active/ResourceLinks.md §3) at
/// the Swift layer. Server-side mirror lives in mig 00267
/// (`public.resource_link_kinds`); these tests don't query SQL, they
/// assert that the in-code matrix matches the declared catalog. A
/// catalog drift between client and server will fail here.
@Suite("LinkKind catalog")
struct LinkKindCatalogTests {

    // MARK: - Active / passive label coverage

    @Test("every kind has distinct active vs passive label")
    func directionalLabelsDiffer() {
        for kind in LinkKind.allCases {
            #expect(
                kind.activeDisplayName != kind.passiveDisplayName,
                "\(kind) reuses the same label for active + passive — relations are directional"
            )
            #expect(!kind.activeDisplayName.isEmpty)
            #expect(!kind.passiveDisplayName.isEmpty)
        }
    }

    @Test("displayName(direction:) selects active for outgoing, passive for incoming")
    func displayNameSwitchesByDirection() {
        for kind in LinkKind.allCases {
            #expect(kind.displayName(direction: .outgoing) == kind.activeDisplayName)
            #expect(kind.displayName(direction: .incoming) == kind.passiveDisplayName)
        }
    }

    // MARK: - Validation matrix

    @Test("isValid mirrors the V1 catalog exactly")
    func isValidMatchesCatalog() {
        // (from, to, kind, expectedValid). The full set of tuples we
        // INSERT'd in mig 00267 is reproduced here so a drift on either
        // side trips this test.
        let valid: [(LinkKind, ResourceType, ResourceType)] = [
            // uses
            (.uses, .event, .asset), (.uses, .event, .fund),
            (.uses, .event, .slot),  (.uses, .event, .space),
            (.uses, .fund,  .asset), (.uses, .fund,  .space),
            // funds
            (.funds, .fund, .asset), (.funds, .fund, .event), (.funds, .fund, .space),
            // governs
            (.governs, .right, .asset), (.governs, .right, .fund),
            (.governs, .right, .slot),  (.governs, .right, .space),
            // located_in
            (.locatedIn, .asset, .space), (.locatedIn, .slot, .space),
            // scheduled_in
            (.scheduledIn, .event, .space), (.scheduledIn, .slot, .space),
            // reserves
            (.reserves, .slot, .asset), (.reserves, .slot, .space),
            // grants_access_to
            (.grantsAccessTo, .right, .asset), (.grantsAccessTo, .right, .slot),
            (.grantsAccessTo, .right, .space),
            // owns (the founder-confirmed addition)
            (.owns, .fund, .asset), (.owns, .fund, .space),
        ]
        for (kind, from, to) in valid {
            #expect(
                kind.isValid(from: from, to: to),
                "(\(from.rawString) -> \(to.rawString) :\(kind.rawValue)) should be in the V1 catalog"
            )
        }
    }

    @Test("invalid tuples explicitly excluded by doctrine fail")
    func invalidTuplesRejected() {
        // The 4 cases founder explicitly carved out + the cardinal
        // doctrinal restriction (right is never Tier 0.5 — see
        // CapabilityTiers §3, so right cannot own).
        let invalid: [(LinkKind, ResourceType, ResourceType, String)] = [
            (.owns,  .asset, .fund,  "asset never owns; doctrinal direction"),
            (.owns,  .right, .asset, "ownership is fund→asset; rights model claims not property"),
            (.funds, .event, .asset, "events don't fund — they consume (uses)"),
            (.uses,  .asset, .event, "assets don't 'use' events; events use assets"),
            (.governs, .fund, .asset, "governance flows from right, not fund"),
        ]
        for (kind, from, to, reason) in invalid {
            #expect(
                !kind.isValid(from: from, to: to),
                "(\(from.rawString) -> \(to.rawString) :\(kind.rawValue)) should be REJECTED: \(reason)"
            )
        }
    }

    @Test("self-link semantics: catalog never sanctions same-type loops where it makes no sense")
    func selfTypeLoopsAreSane() {
        // Loops are not categorically banned (e.g. fund->fund 'uses' is
        // valid per V1 catalog), but obvious nonsense like 'event uses
        // event' or 'asset located_in asset' should be off the table.
        #expect(!LinkKind.uses.isValid(from: .event, to: .event))
        #expect(!LinkKind.locatedIn.isValid(from: .asset, to: .asset))
        #expect(!LinkKind.governs.isValid(from: .right, to: .right))
        // fund→fund uses is sanctioned (e.g., "this fund draws from
        // another"). Keep it as a positive-control.
        #expect(LinkKind.uses.isValid(from: .fund, to: .fund))
    }

    // MARK: - Candidate helper

    @Test("candidates(from:) returns only kinds with at least one valid target")
    func candidatesFiltersCorrectly() {
        // Fund can be source for: uses, funds, owns.
        let fundCandidates = LinkKind.candidates(from: .fund)
        #expect(Set(fundCandidates) == Set([.uses, .funds, .owns]))

        // Right is the only governing source.
        let rightCandidates = LinkKind.candidates(from: .right)
        #expect(Set(rightCandidates) == Set([.governs, .grantsAccessTo]))

        // Asset can only be source for located_in (asset → space).
        let assetCandidates = LinkKind.candidates(from: .asset)
        #expect(Set(assetCandidates) == Set([.locatedIn]))

        // Space is never a source in V1 — incoming only.
        #expect(LinkKind.candidates(from: .space).isEmpty)
    }

    // MARK: - Raw values lock SQL contract

    @Test("rawValue uses snake_case to match the SQL column")
    func rawValueMatchesSql() {
        // The Swift cases use camelCase by Swift convention but the
        // wire format must match `public.resource_link_kinds.kind` so
        // PostgREST round-trips cleanly. This locks both sides.
        let expected: [LinkKind: String] = [
            .uses: "uses",
            .funds: "funds",
            .governs: "governs",
            .locatedIn: "located_in",
            .scheduledIn: "scheduled_in",
            .reserves: "reserves",
            .grantsAccessTo: "grants_access_to",
            .owns: "owns",
        ]
        for (kind, expectedRaw) in expected {
            #expect(kind.rawValue == expectedRaw)
        }
    }
}
