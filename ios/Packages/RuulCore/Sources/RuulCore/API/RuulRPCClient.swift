import Foundation

/// Single typed surface for every canonical RPC iOS is allowed to call in
/// Foundation scope (CanonicalRPCs_Contract.md §16-bis). Anything that
/// mutates server state goes through here; features and view models must
/// never touch `SupabaseClient` directly.
///
/// All methods throw `RuulError` (mapped by `RPCErrorMapper`). Implementors
/// are responsible for translating the underlying `PostgrestError`.
public protocol RuulRPCClient: Sendable {
    // MARK: - Identity & membership

    func createGroup(name: String,
                     slug: String?,
                     category: String?,
                     purposeDeclared: String?) async throws -> UUID

    func inviteMember(groupId: UUID,
                      email: String?,
                      phone: String?,
                      membershipType: String,
                      message: String?) async throws -> UUID

    func acceptInvite(code: String) async throws -> AcceptInviteResult

    func leaveGroup(groupId: UUID, reason: String?) async throws

    // MARK: - Money (self-party only in Foundation)

    func recordExpense(_ draft: ExpenseDraft, clientId: String?) async throws -> UUID

    func recordSettlement(_ draft: SettlementDraft, clientId: String?) async throws -> SettlementResult

    // MARK: - Reads

    func listMyGroups() async throws -> [GroupListItem]

    func groupSummary(groupId: UUID) async throws -> CanonicalGroupSummary

    func memberBalance(groupId: UUID, membershipId: UUID) async throws -> Decimal

    func memberObligationSummary(groupId: UUID, membershipId: UUID) async throws -> [ObligationSummary]

    func listMemberPermissions(groupId: UUID, userId: UUID?) async throws -> [String]

    /// `group_members(p_group_id) returns table(...)`. Pre-joined rows
    /// (membership × profile × roles) for the Members surface. RPC
    /// validates the caller is an active member of the group.
    func groupMembers(groupId: UUID) async throws -> [MemberListItem]

    /// `group_membership_boundary(p_group_id) returns table(...)` —
    /// Primitiva 2 unified view that UNIONs memberships with pending
    /// invites. Same auth rules as `groupMembers`.
    func groupMembershipBoundary(groupId: UUID) async throws -> [MembershipBoundaryItem]

    // MARK: - Purpose

    /// `group_purposes_active(p_group_id)` — returns the group's
    /// active purposes (declared/operative/emotional). Any active
    /// member can read.
    func groupPurposesActive(groupId: UUID) async throws -> [GroupPurpose]

    /// `set_group_purpose(p_group_id, p_kind, p_body, p_visibility)` —
    /// upsert by kind. Requires `purpose.set` permission.
    func setGroupPurpose(_ input: SetGroupPurposeInput) async throws -> GroupPurpose

    // MARK: - Profile

    /// `my_profile() returns public.profiles`. Backend creates a blank
    /// row on first call so this never returns nil for an authenticated
    /// caller.
    func myProfile() async throws -> Profile

    /// `update_my_profile(p_display_name, p_username, p_avatar_url, p_bio)
    /// returns public.profiles`. Caller pre-trims; backend lowercases
    /// username and enforces uniqueness.
    func updateMyProfile(_ input: UpdateMyProfileInput) async throws -> Profile
}
