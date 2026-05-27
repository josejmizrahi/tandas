import Foundation
import Testing
@testable import RuulCore

@Suite("CanonicalProfileRepository")
struct CanonicalProfileRepositoryTests {

    @Test("updateMyProfile trims displayName before sending to RPC")
    func trimsBeforeSend() async throws {
        let mock = MockRuulRPCClient()
        let updated = Profile(id: UUID(), displayName: "Jose")
        await mock.setUpdateMyProfileStub(.success(updated))
        let repo = CanonicalProfileRepository(rpc: mock)

        _ = try await repo.updateMyProfile(
            displayName: "  Jose  ",
            username: "  Jose_M  ",
            avatarURL: "",
            bio: "   "
        )

        let recorded = await mock.recorded
        guard case .updateMyProfile(let input) = recorded.last else {
            Issue.record("expected updateMyProfile call, got \(recorded)")
            return
        }
        #expect(input.pDisplayName == "Jose")
        // Username is trimmed by the repo; backend lowercases.
        #expect(input.pUsername == "Jose_M")
        // Empty strings collapse to nil so the RPC doesn't see "".
        #expect(input.pAvatarUrl == nil)
        #expect(input.pBio == nil)
    }

    @Test("myProfile passes through the rpc result")
    func myProfilePassThrough() async throws {
        let mock = MockRuulRPCClient()
        let seed = Profile(id: UUID(), displayName: "Ana")
        await mock.setMyProfileStub(.success(seed))
        let repo = CanonicalProfileRepository(rpc: mock)

        let result = try await repo.myProfile()
        #expect(result == seed)
    }

    @Test("updateMyProfile propagates backend errors")
    func errorPropagation() async {
        let mock = MockRuulRPCClient()
        await mock.setUpdateMyProfileStub(.failure(.backend(.usernameAlreadyTaken)))
        let repo = CanonicalProfileRepository(rpc: mock)

        await #expect(throws: RuulError.backend(.usernameAlreadyTaken)) {
            _ = try await repo.updateMyProfile(displayName: "Ana", username: "ana")
        }
    }
}
