import Foundation

/// Logical grouping for the members list. `MembersStore.sections`
/// projects its `members` array into one section per non-empty kind,
/// in a fixed order so the UI is stable across refreshes.
public struct MemberSection: Identifiable, Sendable, Equatable {
    public var id: MemberSectionKind { kind }
    public let kind: MemberSectionKind
    public let members: [MemberListItem]

    public init(kind: MemberSectionKind, members: [MemberListItem]) {
        self.kind = kind
        self.members = members
    }
}

public enum MemberSectionKind: Sendable, Hashable {
    case currentUser
    case active
    case provisional
    case invited
    case suspended

    public var title: LocalizedStringResource {
        switch self {
        case .currentUser: return L10n.Members.sectionYou
        case .active:      return L10n.Members.sectionActive
        case .provisional: return L10n.Members.sectionProvisional
        case .invited:     return L10n.Members.sectionInvited
        case .suspended:   return L10n.Members.sectionSuspended
        }
    }

    /// Fixed render order. Empty sections are skipped by the store.
    public static let renderOrder: [MemberSectionKind] = [
        .currentUser, .active, .provisional, .invited, .suspended
    ]
}
