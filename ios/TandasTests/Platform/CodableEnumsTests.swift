import Foundation
import XCTest
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
}
