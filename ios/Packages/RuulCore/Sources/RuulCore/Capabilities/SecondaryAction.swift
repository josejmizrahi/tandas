import Foundation

/// Item in the nav bar `⋯` menu, decided by
/// `CapabilityResolver.secondaryActions(...)`. Order in the returned
/// array IS the menu order; sections are visual groups (separators
/// drawn between consecutive items with different `section` values).
public struct SecondaryAction: Sendable, Hashable, Identifiable {
    public enum Section: Sendable, Hashable {
        case primary      // edit, share, calendar
        case host         // remind, close, cancel
        case money        // ledger, manual fine
        case governance   // rules, capabilities
        case danger       // archive
    }

    public enum Kind: Sendable, Hashable {
        case editDetails
        case addToCalendar
        case share
        case generateWalletPass
        case remindAttendees
        case closeEvent
        case cancelEvent
        case openLedger
        case issueManualFine
        case openRules
        case enableCapability
        case archive
        // Right resource_type lifecycle. UI surface added in slice 6.
        // The detail view dispatches each to a dedicated sheet that
        // collects the operation's inputs (recipient / date / reason)
        // and calls the matching `RightRepository` method.
        case exerciseRight
        case transferRight
        case delegateRight
        case revokeRight
        case suspendRight
        case restoreRight
    }

    public var id: Kind { kind }

    public let label: String
    public let symbol: String
    public let section: Section
    public let kind: Kind
    public let isDestructive: Bool

    public init(
        label: String,
        symbol: String,
        section: Section,
        kind: Kind,
        isDestructive: Bool = false
    ) {
        self.label = label
        self.symbol = symbol
        self.section = section
        self.kind = kind
        self.isDestructive = isDestructive
    }
}
