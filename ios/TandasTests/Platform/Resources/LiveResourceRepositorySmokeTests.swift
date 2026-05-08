import Testing
import Foundation
import Supabase
import RuulCore

/// Manual verification scaffold for `LiveResourceRepository`. CI skips
/// by default — flip the `.disabled` traits and substitute a real
/// `groupId` to run against a live Supabase project.
@Suite("LiveResourceRepository smoke", .disabled())
struct LiveResourceRepositorySmokeTests {
    @Test("list returns rows from a known group", .disabled())
    func smoke() async throws {
        // Manual: replace with a real groupId from your Supabase project.
        let groupId = UUID(uuidString: "REPLACE-WITH-REAL-GROUP-ID")!

        let url = URL(string: ProcessInfo.processInfo.environment["TANDAS_SUPABASE_URL"]!)!
        let key = ProcessInfo.processInfo.environment["TANDAS_SUPABASE_ANON_KEY"]!
        let client = SupabaseClient(supabaseURL: url, supabaseKey: key)
        let repo = LiveResourceRepository(client: client)

        let rows = try await repo.list(
            in: groupId,
            types: [.event],
            statuses: nil,
            limit: 10
        )

        // Sanity — V1 prod has 18 event resources. Any row in the
        // group should round-trip as an Event.
        for row in rows where row.resourceType == .event {
            _ = try row.decodeAsEvent()
        }
    }
}
