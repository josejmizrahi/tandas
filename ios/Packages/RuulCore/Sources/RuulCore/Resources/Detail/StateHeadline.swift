import Foundation

/// State layer payload — the single hero block per screen.
/// Answers "what does this resource mean RIGHT NOW for THIS viewer".
/// Built by `StateHeadlineResolver`; rendered by `StateHeroView`.
public struct StateHeadline: Sendable, Hashable {
    /// One-sentence headline. Founder voice. No jargon.
    public let headline: String
    /// 2-3 supporting facts. Rendered as a single dotted line under
    /// the headline ("20:00 · Casa de Ana · Anfitriona Ana").
    public let supportingFacts: [String]
    /// Inline primary action. nil → block renders the fact alone, no
    /// button. Exactly ONE action per screen, ever.
    public let primaryAction: PrimaryAction?
    /// Urgency band — drives both visual prominence (subtle red tint)
    /// and the priority resolver (urgent state pulls dependent blocks
    /// higher in the stack).
    public let urgency: Urgency

    public enum Urgency: String, Sendable, Hashable {
        case ambient    // informational — "Saldo $4,300"
        case actionable // viewer can act — "Confirm if you're coming"
        case urgent     // time-pressured — "$200 due in 2 days"
        case terminal   // closed / archived — "Closed Mar 4"
    }

    public init(headline: String, supportingFacts: [String], primaryAction: PrimaryAction?, urgency: Urgency) {
        self.headline = headline
        self.supportingFacts = supportingFacts
        self.primaryAction = primaryAction
        self.urgency = urgency
    }
}
