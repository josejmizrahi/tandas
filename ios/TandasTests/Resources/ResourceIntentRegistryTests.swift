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

    @Test("Beta catalog contains the 18 post-create universal verbs")
    func postCreateIntentsPresent() {
        // The post-create screen relies on these 18 ids; toolbar-only
        // intents (releaseCustody, transferAsset, etc.) extend the
        // catalog but aren't asserted here. Hard count removed because
        // the catalog grows independently of the post-create surface.
        let postCreateIds: Set<String> = [
            "invite_people", "check_in_attendees", "track_money",
            "record_contribution", "record_expense", "allow_reservations",
            "assign_holder", "grant_access", "assign_custody",
            "record_valuation", "link_resource", "add_rules",
            "create_child_event", "create_child_slot", "define_priority",
            "change_control", "view_history", "view_balance"
        ]
        let registered = Set(registry.allIntents.map(\.id))
        let missing = postCreateIds.subtracting(registered)
        #expect(missing.isEmpty, "missing post-create intents: \(missing)")
    }

    @Test("Quiet-bar intents are registered and cover all 6 resource types")
    func quietBarIntents() {
        // V2 Slice 3B (Plans/Active/ProductCompression.md §C.1): the
        // universal quiet bar surfaces 6 verbs at the bottom of every
        // Resource Detail Overview. Each must resolve in the registry,
        // and 4 of the 6 (view_history, add_rules, share_resource,
        // edit_resource, archive_resource) must cover all 6 resource
        // types so the bar reads identically across the app.
        //
        // track_money is universal for the 5 non-right types (no money
        // on a pure right). link_resource is intentionally absent until
        // the picker generalizes beyond events.
        let quietBarUniversal: Set<String> = [
            "view_history", "add_rules",
            "share_resource", "edit_resource", "archive_resource"
        ]
        let allTypes = Set(ResourceType.allCases)
        for id in quietBarUniversal {
            guard let intent = registry.intent(id: id) else {
                Issue.record("quiet-bar intent \(id) not in registry")
                continue
            }
            #expect(intent.resourceTypes == allTypes,
                    "quiet-bar intent \(id) must declare all 6 resource types, got \(intent.resourceTypes)")
        }

        // track_money exists on 5 of 6 (skip .right).
        guard let trackMoney = registry.intent(id: "track_money") else {
            Issue.record("track_money intent missing")
            return
        }
        #expect(trackMoney.resourceTypes == allTypes.subtracting([.right]),
                "track_money should cover all types except .right, got \(trackMoney.resourceTypes)")
    }
}
