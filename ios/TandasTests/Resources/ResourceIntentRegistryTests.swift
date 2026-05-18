import Testing
import Foundation
import RuulCore

@Suite("ResourceIntentRegistry v1")
struct ResourceIntentRegistryTests {
    private let registry = DefaultResourceIntentRegistry.v1
    private let catalog = CapabilityCatalog.v1

    @Test("Every intent id is unique")
    func idUniqueness() {
        var seen: Set<String> = []
        for intent in registry.allIntents {
            #expect(!seen.contains(intent.id), "duplicate intent id: \(intent.id)")
            seen.insert(intent.id)
        }
    }

    @Test("Every requiredCapability resolves in the catalog")
    func requiredCapabilitiesResolve() {
        for intent in registry.allIntents {
            for capId in intent.requiredCapabilities {
                #expect(catalog[capId] != nil,
                        "intent \(intent.id) references unknown capability \(capId)")
            }
        }
    }

    @Test("Required caps are enabled for the intent's resource types")
    func requiredCapsTypeMatch() {
        for intent in registry.allIntents {
            for capId in intent.requiredCapabilities {
                guard let block = catalog[capId] else { continue }
                let blockTypes = Set(block.enabledResourceTypes)
                // The intent must only declare resource types where this
                // capability is actually enabled — otherwise the intent
                // would surface for a type that can't accept the cap.
                let overlap = intent.resourceTypes.intersection(blockTypes)
                #expect(!overlap.isEmpty,
                        "intent \(intent.id) requires \(capId) which isn't enabled for any of its declared resource types")
            }
        }
    }

    @Test("Intents lookup by resource type returns expected matches")
    func intentsForType() {
        let eventIntents = registry.intents(for: .event)
        #expect(eventIntents.contains { $0.id == "invite_people" })
        #expect(eventIntents.contains { $0.id == "check_in_attendees" })

        let fundIntents = registry.intents(for: .fund)
        #expect(fundIntents.contains { $0.id == "record_contribution" })
        #expect(fundIntents.contains { $0.id == "record_expense" })

        let rightIntents = registry.intents(for: .right)
        #expect(rightIntents.contains { $0.id == "assign_holder" })
    }

    @Test("'ledger' is forbidden in user-facing labels and copy")
    func ledgerNotInLabels() {
        // 2026-05-18 adjustment 2: Destination.ledgerEntryForm is OK as
        // internal id, but no user-facing string may contain "ledger".
        for intent in registry.allIntents {
            let surfaces = [
                intent.humanLabel, intent.summary,
                intent.firstRunCopy, intent.emptyStateCopy
            ]
            for surface in surfaces {
                #expect(!surface.lowercased().contains("ledger"),
                        "intent \(intent.id) surface contains 'ledger': '\(surface)'")
            }
        }
    }

    @Test("No intent label uses other forbidden doctrine vocabulary")
    func forbiddenVocabulary() {
        let forbidden = ["capability", "atom", "projection", "rule shape",
                         "trigger", "consequence", "module"]
        for intent in registry.allIntents {
            let surfaces = [
                intent.humanLabel, intent.summary,
                intent.firstRunCopy, intent.emptyStateCopy
            ]
            for surface in surfaces {
                let lower = surface.lowercased()
                for word in forbidden {
                    #expect(!lower.contains(word),
                            "intent \(intent.id) surface '\(surface)' contains forbidden '\(word)'")
                }
            }
        }
    }

    @Test("Beta catalog has exactly 18 intents (matching design count)")
    func intentCount() {
        #expect(registry.allIntents.count == 18)
    }
}
