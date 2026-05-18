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
