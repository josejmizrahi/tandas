import Foundation
import Testing
@testable import RuulCore

@Suite("GroupFoundationStatus domain")
struct GroupFoundationStatusTests {

    @Test("decodes a ready group with full per-primitive counts")
    func decodesReady() throws {
        let gid = UUID()
        let json = """
        {
          "group_id": "\(gid.uuidString)",
          "members":   { "status": "complete", "active_count": 3, "required": "..." },
          "boundary":  { "status": "complete", "active_count": 3, "pending_invites_count": 1, "required": "..." },
          "purpose":   { "status": "complete", "active_count": 1, "required": "..." },
          "rules":     { "status": "complete", "active_count": 2, "required": "..." },
          "resources": { "status": "complete", "active_count": 4, "required": "..." },
          "overall_status": "ready"
        }
        """.data(using: .utf8)!
        let s = try JSONDecoder().decode(GroupFoundationStatus.self, from: json)
        #expect(s.groupId == gid)
        #expect(s.isReady)
        #expect(s.completionRatio == 1.0)
        #expect(s.incompletePrimitives.isEmpty)
        #expect(s.members.activeCount == 3)
        #expect(s.boundary.pendingInvitesCount == 1)
        #expect(s.resources.activeCount == 4)
    }

    @Test("decodes a not_ready group with mixed completeness")
    func decodesNotReady() throws {
        let gid = UUID()
        let json = """
        {
          "group_id": "\(gid.uuidString)",
          "members":   { "status": "complete",   "active_count": 1, "required": "..." },
          "boundary":  { "status": "incomplete", "active_count": 1, "pending_invites_count": 0, "required": "..." },
          "purpose":   { "status": "incomplete", "active_count": 0, "required": "..." },
          "rules":     { "status": "incomplete", "active_count": 0, "required": "..." },
          "resources": { "status": "incomplete", "active_count": 0, "required": "..." },
          "overall_status": "not_ready"
        }
        """.data(using: .utf8)!
        let s = try JSONDecoder().decode(GroupFoundationStatus.self, from: json)
        #expect(s.isReady == false)
        #expect(s.incompletePrimitives == [.boundary, .purpose, .rules, .resources])
        #expect(s.completionRatio == 0.2)
    }

    @Test("decodes when optional summaries are missing")
    func decodesWithoutSummaries() throws {
        let gid = UUID()
        let json = """
        {
          "group_id": "\(gid.uuidString)",
          "members":   { "status": "complete" },
          "boundary":  { "status": "complete" },
          "purpose":   { "status": "complete" },
          "rules":     { "status": "complete" },
          "resources": { "status": "complete" },
          "overall_status": "ready"
        }
        """.data(using: .utf8)!
        let s = try JSONDecoder().decode(GroupFoundationStatus.self, from: json)
        #expect(s.isReady)
        #expect(s.members.activeCount == nil)
        #expect(s.boundary.pendingInvitesCount == nil)
        #expect(s.members.required == nil)
    }

    @Test("unknown enum values fall back to safe defaults")
    func defensiveFallbacks() throws {
        let gid = UUID()
        let json = """
        {
          "group_id": "\(gid.uuidString)",
          "members":   { "status": "future" },
          "boundary":  { "status": "future" },
          "purpose":   { "status": "future" },
          "rules":     { "status": "future" },
          "resources": { "status": "future" },
          "overall_status": "future"
        }
        """.data(using: .utf8)!
        let s = try JSONDecoder().decode(GroupFoundationStatus.self, from: json)
        #expect(s.isReady == false)
        #expect(s.members.status == .incomplete)
    }

    @Test("primitive(for:) maps each kind to the right field")
    func lookupHelper() {
        let s = GroupFoundationStatus(
            groupId: UUID(),
            members: .init(status: .complete, activeCount: 1),
            boundary: .init(status: .incomplete),
            purpose: .init(status: .complete),
            rules: .init(status: .incomplete),
            resources: .init(status: .complete),
            overallStatus: .notReady
        )
        #expect(s.primitive(for: .members).activeCount == 1)
        #expect(s.primitive(for: .boundary).isComplete == false)
        #expect(s.primitive(for: .resources).isComplete)
    }
}
