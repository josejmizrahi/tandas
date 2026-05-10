import Foundation

/// Snapshot of the platform module catalog. Sendable struct so it can
/// be passed around between actors / SwiftUI views safely.
///
/// Source of truth lives server-side in `public.modules` (mig 00060).
/// `LiveModuleRegistry.load()` pulls the catalog at app boot and the
/// resulting `ModuleRegistry` replaces the `v1Fallback` baseline that
/// boots cold. Tests, previews, and offline-only flows use
/// `ModuleRegistry.v1Fallback` directly.
///
/// Reads are synchronous against an immutable snapshot — no actor
/// hop on the hot path. Cascade closures are computed via BFS over
/// the `dependencies` graph mirroring the recursive CTE in
/// `set_group_module` (mig 00061).
public struct ModuleRegistry: Sendable, Equatable {
    public let modules: [GroupModule]
    public let byId: [String: GroupModule]

    public init(modules: [GroupModule]) {
        self.modules = modules
        self.byId = Dictionary(
            uniqueKeysWithValues: modules.map { ($0.id, $0) }
        )
    }

    /// V1 fallback used pre-`loadModuleRegistry()` and as the default
    /// for tests/previews. Mirrors the seed in mig 00060 verbatim;
    /// `LiveModuleRegistry` replaces it at app boot when the network
    /// call succeeds.
    public static let v1Fallback = ModuleRegistry(modules: [
        .basicFines,
        .rotatingHost,
        .rsvp,
        .checkIn,
        .appealVoting,
    ])

    /// Lookup by id. Returns nil for unknown ids.
    public func module(id: String) -> GroupModule? {
        byId[id]
    }

    /// Resolve a list of ids (typically `Group.activeModules`) to module
    /// manifests, dropping unknown ids silently.
    public func resolve(ids: [String]) -> [GroupModule] {
        ids.compactMap { byId[$0] }
    }

    /// Validates that a set of module ids is internally consistent:
    /// dependencies present, no conflicts. Returns the issues found, or
    /// empty if valid.
    public func validate(ids: [String]) -> [ValidationIssue] {
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
    /// Mirrors the recursive CTE in mig 00061.
    public func transitiveDependencies(of id: String) -> [String] {
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
    public func transitiveDependents(of id: String) -> [String] {
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

    private func directDependents(of id: String) -> [String] {
        modules.compactMap { $0.dependencies.contains(id) ? $0.id : nil }
    }
}
