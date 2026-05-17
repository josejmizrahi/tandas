import Foundation
import XCTest
import RuulUI
import RuulCore
@testable import Tandas

final class GovernanceServiceTests: XCTestCase {

    // MARK: - .issueManualFine (V1: synthetic .founder level)

    func testCanPerformIssueManualFine_allowedForFounder() async throws {
        let service = GovernanceService()
        let group = Group.mock(id: UUID())
        let founder = Member.mock(role: .founder, groupId: group.id)

        let decision = try await service.canPerform(
            .issueManualFine,
            member: founder,
            in: group,
            context: nil
        )

        if case .allowed = decision {
            // expected
        } else {
            XCTFail("expected .allowed, got \(decision)")
        }
    }

    func testCanPerformIssueManualFine_deniedForNonFounder() async throws {
        let service = GovernanceService()
        let group = Group.mock(id: UUID())
        let member = Member.mock(role: .member, groupId: group.id)

        let decision = try await service.canPerform(
            .issueManualFine,
            member: member,
            in: group,
            context: nil
        )

        guard case .denied(reason: .notFounder) = decision else {
            XCTFail("expected .denied(.notFounder), got \(decision)")
            return
        }
    }

    // MARK: - .voidFine (V1: synthetic .founder level)

    func testCanPerformVoidFine_allowedForFounder() async throws {
        let service = GovernanceService()
        let group = Group.mock(id: UUID())
        let founder = Member.mock(role: .founder, groupId: group.id)

        let decision = try await service.canPerform(
            .voidFine,
            member: founder,
            in: group,
            context: nil
        )

        if case .allowed = decision {
            // expected
        } else {
            XCTFail("expected .allowed, got \(decision)")
        }
    }

    func testCanPerformVoidFine_deniedForNonFounder() async throws {
        let service = GovernanceService()
        let group = Group.mock(id: UUID())
        let member = Member.mock(role: .member, groupId: group.id)

        let decision = try await service.canPerform(
            .voidFine,
            member: member,
            in: group,
            context: nil
        )

        guard case .denied(reason: .notFounder) = decision else {
            XCTFail("expected .denied(.notFounder), got \(decision)")
            return
        }
    }

    // MARK: - hasPermission (RolesV2 Phase 5)

    func testHasPermission_founderGrantsAssignRoles_fromV1SystemRoles() async throws {
        let service = GovernanceService()
        let group = Group.mock(id: UUID(), roles: RoleDefinition.v1SystemRoles)
        let founder = Member.mock(role: .founder, groupId: group.id)

        let allowed = try await service.hasPermission(.assignRoles, member: founder, in: group)
        XCTAssertTrue(allowed, "founder should grant assignRoles via v1 system roles")
    }

    func testHasPermission_memberDeniedAdminPermission() async throws {
        let service = GovernanceService()
        let group = Group.mock(id: UUID(), roles: RoleDefinition.v1SystemRoles)
        let member = Member.mock(role: .member, groupId: group.id)

        let allowed = try await service.hasPermission(.assignRoles, member: member, in: group)
        XCTAssertFalse(allowed, "member must not have assignRoles by default")
    }

    func testHasPermission_customRoleAggregatesPermissions() async throws {
        let service = GovernanceService()
        let treasurer = RoleDefinition(
            id: "treasurer",
            label: "Tesorero",
            permissions: [.fundWithdraw, .fundAudit],
            maxHolders: 2,
            system: false
        )
        var catalog = RoleDefinition.v1SystemRoles
        catalog["treasurer"] = treasurer
        let group = Group.mock(id: UUID(), roles: catalog)

        // Member holding treasurer + member roles should grant fundWithdraw.
        let member = Member.mock(
            role: .member,
            roles: ["treasurer", "member"],
            groupId: group.id
        )
        let canWithdraw = try await service.hasPermission(.fundWithdraw, member: member, in: group)
        XCTAssertTrue(canWithdraw, "custom role should grant its permissions")

        // Same member should NOT receive a permission only the founder role holds.
        let canAssign = try await service.hasPermission(.assignRoles, member: member, in: group)
        XCTAssertFalse(canAssign, "treasurer should not grant assignRoles unless catalog says so")
    }

    func testMemberCustomRolesRoundtripThroughRawRoles() throws {
        // jsonb shape coming back from the server: roles may include
        // custom ids the V1 MemberRole enum doesn't know about.
        let json = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "group_id": "22222222-2222-2222-2222-222222222222",
          "user_id": "33333333-3333-3333-3333-333333333333",
          "display_name_override": null,
          "role": "member",
          "roles": ["member", "treasurer", "seat_owner"],
          "active": true,
          "joined_at": "2024-01-01T00:00:00Z"
        }
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(Member.self, from: json)
        XCTAssertEqual(decoded.rawRoles, ["member", "treasurer", "seat_owner"])
        // V1 MemberRole knows "member" and "treasurer" but not "seat_owner".
        XCTAssertEqual(Set(decoded.roles), Set([.member, .treasurer]))
        XCTAssertTrue(decoded.holdsRole("seat_owner"))
        XCTAssertFalse(decoded.holdsRole("admin"))
    }
}

// MARK: - Test fixtures

private extension Group {
    /// Minimal `Group` fixture for governance tests.
    static func mock(
        id: UUID,
        roles: [String: RoleDefinition]? = nil
    ) -> Group {
        Group(
            id: id,
            name: "Test Group",
            inviteCode: "test1234",
            roles: roles,
            createdBy: UUID(),
            createdAt: .now
        )
    }
}

private extension Member {
    /// Minimal `Member` fixture for governance tests. The single-role
    /// override drives both `role` text and `roles` array, which is what
    /// `GovernanceService` reads.
    static func mock(role: MemberRole, groupId: UUID = UUID()) -> Member {
        Member(
            id: UUID(),
            groupId: groupId,
            userId: UUID(),
            role: role == .founder ? "admin" : "member",
            roles: [role],
            rawRoles: [role.rawValue],
            joinedAt: .now
        )
    }

    /// Fixture with arbitrary `rawRoles` to drive the Phase 5 multi-role
    /// hasPermission path. `role` is the legacy text fallback;
    /// `rawRoles` is the canonical jsonb array consumed by the protocol.
    static func mock(
        role: MemberRole,
        roles rawRoles: [String],
        groupId: UUID = UUID()
    ) -> Member {
        Member(
            id: UUID(),
            groupId: groupId,
            userId: UUID(),
            role: role == .founder ? "admin" : "member",
            roles: rawRoles.compactMap(MemberRole.init(rawValue:)),
            rawRoles: rawRoles,
            joinedAt: .now
        )
    }
}
