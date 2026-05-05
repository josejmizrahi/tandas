import Foundation
import OSLog

/// In-memory cache of templates loaded from `TemplateRepository`. Boots
/// once at app start (`refresh()`), thereafter serves lookups synchronously
/// from cache. Re-fetch on demand if a template's `version` changes.
///
/// Keeps the hot path (group creation, MainTabView render, onboarding
/// step lookup) free of network round trips.
actor TemplateRegistry {
    private let repository: any TemplateRepository
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "templates")

    private var cache: [String: Template] = [:]
    private var loaded: Bool = false

    init(repository: any TemplateRepository) {
        self.repository = repository
    }

    /// Loads (or reloads) all templates from the repository into the cache.
    /// Call once at app boot, and again if you've updated a template config
    /// in the database and want it to reflect immediately.
    func refresh() async {
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
    func template(id: String) async -> Template? {
        if !loaded { await refresh() }
        return cache[id]
    }

    /// All loaded templates, sorted available-first then by id.
    func all() async -> [Template] {
        if !loaded { await refresh() }
        return cache.values.sorted { lhs, rhs in
            if lhs.available != rhs.available { return lhs.available }
            return lhs.id < rhs.id
        }
    }

    /// Available (selectable) templates only — what the founder onboarding
    /// `TemplateSelectorView` shows as enabled cards.
    func available() async -> [Template] {
        await all().filter(\.available)
    }
}
