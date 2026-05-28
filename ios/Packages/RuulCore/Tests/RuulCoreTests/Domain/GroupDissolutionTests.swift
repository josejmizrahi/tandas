import Foundation
import Testing
@testable import RuulCore

@Suite("GroupDissolution domain")
struct GroupDissolutionTests {

    @Test("Decodes the canonical jsonb with status + open_obligations_count")
    func decodesActive() throws {
        let did = UUID(); let gid = UUID(); let dec = UUID()
        let json = """
        {
          "dissolution_id":          "\(did.uuidString)",
          "group_id":                "\(gid.uuidString)",
          "initiated_by":            null,
          "initiated_by_display_name": "Jose",
          "source_decision_id":      "\(dec.uuidString)",
          "status":                  "approved",
          "reason":                  "Cerramos el ciclo.",
          "proposed_at":             null,
          "approved_at":             null,
          "executed_at":             null,
          "updated_at":              null,
          "open_obligations_count":  0
        }
        """.data(using: .utf8)!
        let d = try JSONDecoder().decode(GroupDissolution.self, from: json)
        #expect(d.id == did)
        #expect(d.groupId == gid)
        #expect(d.status == .approved)
        #expect(d.sourceDecisionId == dec)
        #expect(d.openObligationsCount == 0)
        #expect(d.canFinalize)
    }

    @Test("canFinalize false when status not approved or obligations remain")
    func canFinalizeRules() {
        let proposed = GroupDissolution(id: UUID(), groupId: UUID(), status: .proposed, openObligationsCount: 0)
        #expect(proposed.canFinalize == false)
        let approvedDirty = GroupDissolution(id: UUID(), groupId: UUID(), status: .approved, openObligationsCount: 2)
        #expect(approvedDirty.canFinalize == false)
        let approvedClean = GroupDissolution(id: UUID(), groupId: UUID(), status: .approved, openObligationsCount: 0)
        #expect(approvedClean.canFinalize)
    }

    @Test("DissolutionStatus.isActive partitions in-progress vs terminal")
    func statusIsActive() {
        #expect(DissolutionStatus.proposed.isActive)
        #expect(DissolutionStatus.approved.isActive)
        #expect(DissolutionStatus.liquidating.isActive)
        #expect(DissolutionStatus.executed.isActive == false)
        #expect(DissolutionStatus.cancelled.isActive == false)
    }

    @Test("Wire DTO returns nil when dissolution_id missing (empty {} from backend)")
    func wireDTOEmpty() throws {
        let json = "{}".data(using: .utf8)!
        let dto = try JSONDecoder().decode(GroupDissolutionWireDTO.self, from: json)
        #expect(dto.toDomain() == nil)
    }
}
