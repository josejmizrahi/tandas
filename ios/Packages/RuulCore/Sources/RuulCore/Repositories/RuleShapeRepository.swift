import Foundation
import Supabase

/// Loads the rule shape catalog (`public.rule_shapes`) from the server.
/// Used by AppState at boot to populate `RuleShapeRegistry`. Mirrors the
/// `LiveModuleRegistry` pattern.
public protocol RuleShapeRepository: Sendable {
    func load() async throws -> RuleShapeRegistry
}

public actor MockRuleShapeRepository: RuleShapeRepository {
    private let registry: RuleShapeRegistry
    public init(registry: RuleShapeRegistry = .v1Fallback) {
        self.registry = registry
    }
    public func load() async throws -> RuleShapeRegistry { registry }
}

public actor LiveRuleShapeRepository: RuleShapeRepository {
    private let client: SupabaseClient
    public init(client: SupabaseClient) { self.client = client }

    public func load() async throws -> RuleShapeRegistry {
        let shapes: [RuleShape] = try await client
            .rpc("list_rule_shapes")
            .execute()
            .value
        return RuleShapeRegistry(shapes: shapes)
    }
}
