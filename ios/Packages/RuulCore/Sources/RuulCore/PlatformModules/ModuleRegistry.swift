import Foundation

/// Static registry of platform modules. V1 ships 5 hardcoded modules that
/// the `recurring_dinner` template activates by default. Fase 2+ adds
/// module manifests by extending the `v1Modules` array (minimalist by
/// decision D in Plans/Phase1.md — no DB-driven plugin system in V1).
///
/// Reads on the hot path: `module(id:)` from `Group.activeModules` lookups.
/// Modules are pure data (`GroupModule`) so the registry needs no actor —
/// safe to read concurrently from any context.
public enum ModuleRegistry {
    /// All modules known to V1. Order is meaningful for default tab
    /// composition: modules earlier in the list win on tab id collisions.
    public static let v1Modules: [GroupModule] = [
        .basicFines,
        .rotatingHost,
        .rsvp,
        .checkIn,
        .appealVoting,
    ]

    public static let byId: [String: GroupModule] = Dictionary(
        uniqueKeysWithValues: v1Modules.map { ($0.id, $0) }
    )

    /// Lookup by id. Returns nil for module ids not registered (e.g. Fase 2
    /// modules not yet shipped).
    public static func module(id: String) -> GroupModule? {
        byId[id]
    }

    /// Resolve a list of ids (typically `Group.activeModules`) to module
    /// manifests, dropping unknown ids silently.
    public static func resolve(ids: [String]) -> [GroupModule] {
        ids.compactMap { byId[$0] }
    }

    /// Validates that a set of module ids is internally consistent:
    /// dependencies present, no conflicts. Returns the issues found, or
    /// empty if valid.
    public static func validate(ids: [String]) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        let present = Set(ids)

        for id in ids {
            guard let mod = byId[id] else {
                issues.append(.unknown(id: id))
                continue
            }
            for dep in mod.dependencies where !present.contains(dep) {
                issues.append(.missingDependency(module: id, requires: dep))
            }
            for conflict in mod.conflictsWith where present.contains(conflict) {
                issues.append(.conflict(module: id, conflictsWith: conflict))
            }
        }
        return issues
    }

    public enum ValidationIssue: Sendable, Equatable, Hashable {
        case unknown(id: String)
        case missingDependency(module: String, requires: String)
        case conflict(module: String, conflictsWith: String)
    }

    // MARK: - Transitive dep / dependent closures

    /// Every module the given slug requires, transitively. Returns an
    /// ordered, deduplicated set; iteration order is BFS from `id`'s
    /// direct deps. Unknown ids return an empty set (matches the SQL
    /// `set_group_module` cascade behaviour for forward-compat slugs).
    /// Mirrors the closure table hardcoded in `mig 00057`.
    public static func transitiveDependencies(of id: String) -> [String] {
        var out: [String] = []
        var seen = Set<String>([id])
        var queue: [String] = byId[id]?.dependencies ?? []
        while !queue.isEmpty {
            let next = queue.removeFirst()
            if seen.contains(next) { continue }
            seen.insert(next)
            out.append(next)
            if let m = byId[next] {
                queue.append(contentsOf: m.dependencies)
            }
        }
        return out
    }

    /// Every module that requires the given slug, transitively. Used by
    /// the `set_group_module` disable-cascade so dependent modules are
    /// removed when their requirement disappears.
    public static func transitiveDependents(of id: String) -> [String] {
        var out: [String] = []
        var seen = Set<String>([id])
        var queue: [String] = directDependents(of: id)
        while !queue.isEmpty {
            let next = queue.removeFirst()
            if seen.contains(next) { continue }
            seen.insert(next)
            out.append(next)
            queue.append(contentsOf: directDependents(of: next))
        }
        return out
    }

    private static func directDependents(of id: String) -> [String] {
        v1Modules.compactMap { $0.dependencies.contains(id) ? $0.id : nil }
    }
}
