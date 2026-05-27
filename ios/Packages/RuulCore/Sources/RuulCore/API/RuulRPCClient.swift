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
}
