import Foundation

/// Horizontal-pill fact in `ResourceQuickFactsView`. Polymorphic
/// across resource types via `CapabilityResolver.quickFacts(...)`.
public struct QuickFact: Identifiable, Hashable, Sendable {
    public enum Kind: Sendable, Hashable {
        case date           // event when, fund last activity
        case time           // event time of day
        case location       // event/asset location
        case capacity       // event "8/12"
        case balance        // fund balance
        case progress       // fund "$x of $y"
        case status         // asset/right availability
        case host           // event host name
        case custodian      // asset custodian
    }

    public let id: String
    public let kind: Kind
    public let symbol: String   // SF Symbol
    public let label: String    // display string (already localized/formatted)

    public init(id: String, kind: Kind, symbol: String, label: String) {
        self.id = id
        self.kind = kind
        self.symbol = symbol
        self.label = label
    }
}
