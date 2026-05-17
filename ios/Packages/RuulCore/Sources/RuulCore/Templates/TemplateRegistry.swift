import Foundation
import OSLog

/// In-memory cache of templates loaded from `TemplateRepository`. Boots
/// once at app start (`refresh()`), thereafter serves lookups synchronously
/// from cache. Re-fetch on demand if a template's `version` changes.
///
/// Keeps the hot path (group creation, RootShell render, onboarding
/// step lookup) free of network round trips.
///
/// **Static IDs**: Swift code that needs to reference a specific template
/// by name (e.g. backward-compat defaults in deserializers, onboarding
/// gates) reads the `…Id` constants below. The pattern is "declare on
/// demand" — adding a new template means a new row in `templates` table;
/// only add a Swift constant when code needs to compare against the id.
public actor TemplateRegistry {
    /// Stable id for the V1 dinner template. Mirrors the row seeded by
    /// migration 00021. Swift code that needs to reference this template
    /// by name (backward-compat defaults in deserializers, onboarding
    /// gates) reads from this constant rather than hardcoding the
    /// literal `"recurring_dinner"`.
    public static let dinnerRecurringId: String = "recurring_dinner"

    private let repository: any TemplateRepository
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "templates")

    private var cache: [String: Template] = [:]
    private var loaded: Bool = false

    public init(repository: any TemplateRepository) {
        self.repository = repository
    }

    /// Loads (or reloads) all templates from the repository into the cache.
    /// Call once at app boot, and again if you've updated a template config
    /// in the database and want it to reflect immediately.
    public func refresh() async {
        do {
            let all = try await repository.templates()
            cache = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
            loaded = true
            log.debug("template registry refreshed — \(all.count) templates loaded")
        } catch {
            log.error("template registry refresh failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Returns the template by id, or nil if not loaded / not present.
    /// Auto-refreshes on first call if not yet loaded.
    public func template(id: String) async -> Template? {
        if !loaded { await refresh() }
        return cache[id]
    }

    /// All loaded templates, sorted available-first then by id.
    public func all() async -> [Template] {
        if !loaded { await refresh() }
        return cache.values.sorted { lhs, rhs in
            if lhs.available != rhs.available { return lhs.available }
            return lhs.id < rhs.id
        }
    }

    /// Available (selectable) templates only — what the founder onboarding
    /// `TemplateSelectorView` shows as enabled cards.
    public func available() async -> [Template] {
        await all().filter(\.available)
    }
}
