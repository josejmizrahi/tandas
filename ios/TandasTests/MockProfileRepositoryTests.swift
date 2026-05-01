import Testing
import Foundation
@testable import Tandas

@Suite("MockProfileRepository")
struct MockProfileRepositoryTests {
    @Test("loads default profile (empty display_name)")
    func loadsEmpty() async throws {
        let repo = MockProfileRepository()
        let p = try await repo.loadMine()
        #expect(p.displayName.isEmpty)
        #expect(p.needsOnboarding)
    }

    @Test("update display_name persists in mock state")
    func updates() async throws {
        let repo = MockProfileRepository()
        try await repo.updateDisplayName("Jose")
        let p = try await repo.loadMine()
        #expect(p.displayName == "Jose")
        #expect(!p.needsOnboarding)
    }
}
