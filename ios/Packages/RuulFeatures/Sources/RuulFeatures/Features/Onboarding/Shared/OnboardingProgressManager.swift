import Foundation
import SwiftData
import RuulCore
import RuulUI

/// Wrapper around `ModelContext` for onboarding progress persistence.
///
/// MainActor: SwiftData ModelContext is bound to the main actor in iOS 26
/// (per documentation, ModelContext is not Sendable across actors). Callers
/// from background contexts must hop through `Task { @MainActor in ... }`.
@MainActor
public final class OnboardingProgressManager {
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
