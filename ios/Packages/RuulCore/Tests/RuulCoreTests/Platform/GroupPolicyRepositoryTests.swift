import Foundation
import XCTest
import RuulCore

final class GroupPolicyRepositoryTests: XCTestCase {

    func testMockResolveReturnsConfiguredDecision() async throws {
        let repo = MockGroupPolicyRepository()
        let groupId = UUID()
        await repo.setResolution(
            groupId: groupId,
            action: .ruleToggle,
            decision: .voteRequired(quorumPercent: 50, thresholdPercent: 50, durationHours: 72)
        )

        let actual = try await repo.resolve(
            groupId: groupId,
            actorUserId: UUID(),
            action: .ruleToggle,
            targetPayload: [:]
        )

        XCTAssertEqual(actual, .voteRequired(quorumPercent: 50, thresholdPercent: 50, durationHours: 72))
    }

    func testMockResolveDefaultsToAdminOnlyWhenUnscripted() async throws {
        let repo = MockGroupPolicyRepository()
        let actual = try await repo.resolve(
            groupId: UUID(),
            actorUserId: UUID(),
            action: .ruleToggle,
            targetPayload: [:]
        )
        XCTAssertEqual(actual, .adminOnly)
    }

    func testMockUpsertReplacesByCompositeKey() async throws {
        let repo = MockGroupPolicyRepository()
        let groupId = UUID()
        let first = GroupPolicy(
            groupId: groupId,
            policyType: .voteRequired,
            targetAction: .ruleToggle,
            approvalConfig: .init(quorumPercent: 50, thresholdPercent: 50, durationHours: 72)
        )
        _ = try await repo.upsert(first)

        let updated = GroupPolicy(
            id: first.id,
            groupId: groupId,
            policyType: .adminOnly,
            targetAction: .ruleToggle
        )
        _ = try await repo.upsert(updated)

        let listed = try await repo.list(groupId: groupId)
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed.first?.policyType, .adminOnly)
    }

    func testMockApplyPresetReplacesRuleStarPoliciesAtGroupScope() async throws {
        let repo = MockGroupPolicyRepository()
        let groupId = UUID()

        // Seed a pre-existing balanced state.
        try await repo.applyPreset(.balanced, groupId: groupId)
        var policies = try await repo.list(groupId: groupId)
        XCTAssertEqual(policies.count, 4)
        XCTAssertTrue(policies.contains { $0.targetAction == .ruleUpdateAmount && $0.policyType == .voteRequired })

        // Switch to strict — should fully replace at scope=group.
        try await repo.applyPreset(.strict, groupId: groupId)
        policies = try await repo.list(groupId: groupId)
        XCTAssertEqual(policies.count, 4)
        let toggle = policies.first { $0.targetAction == .ruleToggle }
        XCTAssertEqual(toggle?.policyType, .voteRequired)
        XCTAssertEqual(toggle?.approvalConfig?.quorumPercent, 60)
    }

    func testMockApplyPresetIsRecorded() async throws {
        let repo = MockGroupPolicyRepository()
        let groupId = UUID()
        try await repo.applyPreset(.balanced, groupId: groupId)
        try await repo.applyPreset(.strict, groupId: groupId)
        let applied = await repo.appliedPresets
        XCTAssertEqual(applied.map(\.presetId), ["balanced", "strict"])
        XCTAssertEqual(applied.map(\.groupId), [groupId, groupId])
    }
}
