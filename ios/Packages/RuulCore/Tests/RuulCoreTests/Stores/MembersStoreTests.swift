import Foundation
import Testing
@testable import RuulCore

@MainActor
@Suite("MembersStore")
struct MembersStoreTests {

    private let groupId = UUID()

    private func makeRow(
        id: UUID = UUID(),
        userId: UUID? = nil,
        name: String,
        status: MembershipStatus = .active,
        type: MembershipType = .member,
        roles: [String] = [],
        isCurrent: Bool = false
    ) -> MemberListItem {
        MemberListItem(
            id: id,
            userId: userId,
            displayName: name,
            status: status,
            membershipType: type,
            roleNames: roles,
            isCurrentUser: isCurrent
        )
    }

    private func makeStore(rows: [MemberListItem]) async -> (MembersStore, MockRuulRPCClient) {
        let mock = MockRuulRPCClient()
        await mock.setGroupMembersStub(.success(rows))
        let repo = CanonicalMembersRepository(
            rpc: mock,
            invites: CanonicalInviteRepository(rpc: mock)
        )
        return (MembersStore(repository: repo), mock)
    }

    // MARK: - Sections

    @Test("sections order: current user → active → provisional → invited → suspended")
    func sectionOrder() async {
        let me = makeRow(userId: UUID(), name: "Yo", isCurrent: true)
        let active = makeRow(name: "Ana")
        let provisional = makeRow(name: "Mateo", type: .provisional)
        let invited = makeRow(name: "Carlos", status: .invited)
        let suspended = makeRow(name: "Diego", status: .suspended)

        let (store, _) = await makeStore(rows: [me, active, provisional, invited, suspended])
        await store.refresh(groupId: groupId)

        let kinds = store.sections.map(\.kind)
        #expect(kinds == [.currentUser, .active, .provisional, .invited, .suspended])
    }

    // MARK: - Search

    @Test("search filters by display name case-insensitively")
    func searchFiltersByName() async {
        let (store, _) = await makeStore(rows: [
            makeRow(name: "Ana López"),
            makeRow(name: "Diego Rojas")
        ])
        await store.refresh(groupId: groupId)

        store.searchText = "ana"
        #expect(store.filteredMembers.count == 1)
        #expect(store.filteredMembers.first?.displayName == "Ana López")

        store.searchText = "  "
        #expect(store.filteredMembers.count == 2)
    }

    // MARK: - Refresh

    @Test("refresh loads members via repository and lands on .loaded")
    func refreshHappyPath() async {
        let (store, mock) = await makeStore(rows: [makeRow(name: "Ana")])
        await store.refresh(groupId: groupId)

        #expect(store.members.count == 1)
        #expect(store.phase == .loaded)
        let recorded = await mock.recorded
        #expect(recorded.contains(.groupMembers(groupId: groupId)))
    }

    @Test("refresh failure surfaces user-facing message and flips to .failed")
    func refreshFailure() async {
        let mock = MockRuulRPCClient()
        await mock.setGroupMembersStub(.failure(.backend(.mustBeAuthenticated)))
        let repo = CanonicalMembersRepository(
            rpc: mock,
            invites: CanonicalInviteRepository(rpc: mock)
        )
        let store = MembersStore(repository: repo)

        await store.refresh(groupId: groupId)
        if case .failed(let message) = store.phase {
            #expect(!message.isEmpty)
        } else {
            Issue.record("expected .failed phase, got \(store.phase)")
        }
        #expect(store.errorMessage != nil)
    }

    @Test("refreshIfNeeded is a no-op after a successful load for the same group")
    func refreshIfNeededIdempotent() async {
        let (store, mock) = await makeStore(rows: [makeRow(name: "Ana")])
        await store.refreshIfNeeded(groupId: groupId)
        await store.refreshIfNeeded(groupId: groupId)
        await store.refreshIfNeeded(groupId: groupId)
        let recorded = await mock.recorded
        let calls = recorded.filter { if case .groupMembers = $0 { return true } else { return false } }
        #expect(calls.count == 1)
    }

    @Test("refreshIfNeeded re-fetches when group id changes")
    func refreshIfNeededOnGroupChange() async {
        let (store, mock) = await makeStore(rows: [makeRow(name: "Ana")])
        let other = UUID()
        await store.refreshIfNeeded(groupId: groupId)
        await store.refreshIfNeeded(groupId: other)
        let recorded = await mock.recorded
        let calls = recorded.filter { if case .groupMembers = $0 { return true } else { return false } }
        #expect(calls.count == 2)
    }

    // MARK: - Invite

    @Test("invite happy path clears form, refreshes list, returns true")
    func inviteSuccess() async {
        let (store, mock) = await makeStore(rows: [makeRow(name: "Ana")])
        await mock.setInviteMemberStub(.success(UUID()))

        await store.refresh(groupId: groupId)
        store.inviteEmail = "carlos@example.com"
        store.inviteMessage = "Welcome"
        let ok = await store.inviteMember(groupId: groupId)
        #expect(ok)
        #expect(store.inviteEmail.isEmpty)
        #expect(store.inviteMessage.isEmpty)
        // refresh runs a second list fetch after a successful invite
        let recorded = await mock.recorded
        let listCalls = recorded.filter { if case .groupMembers = $0 { return true } else { return false } }
        #expect(listCalls.count >= 2)
    }

    @Test("invite failure surfaces errorMessage and keeps the form")
    func inviteFailure() async {
        let (store, mock) = await makeStore(rows: [makeRow(name: "Ana")])
        await mock.setInviteMemberStub(.failure(.backend(.inviteRequiresEmailOrPhone)))
        await store.refresh(groupId: groupId)

        store.invitePhone = "+521111111111"
        let ok = await store.inviteMember(groupId: groupId)
        #expect(ok == false)
        #expect(store.errorMessage != nil)
        #expect(store.invitePhone == "+521111111111")
    }

    @Test("invite rejected when both email and phone are blank")
    func inviteBlocksWhenBlank() async {
        let (store, _) = await makeStore(rows: [])
        let ok = await store.inviteMember(groupId: groupId)
        #expect(ok == false)
    }
}
