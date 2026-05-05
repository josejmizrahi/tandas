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
}
