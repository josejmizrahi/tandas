import Foundation
import XCTest
import RuulCore
@testable import Tandas

final class CodableEnumsTests: XCTestCase {
    func testPermissionLevelRoundTrip() throws {
        for value in PermissionLevel.knownCases {
            let data = try JSONEncoder().encode(value)
            let decoded = try JSONDecoder().decode(PermissionLevel.self, from: data)
            XCTAssertEqual(value, decoded)
        }

        let unknownData = #""futureLevel""#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(PermissionLevel.self, from: unknownData)
        guard case .unknown(let s) = decoded, s == "futureLevel" else {
            XCTFail("expected .unknown(\"futureLevel\"), got \(decoded)")
            return
        }
    }

    func testResourceTypeRoundTrip() throws {
        for value in ResourceType.knownCases {
            let data = try JSONEncoder().encode(value)
            let decoded = try JSONDecoder().decode(ResourceType.self, from: data)
            XCTAssertEqual(value, decoded)
        }

        let unknownData = #""futureResource""#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ResourceType.self, from: unknownData)
        guard case .unknown(let s) = decoded, s == "futureResource" else {
            XCTFail("expected .unknown(\"futureResource\"), got \(decoded)")
            return
        }
    }

    func testConsequenceTypeRoundTrip() throws {
        for value in ConsequenceType.knownCases {
            let data = try JSONEncoder().encode(value)
            let decoded = try JSONDecoder().decode(ConsequenceType.self, from: data)
            XCTAssertEqual(value, decoded)
        }

        let unknownData = #""futureConsequence""#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ConsequenceType.self, from: unknownData)
        guard case .unknown(let s) = decoded, s == "futureConsequence" else {
            XCTFail("expected .unknown(\"futureConsequence\"), got \(decoded)")
            return
        }
    }

    func testConditionTypeRoundTrip() throws {
        for value in ConditionType.knownCases {
            let data = try JSONEncoder().encode(value)
            let decoded = try JSONDecoder().decode(ConditionType.self, from: data)
            XCTAssertEqual(value, decoded)
        }

        let unknownData = #""futureCondition""#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ConditionType.self, from: unknownData)
        guard case .unknown(let s) = decoded, s == "futureCondition" else {
            XCTFail("expected .unknown(\"futureCondition\"), got \(decoded)")
            return
        }
    }

    func testSystemEventTypeRoundTrip() throws {
        for value in SystemEventType.knownCases {
            let data = try JSONEncoder().encode(value)
            let decoded = try JSONDecoder().decode(SystemEventType.self, from: data)
            XCTAssertEqual(value, decoded)
        }

        let unknownData = #""futureSystemEvent""#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(SystemEventType.self, from: unknownData)
        guard case .unknown(let s) = decoded, s == "futureSystemEvent" else {
            XCTFail("expected .unknown(\"futureSystemEvent\"), got \(decoded)")
            return
        }
    }

    // MARK: - History rendering for new SystemEventType cases (e266a16)

    func testRuleEnabledChangedRenders() {
        let event = SystemEvent.mock(type: .ruleEnabledChanged, occurredAt: Date())
        let p = HistoryItemPresentation(event: event, memberName: "Alice")
        XCTAssertEqual(p.icon, "switch.2")
        XCTAssertEqual(p.title, "Alice cambió el estado de una regla")
        XCTAssertEqual(p.tone, .neutral)
    }

    func testRuleAmountChangedRenders() {
        let event = SystemEvent.mock(type: .ruleAmountChanged, occurredAt: Date())
        let p = HistoryItemPresentation(event: event, memberName: "Alice")
        XCTAssertEqual(p.icon, "pencil.line")
        XCTAssertEqual(p.title, "Alice editó la multa de una regla")
        XCTAssertEqual(p.tone, .neutral)
    }
}

// MARK: - Test fixtures

extension SystemEvent {
    /// Minimal fixture for tests that only care about `eventType` + `occurredAt`.
    static func mock(type: SystemEventType, occurredAt: Date) -> SystemEvent {
        SystemEvent(
            id: UUID(),
            groupId: UUID(),
            eventType: type,
            resourceId: nil,
            memberId: nil,
            payload: .empty,
            occurredAt: occurredAt,
            processedAt: nil
        )
    }
}
