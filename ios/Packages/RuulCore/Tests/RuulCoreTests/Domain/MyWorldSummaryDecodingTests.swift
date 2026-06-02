import Foundation
import Testing
@testable import RuulCore

/// R.0H.1 — verifies that `MyWorldSummary` Codable is tolerant per the
/// founder ajustes:
///   1. Arrays default `[]` (decodeIfPresent ?? [])
///   2. metadata como `[String: RPCJSONValue]?` (jsonb tolerante)
///   3. Fechas opcionales si el RPC cambia formato
///   4. Unknown fields ignorados (default Codable behavior)
@Suite("R.0H.1 — MyWorldSummary decoding")
struct MyWorldSummaryDecodingTests {

    private func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    // MARK: - Caso 1 — JSON completo (representative of a populated world)

    @Test("Caso 1: decodes a fully-populated my_world_summary payload")
    func decodesFullPayload() throws {
        let actorId   = UUID()
        let groupId   = UUID()
        let resOwnId  = UUID()
        let resMgrId  = UUID()
        let entityId  = UUID()
        let relId     = UUID()
        let eventId   = UUID()
        let decId     = UUID()

        let json = """
        {
          "actor": {
            "id": "\(actorId.uuidString)",
            "actor_kind": "person",
            "display_name": "Jose",
            "metadata": {"source": "r0a_backfill"}
          },
          "as_of": "2026-06-01T22:00:00Z",
          "net_worth": {
            "actor_id": "\(actorId.uuidString)",
            "as_of": "2026-06-01T22:00:00Z",
            "owned_by_currency": [
              {"currency": "MXN", "owned_value": 1000, "owned_count": 1, "resource_ids": ["\(resOwnId.uuidString)"]}
            ],
            "beneficiary_by_currency": [],
            "notes": {"fx": "none"}
          },
          "owned_resources": [
            {"resource_id": "\(resOwnId.uuidString)", "name": "Terreno", "resource_type": "asset",
             "group_id": "\(groupId.uuidString)", "percent": 100, "currency": "MXN", "estimated_value": 1000}
          ],
          "managed_resources": [
            {"resource_id": "\(resMgrId.uuidString)", "name": "Documento", "resource_type": "document",
             "group_id": "\(groupId.uuidString)"}
          ],
          "used_resources": [],
          "beneficiary_resources": [],
          "groups": [
            {"group_id": "\(groupId.uuidString)", "name": "Familia", "membership_type": "member", "joined_via": "founder_seed"}
          ],
          "controlled_entities": [
            {"actor_id": "\(entityId.uuidString)", "display_name": "Quimibond Trust",
             "actor_kind": "legal_entity", "relationship_type": "shareholder_of",
             "metadata": {"percent": 70}}
          ],
          "obligations": [
            {"relationship_id": "\(relId.uuidString)", "relationship_type": "debtor_to",
             "direction": "out", "subject_actor_id": "\(actorId.uuidString)",
             "object_actor_id": "\(entityId.uuidString)",
             "metadata": {"amount": 5000, "currency": "MXN"}}
          ],
          "recent_activity": [
            {"event_id": "\(eventId.uuidString)", "event_type": "resource.created",
             "group_id": "\(groupId.uuidString)", "entity_kind": "resource",
             "entity_id": "\(resOwnId.uuidString)",
             "actor_user_id": "\(actorId.uuidString)",
             "payload": {"note": "smoke"},
             "created_at": "2026-06-01T21:00:00Z"}
          ],
          "pending_decisions": [
            {"decision_id": "\(decId.uuidString)", "title": "Reglas",
             "group_id": "\(groupId.uuidString)", "status": "open",
             "created_at": "2026-06-01T20:00:00Z"}
          ],
          "notes": {"limit_per_section": 20}
        }
        """.data(using: .utf8)!

        let summary = try makeDecoder().decode(MyWorldSummary.self, from: json)

        #expect(summary.actor.id == actorId)
        #expect(summary.actor.actorKind == "person")
        #expect(summary.actor.displayName == "Jose")
        #expect(summary.netWorth?.ownedByCurrency.count == 1)
        #expect(summary.netWorth?.ownedByCurrency.first?.currency == "MXN")
        #expect(summary.netWorth?.ownedByCurrency.first?.ownedValue == Decimal(1000))
        #expect(summary.ownedResources.count == 1)
        #expect(summary.ownedResources.first?.resourceId == resOwnId)
        #expect(summary.ownedResources.first?.percent == Decimal(100))
        #expect(summary.ownedResources.first?.estimatedValue == Decimal(1000))
        #expect(summary.managedResources.count == 1)
        #expect(summary.usedResources.isEmpty)
        #expect(summary.beneficiaryResources.isEmpty)
        #expect(summary.groups.first?.name == "Familia")
        #expect(summary.controlledEntities.first?.relationshipType == "shareholder_of")
        #expect(summary.obligations.first?.direction == "out")
        #expect(summary.obligations.first?.relationshipType == "debtor_to")
        #expect(summary.recentActivity.first?.eventType == "resource.created")
        #expect(summary.pendingDecisions.first?.status == "open")
        #expect(summary.notes?["limit_per_section"] != nil)
    }

