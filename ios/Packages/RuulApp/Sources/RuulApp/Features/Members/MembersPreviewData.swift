import Foundation
import RuulCore

/// Preview fixtures for the members surface. Covers the edge cases the
/// spec calls out (current user, active, long names, provisional,
/// invited, suspended, many roles, no avatar). Lives in the RuulApp
/// target so the data can stay non-public to RuulCore while still being
/// reachable from every Members view's `#Preview`.
public enum MembersPreviewData {

    public static let currentUser = MemberListItem(
        id: UUID(),
        userId: UUID(),
        displayName: "Jose Mizrahi",
        avatarURL: nil,
        status: .active,
        membershipType: .member,
        roleNames: ["Fundador"],
        joinedAt: Date(timeIntervalSinceNow: -86_400 * 30),
        isCurrentUser: true
    )

    public static let activeMember = MemberListItem(
        id: UUID(),
        userId: UUID(),
        displayName: "Ana López",
        status: .active,
        roleNames: ["Tesorero"],
        joinedAt: Date(timeIntervalSinceNow: -86_400 * 15)
    )

    public static let longName = MemberListItem(
        id: UUID(),
        userId: UUID(),
        displayName: "Christopher Alexander de la Vega y Castillo del Mar",
        status: .active,
        roleNames: ["Coordinador de eventos", "Aprobador de gastos"],
        joinedAt: Date()
    )

    public static let provisional = MemberListItem(
        id: UUID(),
        userId: nil,
        displayName: "Mateo García",
        status: .active,
        membershipType: .provisional
    )

    public static let invited = MemberListItem(
        id: UUID(),
        userId: nil,
        displayName: "carlos@email.com",
        status: .invited
    )

    public static let suspended = MemberListItem(
        id: UUID(),
        userId: UUID(),
        displayName: "Diego Rojas",
        status: .suspended,
        roleNames: ["Aprobador de gastos"]
    )

    public static let manyRoles = MemberListItem(
        id: UUID(),
        userId: UUID(),
        displayName: "Sofia Hernández",
        status: .active,
        roleNames: ["Tesorero", "Coordinador", "Aprobador", "Moderador"]
    )

    public static let noAvatar = MemberListItem(
        id: UUID(),
        userId: UUID(),
        displayName: "Luis"
    )

    public static let all: [MemberListItem] = [
        currentUser, activeMember, longName, provisional,
        invited, suspended, manyRoles, noAvatar
    ]
}

// MARK: - Redaction placeholder

public extension MemberListItem {
    /// Stable shape used by `MembersListView` while skeleton rows are
    /// rendered with `.redacted(reason: .placeholder)`. The literal
    /// content is irrelevant — SwiftUI replaces glyphs with grey blocks.
    static var placeholder: MemberListItem {
        MemberListItem(
            id: UUID(),
            displayName: "Placeholder Name",
            roleNames: ["Placeholder role"]
        )
    }
}
