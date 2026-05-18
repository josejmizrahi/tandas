import Foundation
import OSLog

/// Brings a set of capability ids online on a resource without showing
/// the user any toggle. Used by `PostCreateIntentDispatcher` when the
/// user taps an intent whose `requiredCapabilities` aren't yet attached,
/// and by `ResourceCreationCoordinator` to attach variant-declared
/// silent caps at create time.
///
/// Three layered gates apply to every requested id, in order. A miss at
/// any gate becomes a skip — never an error surface — because intents
/// that need missing caps are supposed to be hidden by the post-create
/// screen already; the activator's job is to be honest about what
/// actually landed:
///   1. Catalog: the id must resolve to a `CapabilityBlock`.
///   2. Stable: `block.status.isStable` must be true. Half-built blocks
///      can't deliver behavior even if the row is written.
///   3. Available: the group's active modules must provide it
///      (`CapabilityResolver.availableCapabilities`).
///
/// Idempotent: ids already attached + enabled on the resource pass
/// through as `alreadyAttached`. Failed writes surface as `failed` with
/// the underlying error preserved per id.
public actor LazyCapabilityActivator {
    private let catalog: CapabilityCatalog
    private let resolver: CapabilityResolver
    private let capabilityRepo: any ResourceCapabilityRepository
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "resource.activator")

    public init(
        catalog: CapabilityCatalog = .v1,
        resolver: CapabilityResolver = CapabilityResolver(),
        capabilityRepo: any ResourceCapabilityRepository
    ) {
        self.catalog = catalog
        self.resolver = resolver
        self.capabilityRepo = capabilityRepo
    }

    /// Ensure each id in `ids` is attached + enabled on `resourceId`.
    /// Per-id outcome buckets:
    ///   - `attached`        : the activator wrote a new row this call.
    ///   - `alreadyAttached` : the id was already enabled — no-op.
    ///   - `skippedUnknown`  : the id isn't in the catalog.
    ///   - `skippedIncomplete`: the block exists but `.status` isn't stable.
    ///   - `skippedUnavailable`: the group's active modules don't provide
    ///                          the id for `resourceType`.
    ///   - `failed`          : the repo write threw.
    ///
    /// Caller can inspect `outcome.attached` to know which intents
    /// just became real, and `outcome.skipped*` to flag UI that
    /// expected behavior the runtime can't deliver yet.
    public func ensure(
        _ ids: Set<String>,
        on resourceId: UUID,
        resourceType: ResourceType,
        in group: Group
    ) async -> ActivationOutcome {
        var outcome = ActivationOutcome()
        guard !ids.isEmpty else { return outcome }

        // Snapshot what's already attached so we don't double-write.
        let existing: Set<String>
        do {
            let rows = try await capabilityRepo.list(resourceId: resourceId)
            existing = Set(rows.filter(\.enabled).map(\.capabilityBlockId))
        } catch {
            log.error("activator: failed to list existing caps: \(error.localizedDescription)")
            // If we can't read the snapshot, treat all as "potentially missing"
            // and let the repo handle dedup via its upsert path.
            existing = []
        }

        let available = Set(resolver.availableCapabilities(
            for: resourceType, in: group, catalog: catalog
        ))

        for id in ids.sorted() {
            // Gate 1: catalog membership.
            guard let block = catalog[id] else {
                outcome.skippedUnknown.insert(id)
                continue
            }
            // Gate 2: stable status. Half-built blocks would write a row
            // but no runtime delivers behavior — silently lying to the
            // user. Skip and let the intent stay hidden.
            guard block.status.isStable else {
                outcome.skippedIncomplete.insert(id)
                continue
            }
            // Gate 3: group has an active module that provides this id
            // for this resource type. (resolver folds the catalog's
            // enabledResourceTypes into its lookup, so the type check
            // is implicit.)
            guard available.contains(id) else {
                outcome.skippedUnavailable.insert(id)
                continue
            }
            // Idempotency: already enabled → no-op.
            if existing.contains(id) {
                outcome.alreadyAttached.insert(id)
                continue
            }
            // Write. Empty config — intents that need config route through
            // their destination form, not through silent attach.
            do {
                _ = try await capabilityRepo.enable(id, on: resourceId, config: .object([:]))
                outcome.attached.insert(id)
            } catch {
                log.error("activator: failed to attach \(id): \(error.localizedDescription)")
                outcome.failed[id] = error.localizedDescription
            }
        }

        return outcome
    }
}

/// Per-id buckets for `LazyCapabilityActivator.ensure`. The dispatcher
/// uses this to decide what to surface to the user and what to log.
/// `failed` carries the localized message string rather than the raw
/// `Error` so the struct stays `Sendable` / `Hashable`-friendly.
public struct ActivationOutcome: Sendable, Hashable {
    public var attached: Set<String> = []
    public var alreadyAttached: Set<String> = []
    public var skippedUnknown: Set<String> = []
    public var skippedIncomplete: Set<String> = []
    public var skippedUnavailable: Set<String> = []
    public var failed: [String: String] = [:]

    public init() {}

    /// Convenience: ids that did NOT come online this call (skipped or
    /// failed). The caller can flag these so an intent's destination
    /// can surface a "esto todavía no está disponible" empty state
    /// instead of opening a broken form.
    public var didNotActivate: Set<String> {
        skippedUnknown
            .union(skippedIncomplete)
            .union(skippedUnavailable)
            .union(failed.keys)
    }

    public var allEffective: Set<String> {
        attached.union(alreadyAttached)
    }
}