    // MARK: - Caso 2 — JSON con arrays vacíos / sections missing

    @Test("Caso 2: missing/empty arrays default to [] without throwing")
    func decodesEmptySections() throws {
        let actorId = UUID()
        // Note: managed_resources, beneficiary_resources, controlled_entities,
        // obligations, recent_activity, pending_decisions are all OMITTED;
        // others are explicit empty arrays. All should land as [].
        let json = """
        {
          "actor": {"id": "\(actorId.uuidString)", "actor_kind": "person",
                    "display_name": "Solo", "metadata": null},
          "owned_resources": [],
          "used_resources": [],
          "groups": []
        }
        """.data(using: .utf8)!

        let summary = try makeDecoder().decode(MyWorldSummary.self, from: json)

        #expect(summary.actor.id == actorId)
        #expect(summary.actor.metadata == nil)
        #expect(summary.asOf == nil)
        #expect(summary.netWorth == nil)
        #expect(summary.ownedResources.isEmpty)
        #expect(summary.managedResources.isEmpty)
        #expect(summary.usedResources.isEmpty)
        #expect(summary.beneficiaryResources.isEmpty)
        #expect(summary.groups.isEmpty)
        #expect(summary.controlledEntities.isEmpty)
        #expect(summary.obligations.isEmpty)
        #expect(summary.recentActivity.isEmpty)
        #expect(summary.pendingDecisions.isEmpty)
        #expect(summary.notes == nil)
    }

    // MARK: - Caso 3 — metadata arbitraria + unknown fields ignorados

    @Test("Caso 3: arbitrary metadata jsonb + future fields are tolerated")
    func decodesArbitraryMetadataAndUnknownFields() throws {
        let actorId = UUID()
        let entityId = UUID()
        let relId = UUID()
        let json = """
        {
          "actor": {
            "id": "\(actorId.uuidString)",
            "actor_kind": "person",
            "display_name": "Linda",
            "metadata": {
              "phone": "+52...",
              "tags": ["beta_user", "early_adopter"],
              "deep": {"nested": {"flag": true, "count": 7}},
              "value": 1234.5
            },
            "future_field_that_did_not_exist_yet": "should be ignored"
          },
          "controlled_entities": [
            {"actor_id": "\(entityId.uuidString)",
             "display_name": null,
             "actor_kind": "legal_entity",
             "relationship_type": "trustee_of",
             "metadata": {"role": "trustee", "voting_rights": false}}
          ],
          "obligations": [
            {"relationship_id": "\(relId.uuidString)",
             "relationship_type": "guarantor_of",
             "direction": "out",
             "subject_actor_id": "\(actorId.uuidString)",
             "object_resource_id": "\(UUID().uuidString)",
             "metadata": {"note": "endorsement"}}
          ],
          "net_worth": {
            "owned_by_currency": [],
            "beneficiary_by_currency": [],
            "extra_section_we_dont_know_yet": "ignored"
          },
          "unexpected_top_level": ["this", "is", "ignored"]
        }
        """.data(using: .utf8)!

        let summary = try makeDecoder().decode(MyWorldSummary.self, from: json)

        #expect(summary.actor.displayName == "Linda")
        // Metadata preserved as opaque RPCJSONValue object
        let actorMeta = summary.actor.metadata
        #expect(actorMeta?["phone"] != nil)
        #expect(actorMeta?["tags"] != nil)
        #expect(actorMeta?["deep"] != nil)
        // Controlled entity metadata is also opaque
        #expect(summary.controlledEntities.first?.relationshipType == "trustee_of")
        #expect(summary.controlledEntities.first?.metadata?["role"] != nil)
        // Obligation with object_resource_id branch
        let oblig = summary.obligations.first
        #expect(oblig?.relationshipType == "guarantor_of")
        #expect(oblig?.objectResourceId != nil)
        #expect(oblig?.objectActorId == nil)
        // Unknown fields silently ignored — no decoding error
    }
}
