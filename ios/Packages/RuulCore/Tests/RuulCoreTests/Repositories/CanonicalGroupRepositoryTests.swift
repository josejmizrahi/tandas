import Foundation
import Testing
@testable import RuulCore

@Suite("CanonicalGroupRepository")
struct CanonicalGroupRepositoryTests {

    @Test("createGroup forwards every argument to the RPC client")
    func createGroup() async throws {
        let mock = MockRuulRPCClient()
        let returnedId = UUID()
        await mock.setCreateGroupStub(.success(returnedId))
        let repo = CanonicalGroupRepository(rpc: mock)

        let id = try await repo.createGroup(name: "Casa", slug: "casa", category: "dinner", purposeDeclared: "cenar")
        #expect(id == returnedId)

        let calls = await mock.recorded
        #expect(calls == [.createGroup(name: "Casa", slug: "casa", category: "dinner", purposeDeclared: "cenar")])
    }

    @Test("listMyGroups returns whatever the client returns")
    func listMyGroups() async throws {
        let mock = MockRuulRPCClient()
        let item = GroupListItem(id: UUID(), name: "G", slug: nil, category: nil, purposeSummary: nil, membershipId: UUID())
        await mock.setListMyGroupsStub(.success([item]))
        let repo = CanonicalGroupRepository(rpc: mock)

        let groups = try await repo.listMyGroups()
        #expect(groups == [item])

        let calls = await mock.recorded
        #expect(calls == [.listMyGroups])
    }

    @Test("leaveGroup forwards id + reason")
    func leaveGroup() async throws {
        let mock = MockRuulRPCClient()
        let repo = CanonicalGroupRepository(rpc: mock)
        let groupId = UUID()

        try await repo.leaveGroup(groupId: groupId, reason: "moving")

        let calls = await mock.recorded
        #expect(calls == [.leaveGroup(groupId: groupId, reason: "moving")])
    }

    @Test("groupSummary surfaces backend errors as RuulError")
    func summaryError() async throws {
        let mock = MockRuulRPCClient()
        await mock.setGroupSummaryStub(.failure(.backend(.crossTenantViolation)))
        let repo = CanonicalGroupRepository(rpc: mock)
        let groupId = UUID()

        await #expect(throws: RuulError.backend(.crossTenantViolation)) {
            _ = try await repo.groupSummary(groupId: groupId)
        }

        let calls = await mock.recorded
        #expect(calls == [.groupSummary(groupId: groupId)])
    }

    @Test("listMemberPermissions accepts nil userId")
    func listPermissions() async throws {
        let mock = MockRuulRPCClient()
        await mock.setListMemberPermissionsStub(.success(["money.expense.create"]))
        let repo = CanonicalGroupRepository(rpc: mock)
        let groupId = UUID()

        let perms = try await repo.listMemberPermissions(groupId: groupId, userId: nil)
        #expect(perms == ["money.expense.create"])

        let calls = await mock.recorded
        #expect(calls == [.listMemberPermissions(groupId: groupId, userId: nil)])
    }
}
