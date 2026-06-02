import Foundation
import Observation

/// R.1A — `@MainActor @Observable` store backing the context-first
/// surface. Hydrates `availableContexts` exclusively from
/// `my_world_summary()` (founder lock: no direct reads from `actors`)
/// and tracks the user-selected `currentContext` across app launches
/// via two `UserDefaults` keys.
///
/// Mapping (silently omits anything without an actor_id or with no
/// usable display name — "no inventar contextos"):
/// - `summary.actor` → one Person context
/// - `summary.groups[]` → Group contexts
/// - `summary.controlledEntities[]` → LegalEntity contexts when
///   `actorKind` is neither `"person"` nor `"group"`
///
/// Scope lock R.1A: this store has no UI side effects. Switching a
/// context only mutates `currentContext` + persists it. The shell does
/// not root-swap until R.1C.
@MainActor
@Observable
public final class CurrentContextStore {
    public private(set) var currentContext: AppContext?
    public private(set) var availableContexts: [AppContext] = []
    public private(set) var phase: StorePhase = .idle
    public private(set) var errorMessage: String?

    private let repository: CanonicalMyWorldRepository?
    private let defaults: UserDefaults

    /// UserDefaults keys for cross-launch persistence of the selected
    /// context. Kept as two scalars (id + kind) so we never have to
    /// decode a stale `AppContext` snapshot — we resolve against the
    /// freshly-loaded `availableContexts` instead.
    public static let persistedIdKey = "current_context_id"
    public static let persistedKindKey = "current_context_kind"

    public init(
        repository: CanonicalMyWorldRepository,
        defaults: UserDefaults = .standard
    ) {
        self.repository = repository
        self.defaults = defaults
    }

    /// Preview / unit-test init. Bypasses the repository so SwiftUI
    /// previews + Swift Testing suites can seed deterministic state.
    public init(
        previewContexts: [AppContext],
        current: AppContext? = nil,
        phase: StorePhase = .loaded,
        defaults: UserDefaults = .standard
    ) {
        self.repository = nil
        self.availableContexts = previewContexts
        self.currentContext = current
        self.phase = phase
        self.defaults = defaults
    }

    // MARK: - Loading

    /// Hydrate `availableContexts` from `my_world_summary()`. On
    /// success, restores the persisted context if it still exists in
    /// the fresh list, otherwise falls back to the person context.
    /// No-op when constructed via the preview init.
    public func load() async {
        guard let repository else { return }
        if availableContexts.isEmpty { phase = .loading }
        errorMessage = nil
        do {
            let summary = try await repository.loadSummary()
            availableContexts = Self.buildContexts(from: summary)
            resolveCurrentAfterReload()
            phase = .loaded
        } catch {
            errorMessage = UserFacingError.from(error).message
            phase = .failed(message: errorMessage ?? "")
        }
    }

    // MARK: - Switching

    /// Switch the active context and persist immediately. Silently
    /// ignores contexts not present in `availableContexts` to prevent
    /// the switcher from selecting stale entries.
    public func switchTo(_ context: AppContext) {
        guard availableContexts.contains(context) else { return }
        currentContext = context
        persistCurrentContext()
    }

    /// Read the persisted id + kind and set `currentContext` to the
    /// matching entry in `availableContexts`. Falls back to the person
    /// context if the persisted entry no longer exists.
    public func restorePersistedContext() {
        guard
            let idString = defaults.string(forKey: Self.persistedIdKey),
            let id = UUID(uuidString: idString),
            let kindString = defaults.string(forKey: Self.persistedKindKey),
            let kind = ContextKind(rawValue: kindString)
        else {
            fallbackToPersonContext()
            return
        }
        if let match = availableContexts.first(where: { $0.id == id && $0.kind == kind }) {
            currentContext = match
        } else {
            fallbackToPersonContext()
        }
    }

    /// Write the current selection to UserDefaults. Clears both keys
    /// when `currentContext` is `nil`.
    public func persistCurrentContext() {
        if let ctx = currentContext {
            defaults.set(ctx.id.uuidString, forKey: Self.persistedIdKey)
            defaults.set(ctx.kind.rawValue, forKey: Self.persistedKindKey)
        } else {
            defaults.removeObject(forKey: Self.persistedIdKey)
            defaults.removeObject(forKey: Self.persistedKindKey)
        }
    }

    /// Set the current context to the first person entry. Per R.0A
    /// every signed-in user always has exactly one person actor, so
    /// this is the canonical safe fallback when persistence misses.
    public func fallbackToPersonContext() {
        currentContext = availableContexts.first { $0.kind == .person }
    }

    /// Clear all state (use on sign-out so the next session doesn't
    /// see the previous user's switcher).
    public func reset() {
        currentContext = nil
        availableContexts = []
        phase = .idle
        errorMessage = nil
        defaults.removeObject(forKey: Self.persistedIdKey)
        defaults.removeObject(forKey: Self.persistedKindKey)
    }

    // MARK: - Internals

    private func resolveCurrentAfterReload() {
        if let current = currentContext,
           availableContexts.contains(where: { $0.id == current.id && $0.kind == current.kind }) {
            // Already-selected context is still valid — keep it but
            // refresh the in-memory copy so display name updates land.
            if let refreshed = availableContexts.first(where: { $0.id == current.id && $0.kind == current.kind }) {
                currentContext = refreshed
            }
            return
        }
        restorePersistedContext()
    }

    /// Pure builder so tests + previews can verify the mapping without
    /// touching UserDefaults or the network.
    public static func buildContexts(from summary: MyWorldSummary) -> [AppContext] {
        var out: [AppContext] = []

        // Person — always exactly one.
        out.append(
            AppContext(
                id: summary.actor.id,
                kind: .person,
                displayName: summary.actor.displayName,
                subtitle: "Mi mundo",
                avatarSymbol: "person.crop.circle.fill",
                metadata: summary.actor.metadata
            )
        )

        // Groups — preserve repository order so the switcher feels
        // stable across reloads.
        for group in summary.groups {
            out.append(
                AppContext(
                    id: group.groupId,
                    kind: .group,
                    displayName: group.name,
                    subtitle: group.membershipType?.capitalized,
                    avatarSymbol: "person.3.fill",
                    metadata: nil
                )
            )
        }

        // Legal entities — only when actor_kind isn't person/group and
        // we have a non-empty display name (silent omission otherwise).
        for entity in summary.controlledEntities {
            let kind = entity.actorKind?.lowercased() ?? ""
            guard kind != "person", kind != "group" else { continue }
            guard let name = entity.displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { continue }
            out.append(
                AppContext(
                    id: entity.actorId,
                    kind: .legalEntity,
                    displayName: name,
                    subtitle: entity.relationshipType.capitalized,
                    avatarSymbol: "building.2.fill",
                    metadata: entity.metadata
                )
            )
        }

        return out
    }
}
