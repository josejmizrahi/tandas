import Foundation

/// Single primary CTA for a resource detail screen, decided by
/// `CapabilityResolver.primaryAction(...)`. Drives the sticky footer
/// in `UniversalResourceDetailView`.
public struct PrimaryAction: Sendable, Hashable {
    public enum Style: Sendable, Hashable {
        case standard       // accent fill
        case prominent      // larger, more visual weight
        case destructive    // red tint
    }

    /// Logical kind of action — view dispatches based on this to existing
    /// presenter callbacks. Adding a new resource type means adding a
    /// case here + a branch in the resolver + a dispatch in the view.
    public enum Kind: Sendable, Hashable {
        case rsvpConfirm        // event + viewer hasn't RSVP'd
        case rsvpCancel         // event + viewer has RSVP'd "going"
        case viewHostActions    // event + viewer is host (opens action sheet)
        case openContribute     // fund (placeholder — Phase 2 wires)
        case openBooking        // asset (placeholder — Phase 2 wires)
        case viewClosed         // event closed (or readonly)
        case none               // no CTA — caller hides the footer
    }

    public let label: String
    public let symbol: String?
    public let style: Style
    public let kind: Kind

    public init(label: String, symbol: String?, style: Style, kind: Kind) {
        self.label = label
        self.symbol = symbol
        self.style = style
        self.kind = kind
    }

    /// Sentinel for the "no CTA" case. Caller can `if action.kind == .none`
    /// or use this constant directly.
    public static let none = PrimaryAction(
        label: "",
        symbol: nil,
        style: .standard,
        kind: .none
    )
}
