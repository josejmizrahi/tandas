import Foundation

/// Logical grouping for the boundary list. `MembersStore.sections`
/// projects its `items` array into one section per non-empty kind,
/// in a fixed order so the UI is stable across refreshes.
public struct MemberSection: Identifiable, Sendable, Equatable {
    public var id: MemberSectionKind { kind }
    public let kind: MemberSectionKind
    public let members: [MembershipBoundaryItem]

    public init(kind: MemberSectionKind, members: [MembershipBoundaryItem]) {
        self.kind = kind
        self.members = members
    }
}

public enum MemberSectionKind: Sendable, Hashable {
    case currentUser
    case requested
    case active
    case provisional
    case invited
    case suspended

    public var title: LocalizedStringResource {
        switch self {
        case .currentUser: return L10n.Members.sectionYou
        case .requested:   return L10n.Members.sectionRequested
        case .active:      return L10n.Members.sectionActive
        case .provisional: return L10n.Members.sectionProvisional
        case .invited:     return L10n.Members.sectionInvited
        case .suspended:   return L10n.Members.sectionSuspended
        }
    }

    /// Fixed render order. Empty sections are skipped by the store.
    /// D.24: `.requested` placed right after `currentUser` so admin
    /// attention lands on the pending-approvals cluster immediately.
    public static let renderOrder: [MemberSectionKind] = [
        .currentUser, .requested, .active, .provisional, .invited, .suspended
    ]
}
