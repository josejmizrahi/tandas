import Foundation
import Observation

/// R.0H.1 — `@MainActor @Observable` store backing the (still-to-build)
/// `PersonalHomeView`. Hydrates from `my_world_summary()` via
/// `CanonicalMyWorldRepository`.
///
/// R.0H.1 scope: plumbing only. No UI. No navigation. R.0H.2 will add
/// `PersonalHomeView` consuming this store; R.0H.3 introduces the
/// feature-flagged root pivot — `GroupListView` remains the default
/// throughout R.0H (founder lock).
@MainActor
@Observable
public final class MyWorldStore {
    public private(set) var summary: MyWorldSummary?
    public private(set) var phase: StorePhase = .idle
    public private(set) var errorMessage: String?

    private let repository: CanonicalMyWorldRepository

    public init(repository: CanonicalMyWorldRepository) {
        self.repository = repository
    }

    /// Hydrate (or refresh) the summary. Errors are mapped via
    /// `UserFacingError.from` so views can render `errorMessage`
    /// directly without re-mapping.
    public func load() async {
        phase = .loading
        errorMessage = nil
        do {
            self.summary = try await repository.loadSummary()
            phase = .loaded
        } catch {
            errorMessage = UserFacingError.from(error).message
            phase = .failed(message: errorMessage ?? "")
        }
    }

    /// Discard any cached state. Useful when the user logs out / switches
    /// accounts (R.0H.3+ will wire this to `AuthService` state changes).
    public func reset() {
        summary = nil
        phase = .idle
        errorMessage = nil
    }
}
