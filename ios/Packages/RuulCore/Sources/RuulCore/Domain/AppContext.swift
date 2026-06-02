import Foundation

/// R.1A — context-first foundation. An `AppContext` is the **UX
/// perspective** a user operates from in a given moment. The data model
/// underneath stays actor-centric (one row in `actors` per person/group/
/// legal entity); `AppContext` is the surfaced viewport over an actor.
///
/// Founder lock 2026-06-01: Actor = data, Context = experience.
/// `id` is always the canonical `actor_id` (NOT user_id, NOT group_id —
/// although for groups they happen to coincide thanks to the R.0A
/// forward-sync trigger that mirrors `groups.id` into `actors.id`).
public enum ContextKind: String, Codable, Sendable, Hashable, CaseIterable {
    case person
    case group
    case legalEntity = "legal_entity"
}

public struct AppContext: Sendable, Equatable, Hashable, Identifiable {
    public let id: UUID
    public let kind: ContextKind
    public let displayName: String
    public let subtitle: String?
    public let avatarSymbol: String?
    public let metadata: [String: RPCJSONValue]?

    public init(
        id: UUID,
        kind: ContextKind,
        displayName: String,
        subtitle: String? = nil,
        avatarSymbol: String? = nil,
        metadata: [String: RPCJSONValue]? = nil
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.subtitle = subtitle
        self.avatarSymbol = avatarSymbol
        self.metadata = metadata
    }
}
