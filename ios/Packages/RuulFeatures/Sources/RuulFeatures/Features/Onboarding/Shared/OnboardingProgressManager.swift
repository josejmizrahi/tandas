import Foundation
import SwiftData
import RuulCore
import RuulUI

/// Persistence seam for onboarding progress. Production wires the
/// SwiftData-backed `OnboardingProgressManager`; tests wire the in-memory
/// `InMemoryOnboardingProgressStore` to avoid a SwiftData `ModelContainer`
/// cold-start that hangs the test process on Xcode 26.3 simulators in CI
/// (the actual host iOS runner — local Xcode 26.4 boots fine).
@MainActor
public protocol OnboardingProgressPersisting: AnyObject {
    func loadActive() throws -> OnboardingProgress?
    func save(_ progress: OnboardingProgress) throws
    func clear() throws
}

/// Wrapper around `ModelContext` for onboarding progress persistence.
///
/// MainActor: SwiftData ModelContext is bound to the main actor in iOS 26
/// (per documentation, ModelContext is not Sendable across actors). Callers
/// from background contexts must hop through `Task { @MainActor in ... }`.
@MainActor
public final class OnboardingProgressManager: OnboardingProgressPersisting {
    private let context: ModelContext

    public init(context: ModelContext) {
        self.context = context
    }

    /// Returns the most recent unfinished progress, or nil.
    public func loadActive() throws -> OnboardingProgress? {
        let descriptor = FetchDescriptor<OnboardingProgress>(
            sortBy: [SortDescriptor(\.lastUpdatedAt, order: .reverse)]
        )
        let all = try context.fetch(descriptor)
        return all.first
    }

    /// Insert or update the given progress.
    public func save(_ progress: OnboardingProgress) throws {
        progress.lastUpdatedAt = .now
        if progress.modelContext == nil {
            context.insert(progress)
        }
        try context.save()
    }

    /// Removes ALL OnboardingProgress rows. Called on flow completion.
    public func clear() throws {
        let all = try context.fetch(FetchDescriptor<OnboardingProgress>())
        for p in all {
            context.delete(p)
        }
        try context.save()
    }
}

/// In-memory replacement for `OnboardingProgressManager` used in unit
/// tests. Avoids the SwiftData `ModelContainer` initialization that
/// reliably hangs the test process on the macos-15 CI runner (Xcode 26.3
/// simulator). Keeps the same protocol surface so coordinators don't need
/// to special-case the test wiring.
///
/// Holds a single in-memory progress row. `save` retains the latest
/// reference; `loadActive` returns it; `clear` drops it.
@MainActor
public final class InMemoryOnboardingProgressStore: OnboardingProgressPersisting {
    private var stored: OnboardingProgress?

    public init() {}

    public func loadActive() throws -> OnboardingProgress? { stored }

    public func save(_ progress: OnboardingProgress) throws {
        progress.lastUpdatedAt = .now
        stored = progress
    }

    public func clear() throws { stored = nil }
}
