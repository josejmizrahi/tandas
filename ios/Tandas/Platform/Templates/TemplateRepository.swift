import Foundation
import Supabase
import RuulCore

/// Reads `public.templates`. The registry caches results from this repo at
/// boot. Mutation (create new templates, update version) is admin-only and
/// not exposed here in V1.
protocol TemplateRepository: Actor {
    /// All templates, regardless of `available`. Order: available first,
    /// then by id.
    func templates() async throws -> [Template]

    /// Lookup by id. Returns nil if the row doesn't exist.
    func template(id: String) async throws -> Template?
}

// MARK: - Mock

actor MockTemplateRepository: TemplateRepository {
    private let store: [Template]

    init(seed: [Template] = MockTemplateRepository.defaultSeed) {
        self.store = seed
    }

    func templates() async throws -> [Template] {
        store.sorted { lhs, rhs in
            if lhs.available != rhs.available { return lhs.available }
            return lhs.id < rhs.id
        }
    }

    func template(id: String) async throws -> Template? {
        store.first { $0.id == id }
    }

    /// Minimal in-memory fixture — only the recurring_dinner template with
    /// empty config. Tests that need a fuller config should pass their own
    /// seed.
    static let defaultSeed: [Template] = [
        Template(
            id: "recurring_dinner",
            version: 1,
            name: "Cena recurrente",
            description: "Mock template for tests / previews.",
            icon: "fork.knife",
            config: TemplateConfig(
                id: "recurring_dinner",
                availableInVersion: 1
            ),
            available: true,
            createdAt: nil,
            updatedAt: nil
        )
    ]
}

// MARK: - Live

actor LiveTemplateRepository: TemplateRepository {
    private let client: SupabaseClient
    init(client: SupabaseClient) { self.client = client }

    func templates() async throws -> [Template] {
        try await client
            .from("templates")
            .select("*")
            .order("available", ascending: false)
            .order("id", ascending: true)
            .execute()
            .value
    }

    func template(id: String) async throws -> Template? {
        let rows: [Template] = try await client
            .from("templates")
            .select("*")
            .eq("id", value: id)
            .limit(1)
            .execute()
            .value
        return rows.first
    }
}
