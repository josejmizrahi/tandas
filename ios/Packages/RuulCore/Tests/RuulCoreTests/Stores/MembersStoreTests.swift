import Foundation
import Testing
@testable import RuulCore

@MainActor
@Suite("MembersStore")
struct MembersStoreTests {

    private let groupId = UUID()

    private func makeMembership(
        id: UUID = UUID(),
        userId: UUID? = nil,
        name: String,
        status: MembershipStatus = .active,
        type: MembershipType = .member,
        roles: [String] = [],
        isCurrent: Bool = false
    ) -> MembershipBoundaryItem {
        MembershipBoundaryItem(
            id: id,
            kind: .membership,
            membershipId: id,
            userId: userId,
            displayName: name,
            status: status,
            membershipType: type,
            roleNames: roles,
            isCurrentUser: isCurrent
        )
    }

    private func makeInvite(
        id: UUID = UUID(),
        name: String,
        type: MembershipType = .member
    ) -> MembershipBoundaryItem {
        MembershipBoundaryItem(
            id: id,
            kind: .invite,
            inviteId: id,
            displayName: name,
            status: .invited,
            membershipType: type
        )
    }

    private func makeStore(items: [MembershipBoundaryItem]) async -> (MembersStore, MockRuulRPCClient) {
        let mock = MockRuulRPCClient()
        await mock.setGroupMembershipBoundaryStub(.success(items))
        let repo = CanonicalMembersRepository(
            rpc: mock,
            invites: CanonicalInviteRepository(rpc: mock)
        )
        return (MembersStore(repository: repo), mock)
    }

    // MARK: - Sections

    @Test("sections order: current user → active → provisional → invited → suspended")
    func sectionOrder() async {
        let me = makeMembership(userId: UUID(), name: "Yo", isCurrent: true)
        let active = makeMembership(name: "Ana")
        let provisional = makeMembership(name: "Mateo", type: .provisional)
        let invitedMembership = makeMembership(name: "Carlos", status: .invited)
        let pendingInvite = makeInvite(name: "diana@example.com")
        let suspended = makeMembership(name: "Diego", status: .suspended)

        let (store, _) = await makeStore(items: [
            me, active, provisional, invitedMembership, pendingInvite, suspended
        ])
        await store.refresh(groupId: groupId)

        let kinds = store.sections.map(\.kind)
        #expect(kinds == [.currentUser, .active, .provisional, .invited, .suspended])
    }

    @Test("pending invite rows land in the invited section regardless of kind")
    func invitedSectionMixesKinds() async {
        let pending = makeInvite(name: "carlos@example.com")
        let invitedMembership = makeMembership(name: "Diana", status: .invited)
        let (store, _) = await makeStore(items: [pending, invitedMembership])
        await store.refresh(groupId: groupId)

        let invitedSection = store.sections.first { $0.kind == .invited }
        #expect(invitedSection?.members.count == 2)
    }

    // MARK: - Search

    @Test("search matches displayName, username, and role names")
    func searchFiltersAcrossFields() async {
        let ana = MembershipBoundaryItem(
            id: UUID(), kind: .membership, membershipId: UUID(),
            displayName: "Ana López", username: "ana_l",
            status: .active, roleNames: ["Tesorero"]
        )
        let diego = MembershipBoundaryItem(
            id: UUID(), kind: .membership, membershipId: UUID(),
            displayName: "Diego Rojas", username: "diego",
            status: .active, roleNames: ["Coordinador"]
        )
        let (store, _) = await makeStore(items: [ana, diego])
        await store.refresh(groupId: groupId)

        store.searchText = "ANA"
        #expect(store.filteredItems.contains(where: { $0.displayName == "Ana López" }))
        #expect(store.filteredItems.count == 1)

        store.searchText = "diego"
        #expect(store.filteredItems.first?.username == "diego")

        store.searchText = "tesor"
        #expect(store.filteredItems.first?.displayName == "Ana López")
    }

    // MARK: - Refresh

    @Test("refresh loads boundary items via repository and lands on .loaded")
    func refreshHappyPath() async {
        let (store, mock) = await makeStore(items: [makeMembership(name: "Ana")])
        await store.refresh(groupId: groupId)

        #expect(store.items.count == 1)
        #expect(store.phase == .loaded)
        let recorded = await mock.recorded
        #expect(recorded.contains(.groupMembershipBoundary(groupId: groupId)))
    }

    @Test("refresh failure surfaces user-facing message and flips to .failed")
    func refreshFailure() async {
        let mock = MockRuulRPCClient()
        await mock.setGroupMembershipBoundaryStub(.failure(.backend(.mustBeAuthenticated)))
        let repo = CanonicalMembersRepository(
            rpc: mock,
            invites: CanonicalInviteRepository(rpc: mock)
        )
        let store = MembersStore(repository: repo)

        await store.refresh(groupId: groupId)
        if case .failed(let message) = store.phase {
            #expect(!message.isEmpty)
        } else {
            Issue.record("expected .failed, got \(store.phase)")
        }
        #expect(store.errorMessage != nil)
    }

    @Test("refreshIfNeeded is a no-op after a successful load for the same group")
    func refreshIfNeededIdempotent() async {
        let (store, mock) = await makeStore(items: [makeMembership(name: "Ana")])
        await store.refreshIfNeeded(groupId: groupId)
        await store.refreshIfNeeded(groupId: groupId)
        await store.refreshIfNeeded(groupId: groupId)
        let recorded = await mock.recorded
        let calls = recorded.filter { if case .groupMembershipBoundary = $0 { return true } else { return false } }
        #expect(calls.count == 1)
    }

    @Test("refreshIfNeeded re-fetches when group id changes")
    func refreshIfNeededOnGroupChange() async {
        let (store, mock) = await makeStore(items: [makeMembership(name: "Ana")])
        let other = UUID()
        await store.refreshIfNeeded(groupId: groupId)
        await store.refreshIfNeeded(groupId: other)
        let recorded = await mock.recorded
        let calls = recorded.filter { if case .groupMembershipBoundary = $0 { return true } else { return false } }
        #expect(calls.count == 2)
    }

    // MARK: - Invite

    @Test("invite happy path clears form, refreshes list, returns true")
    func inviteSuccess() async {
        let (store, mock) = await makeStore(items: [makeMembership(name: "Ana")])
        await mock.setInviteMemberStub(.success(UUID()))

        await store.refresh(groupId: groupId)
        store.inviteEmail = "carlos@example.com"
        store.inviteMessage = "Welcome"
        let ok = await store.inviteMember(groupId: groupId)
        #expect(ok)
        #expect(store.inviteEmail.isEmpty)
        #expect(store.inviteMessage.isEmpty)
        // A successful invite triggers a follow-up boundary refresh.
        let recorded = await mock.recorded
        let boundaryCalls = recorded.filter { if case .groupMembershipBoundary = $0 { return true } else { return false } }
        #expect(boundaryCalls.count >= 2)
    }

    @Test("invite failure surfaces errorMessage and keeps the form")
    func inviteFailure() async {
        let (store, mock) = await makeStore(items: [makeMembership(name: "Ana")])
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
        let (store, _) = await makeStore(items: [])
        let ok = await store.inviteMember(groupId: groupId)
        #expect(ok == false)
    }
}
