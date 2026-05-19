import Foundation

/// Normalizes a builder-produced `StateHeadline` so renderers can trust
/// invariants (non-empty headline, no empty supporting facts). The
/// FAMILY-specific rules for which sentence to pick live in each
/// builder — this resolver only enforces the shared contract.
public enum StateHeadlineResolver {
    /// - Parameters:
    ///   - raw: builder's draft headline.
    ///   - fallback: used when the builder's headline is empty.
    public static func normalize(_ raw: StateHeadline, fallback: String) -> StateHeadline {
        let trimmed = raw.headline.trimmingCharacters(in: .whitespacesAndNewlines)
        let headline = trimmed.isEmpty ? fallback : trimmed
        let facts = raw.supportingFacts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return StateHeadline(
            headline: headline,
            supportingFacts: facts,
            primaryAction: raw.primaryAction,
            urgency: raw.urgency
        )
    }
}
