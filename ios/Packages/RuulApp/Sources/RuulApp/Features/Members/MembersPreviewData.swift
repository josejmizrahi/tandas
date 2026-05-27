import Foundation
import RuulCore

/// Preview fixtures for the members surface. Covers the boundary
/// edge cases (current user, active, long names, provisional,
/// invited, suspended, many roles, no avatar, pending invite by
/// email and by phone). Lives in the RuulApp target so the data can
/// stay non-public to RuulCore while still being reachable from
/// every Members view's `#Preview`.
public enum MembersPreviewData {

    public static let currentUser = MembershipBoundaryItem(
        id: UUID(),
        kind: .membership,
        membershipId: UUID(),
        userId: UUID(),
        displayName: "Jose Mizrahi",
        status: .active,
        membershipType: .member,
        roleNames: ["Fundador"],
        joinedAt: Date(timeIntervalSinceNow: -86_400 * 30),
        isCurrentUser: true
    )

    public static let activeMember = MembershipBoundaryItem(
        id: UUID(),
        kind: .membership,
        membershipId: UUID(),
        userId: UUID(),
        displayName: "Ana López",
        status: .active,
        membershipType: .member,
        roleNames: ["Tesorero"],
        joinedAt: Date(timeIntervalSinceNow: -86_400 * 15)
    )

    public static let longName = MembershipBoundaryItem(
        id: UUID(),
        kind: .membership,
        membershipId: UUID(),
        userId: UUID(),
        displayName: "Christopher Alexander de la Vega y Castillo del Mar",
        status: .active,
        membershipType: .member,
        roleNames: ["Coordinador de eventos", "Aprobador de gastos"],
        joinedAt: Date()
    )

    public static let provisional = MembershipBoundaryItem(
        id: UUID(),
        kind: .membership,
        membershipId: UUID(),
        userId: nil,
        displayName: "Mateo García",
        status: .active,
        membershipType: .provisional
    )

    public static let invitePendingEmail = MembershipBoundaryItem(
        id: UUID(),
        kind: .invite,
        inviteId: UUID(),
        displayName: "carlos@email.com",
        status: .invited,
        membershipType: .member,
        invitedAt: Date(timeIntervalSinceNow: -3_600)
    )

    public static let invitePendingPhone = MembershipBoundaryItem(
        id: UUID(),
        kind: .invite,
        inviteId: UUID(),
        displayName: "+52 55 1234 5678",
        status: .invited,
        membershipType: .provisional,
        invitedAt: Date(timeIntervalSinceNow: -60_000)
    )

    public static let suspended = MembershipBoundaryItem(
        id: UUID(),
        kind: .membership,
        membershipId: UUID(),
        userId: UUID(),
        displayName: "Diego Rojas",
        status: .suspended,
        membershipType: .member,
        roleNames: ["Aprobador de gastos"]
    )

    public static let manyRoles = MembershipBoundaryItem(
        id: UUID(),
        kind: .membership,
        membershipId: UUID(),
        userId: UUID(),
        displayName: "Sofia Hernández",
        status: .active,
        membershipType: .member,
        roleNames: ["Tesorero", "Coordinador", "Aprobador", "Moderador"]
    )

    public static let noAvatar = MembershipBoundaryItem(
        id: UUID(),
        kind: .membership,
        membershipId: UUID(),
        userId: UUID(),
        displayName: "Luis"
    )

    /// Full boundary set used by `MembersListView`'s populated preview.
    public static let boundaryAll: [MembershipBoundaryItem] = [
        currentUser, activeMember, longName, provisional,
        invitePendingEmail, invitePendingPhone, suspended, manyRoles, noAvatar
    ]
}
