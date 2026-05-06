import Foundation
import XCTest
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
}

// MARK: - Test fixtures

private extension Group {
    /// Minimal `Group` fixture for governance tests.
    static func mock(id: UUID) -> Group {
        Group(
            id: id,
            name: "Test Group",
            inviteCode: "test1234",
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
            joinedAt: .now
        )
    }
}
