import Testing
import Foundation
import RuulCore

@Suite("ResourceVariantRegistry v1")
struct ResourceVariantRegistryTests {
    private let registry = DefaultResourceVariantRegistry.v1
    private let catalog = CapabilityCatalog.v1
    private let intents = DefaultResourceIntentRegistry.v1

    @Test("Beta-1 ships exactly 18 variants (3 per type)")
    func variantCount() {
        #expect(registry.allVariants.count == 18)
        for type in ResourceType.allCases {
            #expect(registry.variants(for: type).count == 3,
                    "expected 3 variants for \(type.rawString), got \(registry.variants(for: type).count)")
        }
    }

    @Test("Picker surfaces 14 variants — sports_match/travel_fund/venue/ticket hidden")
    func pickableVariantCount() {
        // V2 Slice 3A (Plans/Active/ProductCompression.md §D.2): 4 of 18
        // Beta variants are hidden from the picker as recipes-in-waiting.
        // They remain registered for id-lookup. The 5th candidate
        // (one of event.social_gathering / event.recurring_event) is
        // deferred per V2 §K.1 pending founder decision.
        let pickable = ResourceType.allCases.flatMap { registry.pickableVariants(for: $0) }
        #expect(pickable.count == 14, "expected 14 pickable variants, got \(pickable.count)")

        let pickablePerType: [(ResourceType, Int)] = [
            (.event, 2),   // social_gathering, recurring_event   (sports_match hidden)
            (.fund,  2),   // shared_expenses,  investment_fund   (travel_fund   hidden)
            (.asset, 3),
            (.space, 2),   // private_space,    reservable_space  (venue         hidden)
            (.slot,  2),   // seat,             shift             (ticket        hidden)
            (.right, 3),
        ]
        for (type, expected) in pickablePerType {
            let count = registry.pickableVariants(for: type).count
            #expect(count == expected,
                    "expected \(expected) pickable variants for \(type.rawString), got \(count)")
        }

        // Hidden variants stay reachable via id-lookup so existing
        // resources continue to resolve their variant.
        for id in ["event.sports_match", "fund.travel_fund", "space.venue", "slot.ticket"] {
            #expect(registry.variant(id: id) != nil,
                    "hidden variant \(id) must still resolve via variant(id:)")
            #expect(registry.variant(id: id)?.isVisibleInPicker == false,
                    "hidden variant \(id) must be flagged isVisibleInPicker == false")
        }
    }

    @Test("Every variant id is unique and follows '<type>.<name>' convention")
    func idConvention() {
        var seen: Set<String> = []
        for variant in registry.allVariants {
            #expect(!seen.contains(variant.id), "duplicate variant id: \(variant.id)")
            seen.insert(variant.id)
            #expect(variant.id.hasPrefix("\(variant.resourceType.rawString)."),
                    "variant id \(variant.id) doesn't start with \(variant.resourceType.rawString).")
        }
    }

    @Test("Every attachedCapability resolves to a stable block in the catalog")
    func attachedCapabilitiesResolve() {
        for variant in registry.allVariants {
            for capId in variant.attachedCapabilities {
                guard let block = catalog[capId] else {
                    Issue.record("variant \(variant.id) references unknown capability \(capId)")
                    continue
                }
                #expect(block.status.isStable,
                        "variant \(variant.id) attaches incomplete capability \(capId)")
                #expect(block.enabledResourceTypes.contains(variant.resourceType),
                        "capability \(capId) is not enabled for \(variant.resourceType.rawString)")
            }
        }
    }

    @Test("Every suggested intent resolves in the intent registry")
    func intentsResolve() {
        for variant in registry.allVariants {
            for intentId in variant.suggestedIntents {
                guard let intent = intents.intent(id: intentId) else {
                    Issue.record("variant \(variant.id) references unknown intent \(intentId)")
                    continue
                }
                #expect(intent.resourceTypes.contains(variant.resourceType),
                        "intent \(intentId) doesn't support \(variant.resourceType.rawString)")
            }
        }
    }

    @Test("No variant copy contains forbidden doctrine vocabulary")
    func forbiddenVocabulary() {
        // Per 2026-05-18 doctrine: capability, atom, projection, rule shape,
        // trigger, consequence, ledger, module — none allowed in user copy.
        let forbidden = ["capability", "atom", "projection", "rule shape",
                         "trigger", "consequence", "ledger", "module"]
        for variant in registry.allVariants {
            let surfaces = [
                variant.humanName, variant.summary, variant.postCreateHeadline
            ] + variant.examples
            for surface in surfaces {
                let lower = surface.lowercased()
                for word in forbidden {
                    #expect(!lower.contains(word),
                            "variant \(variant.id) surface '\(surface)' contains forbidden '\(word)'")
                }
            }
        }
    }
}
