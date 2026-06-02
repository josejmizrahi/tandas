import Foundation
import RuulCore

/// R.0H.2 — fixtures for `PersonalHomeView` Xcode previews. Stays close
/// to the real `my_world_summary()` payload shape so design/UX iteration
/// reflects what the user will actually see in production.
enum PersonalHomePreviewData {
    static let actorId  = UUID()
    static let groupId  = UUID()
    static let resOwn   = UUID()
    static let resMgr   = UUID()
    static let entityId = UUID()
    static let decId    = UUID()
    static let eventId  = UUID()

    static let populated: MyWorldSummary = decode(populatedJSON)

    static let empty: MyWorldSummary = decode("""
    {
      "actor": {
        "id": "\(actorId.uuidString)",
        "actor_kind": "person",
        "display_name": "Linda",
        "metadata": null
      }
    }
    """)

    // MARK: - Helpers

    private static func decode(_ json: String) -> MyWorldSummary {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try! decoder.decode(MyWorldSummary.self, from: Data(json.utf8))
    }

    private static let populatedJSON: String = """
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
          {"currency": "MXN", "owned_value": 1250000, "owned_count": 2,
           "resource_ids": ["\(resOwn.uuidString)"]},
          {"currency": "USD", "owned_value": 8500, "owned_count": 1,
           "resource_ids": []}
        ],
        "beneficiary_by_currency": [
          {"currency": "MXN", "value": 300000, "count": 1, "resource_ids": []}
        ],
        "notes": {"fx": "none"}
      },
      "owned_resources": [
        {"resource_id": "\(resOwn.uuidString)", "name": "Terreno Tepoztlán",
         "resource_type": "real_estate", "group_id": "\(groupId.uuidString)",
         "percent": 100, "currency": "MXN", "estimated_value": 950000},
        {"resource_id": "\(UUID().uuidString)", "name": "Cuenta BBVA",
         "resource_type": "fund", "group_id": null,
         "percent": 100, "currency": "MXN", "estimated_value": 300000}
      ],
      "managed_resources": [
        {"resource_id": "\(resMgr.uuidString)", "name": "Fondo familiar",
         "resource_type": "fund", "group_id": "\(groupId.uuidString)"}
      ],
      "used_resources": [],
      "beneficiary_resources": [
        {"resource_id": "\(UUID().uuidString)", "name": "Trust patrimonial",
         "resource_type": "asset", "group_id": null,
         "percent": 50, "currency": "MXN", "estimated_value": 300000}
      ],
      "groups": [
        {"group_id": "\(groupId.uuidString)", "name": "Familia Mizrahi",
         "membership_type": "member", "joined_via": "founder_seed"},
        {"group_id": "\(UUID().uuidString)", "name": "Amigos de la prepa",
         "membership_type": "member", "joined_via": "invite"}
      ],
      "controlled_entities": [
        {"actor_id": "\(entityId.uuidString)", "display_name": "Quimibond Trust",
         "actor_kind": "legal_entity", "relationship_type": "trustee_of",
         "metadata": {"role": "trustee"}}
      ],
      "obligations": [
        {"relationship_id": "\(UUID().uuidString)", "relationship_type": "debtor_to",
         "direction": "out", "subject_actor_id": "\(actorId.uuidString)",
         "object_actor_id": "\(entityId.uuidString)",
         "metadata": {"amount": 50000, "currency": "MXN"}}
      ],
      "recent_activity": [
        {"event_id": "\(eventId.uuidString)", "event_type": "resource.created",
         "group_id": "\(groupId.uuidString)", "entity_kind": "resource",
         "entity_id": "\(resOwn.uuidString)",
         "actor_user_id": "\(actorId.uuidString)",
         "payload": {"name": "Terreno Tepoztlán"},
         "created_at": "2026-06-01T21:30:00Z"},
        {"event_id": "\(UUID().uuidString)", "event_type": "decision.opened",
         "group_id": "\(groupId.uuidString)", "entity_kind": "decision",
         "entity_id": "\(decId.uuidString)",
         "actor_user_id": "\(actorId.uuidString)",
         "payload": {"title": "Cambio de reglas de cuotas"},
         "created_at": "2026-06-01T20:15:00Z"}
      ],
      "pending_decisions": [
        {"decision_id": "\(decId.uuidString)", "title": "Cambio de reglas de cuotas",
         "group_id": "\(groupId.uuidString)", "status": "open",
         "created_at": "2026-06-01T20:00:00Z"}
      ],
      "notes": {"limit_per_section": 20}
    }
    """
}
