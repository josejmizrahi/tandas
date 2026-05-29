import Foundation

/// V3-INV result of `invite_member`. Carries the shareable `code` so
/// the UI can show it / copy it / hand it to a ShareLink right after
/// the invitation is created. `placeholderMembershipId` is the
/// `group_memberships` row spawned by V3-R0 so the invitee can be a
/// payer/participant before they accept.
public struct InviteCreated: Sendable, Hashable {
    public let inviteId: UUID
    public let code: String
    public let placeholderMembershipId: UUID?

    public init(inviteId: UUID, code: String, placeholderMembershipId: UUID?) {
        self.inviteId = inviteId
        self.code = code
        self.placeholderMembershipId = placeholderMembershipId
    }
}
