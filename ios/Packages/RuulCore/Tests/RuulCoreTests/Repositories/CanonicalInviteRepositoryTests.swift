import Foundation
import Testing
@testable import RuulCore

@Suite("CanonicalInviteRepository")
struct CanonicalInviteRepositoryTests {

    @Test("inviteMember defaults membershipType to 'member' and forwards email")
    func inviteMember() async throws {
        let mock = MockRuulRPCClient()
        let returnedId = UUID()
        await mock.setInviteMemberStub(.success(returnedId))
        let repo = CanonicalInviteRepository(rpc: mock)
        let groupId = UUID()

        let id = try await repo.inviteMember(groupId: groupId, email: "a@b.co")
        #expect(id == returnedId)

        let calls = await mock.recorded
        #expect(calls == [.inviteMember(groupId: groupId, email: "a@b.co", phone: nil, membershipType: "member", message: nil)])
    }

    @Test("inviteMember surfaces .inviteRequiresEmailOrPhone when backend rejects")
    func inviteMemberMissingContact() async throws {
        let mock = MockRuulRPCClient()
        await mock.setInviteMemberStub(.failure(.backend(.inviteRequiresEmailOrPhone)))
        let repo = CanonicalInviteRepository(rpc: mock)

        await #expect(throws: RuulError.backend(.inviteRequiresEmailOrPhone)) {
            _ = try await repo.inviteMember(groupId: UUID())
        }
    }

    @Test("acceptInvite returns the joined group + new membership id")
    func acceptInviteHappy() async throws {
        let mock = MockRuulRPCClient()
        let result = AcceptInviteResult(groupId: UUID(), membershipId: UUID())
        await mock.setAcceptInviteStub(.success(result))
        let repo = CanonicalInviteRepository(rpc: mock)

        let out = try await repo.acceptInvite(code: "ABC-123")
        #expect(out == result)

        let calls = await mock.recorded
        #expect(calls == [.acceptInvite(code: "ABC-123")])
    }

    @Test("acceptInvite propagates .inviteExpired")
    func acceptInviteExpired() async throws {
        let mock = MockRuulRPCClient()
        await mock.setAcceptInviteStub(.failure(.backend(.inviteExpired)))
        let repo = CanonicalInviteRepository(rpc: mock)

        await #expect(throws: RuulError.backend(.inviteExpired)) {
            _ = try await repo.acceptInvite(code: "X")
        }
    }
}
