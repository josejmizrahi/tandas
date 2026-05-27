import Foundation
import Observation

/// `@MainActor` store for the caller's own profile. Owns the
/// "completion required?" signal that drives the onboarding nudge in
/// the signed-in flow.
///
/// Refresh is explicit + idempotent: `refreshIfNeeded()` is safe to
/// call from a `.task` on every screen; the first call fetches, the
/// rest no-op. `refresh()` always re-fetches.
@MainActor
@Observable
public final class ProfileStore {
    public private(set) var profile: Profile?
    public private(set) var phase: StorePhase = .idle
    public private(set) var errorMessage: String?

    /// Drives a `.sheet(isPresented:)` for EditProfileView so the View
    /// layer can bind directly. Lives on the store so the nudge button
    /// and the "Cuenta" menu both open the same sheet without
    /// duplicating @State.
    public var isEditPresented: Bool = false

    private let repository: CanonicalProfileRepository
    private var hasLoadedOnce: Bool = false

    public init(repository: CanonicalProfileRepository) {
        self.repository = repository
    }

    /// True iff the loaded profile has no usable `display_name`. False
    /// before the first successful load — the nudge waits for the
    /// backend's answer rather than flashing during bootstrap.
    public var requiresProfileCompletion: Bool {
        guard let profile else { return false }
        return !profile.hasUsableDisplayName
    }

    /// Force-fetches the profile. Sets `.loading` (without clearing the
    /// previous value so the UI doesn't flicker) and resolves to
    /// `.loaded` or `.failed`.
    public func refresh() async {
        phase = .loading
        do {
            let fetched = try await repository.myProfile()
            profile = fetched
            phase = .loaded
            errorMessage = nil
            hasLoadedOnce = true
        } catch {
            let message = UserFacingError.from(error).message
            errorMessage = message
            phase = .failed(message: message)
        }
    }

    /// One-shot loader for `.task` blocks on signed-in screens. No-ops
    /// after the first successful load so re-entering the same screen
    /// doesn't refetch.
    public func refreshIfNeeded() async {
        guard !hasLoadedOnce else { return }
        await refresh()
    }

    /// Routes the upsert through the repository. Pre-validates locally
    /// so the UI can short-circuit without a round-trip when the user
    /// hasn't typed a name yet. Returns `true` on success so the View
    /// can dismiss its sheet.
    @discardableResult
    public func updateProfile(
        displayName: String,
        username: String? = nil,
        avatarURL: String? = nil,
        bio: String? = nil
    ) async -> Bool {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            errorMessage = "Escribe tu nombre."
            return false
        }
        do {
            let updated = try await repository.updateMyProfile(
                displayName: trimmed,
                username: username,
                avatarURL: avatarURL,
                bio: bio
            )
            profile = updated
            phase = .loaded
            errorMessage = nil
            isEditPresented = false
            hasLoadedOnce = true
            return true
        } catch {
            errorMessage = UserFacingError.from(error).message
            return false
        }
    }

    public func clearError() {
        errorMessage = nil
    }

    /// Convenience for callers (Members, Money) that just need a
    /// label — never call `profile?.displayName` directly outside this
    /// store, since the resolved fallback lives here.
    public var resolvedDisplayName: String {
        profile?.resolvedDisplayName ?? "Miembro"
    }
}
