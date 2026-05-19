import Testing
import Foundation
import RuulCore

// MARK: - ResourceRow.rightHolderMemberId

@Suite("ResourceRow.rightHolderMemberId")
struct ResourceRowRightHolderTests {

    @Test("returns nil for non-right resource even when metadata has the key")
    func nonRightReturnsNil() {
        let assetMemberId = UUID()
        let asset = ResourceRow(
            id: UUID(),
            groupId: UUID(),
            resourceType: .asset,
            status: "active",
            metadata: .object(["holder_member_id": .string(assetMemberId.uuidString)]),
            createdBy: UUID(),
            createdAt: .now,
            updatedAt: .now
        )
        #expect(asset.rightHolderMemberId == nil)
    }

    @Test("returns parsed UUID for right with valid metadata")
    func rightWithHolderReturnsId() {
        let memberId = UUID()
        let right = ResourceRow(
            id: UUID(),
            groupId: UUID(),
            resourceType: .right,
            status: "active",
            metadata: .object(["holder_member_id": .string(memberId.uuidString)]),
            createdBy: UUID(),
            createdAt: .now,
            updatedAt: .now
        )
        #expect(right.rightHolderMemberId == memberId)
    }

    @Test("returns nil when metadata key missing")
    func rightWithoutMetadataReturnsNil() {
        let right = ResourceRow(
            id: UUID(),
            groupId: UUID(),
            resourceType: .right,
            status: "active",
            metadata: .object([:]),
            createdBy: UUID(),
            createdAt: .now,
            updatedAt: .now
        )
        #expect(right.rightHolderMemberId == nil)
    }
}
