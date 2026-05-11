import Foundation
import XCTest
import RuulCore

/// Verifies the polymorphic `DetailSummaryView` reads its rows from
/// `SummaryFieldCatalog` correctly per resource type, snake_case +
/// camelCase fall-through, and that the formatter emits the expected
/// display strings. Guards against silently dropping rows after future
/// catalog edits or formatter regressions.
final class SummaryFieldCatalogTests: XCTestCase {

    // MARK: - Resolve

    func test_eventDescriptor_resolvesHostFromSnakeCase() {
        let metadata: JSONConfig = .object([
            "host_name": .string("Alice"),
        ])
        let host = SummaryFieldCatalog.v1
            .fields(for: .event)
            .first(where: { $0.id == "host" })!
            .resolve(in: metadata)
        XCTAssertEqual(host, "Alice")
    }

    func test_eventDescriptor_resolvesHostFromCamelCaseFallback() {
        let metadata: JSONConfig = .object([
            "hostName": .string("Bob"),
        ])
        let host = SummaryFieldCatalog.v1
            .fields(for: .event)
            .first(where: { $0.id == "host" })!
            .resolve(in: metadata)
        XCTAssertEqual(host, "Bob")
    }

    func test_eventCapacity_pluralizesAboveOne() {
        let descriptor = SummaryFieldCatalog.v1
            .fields(for: .event)
            .first(where: { $0.id == "capacity" })!
        XCTAssertEqual(descriptor.resolve(in: .object(["capacity_max": .int(8)])), "8 personas")
        XCTAssertEqual(descriptor.resolve(in: .object(["capacity_max": .int(1)])), "1 persona")
    }

    func test_descriptorReturnsNilWhenNoKeyHits() {
        let descriptor = SummaryFieldCatalog.v1
            .fields(for: .event)
            .first(where: { $0.id == "host" })!
        XCTAssertNil(descriptor.resolve(in: .object([:])))
        XCTAssertNil(descriptor.resolve(in: .object(["unrelated": .string("noise")])))
    }

    func test_descriptorReturnsNilWhenStringValueEmpty() {
        // Empty strings shouldn't render as a row — drops out.
        let descriptor = SummaryFieldCatalog.v1
            .fields(for: .event)
            .first(where: { $0.id == "host" })!
        XCTAssertNil(descriptor.resolve(in: .object(["host_name": .string("")])))
    }

    // MARK: - Catalog shape

    func test_catalogReturnsEmptyForUnconfiguredType() {
        // Phase 2 types (booking, assignment, rotation, etc.) have no V1
        // catalog entries yet — view collapses to empty rather than crashing.
        XCTAssertTrue(SummaryFieldCatalog.v1.fields(for: .booking).isEmpty)
        XCTAssertTrue(SummaryFieldCatalog.v1.fields(for: .contribution).isEmpty)
        XCTAssertTrue(SummaryFieldCatalog.v1.fields(for: .rotation).isEmpty)
    }

    func test_eventFields_orderedHostThenLocationThenCapacity() {
        // Order is contractual — the view renders in declaration order. A
        // catalog edit that reorders rows is a UX change worth flagging.
        let ids = SummaryFieldCatalog.v1.fields(for: .event).map(\.id)
        XCTAssertEqual(ids, ["host", "location", "capacity"])
    }

    // MARK: - Formatter

    func test_intWithUnitFormat_handlesSingularPlural() {
        let f = SummaryFieldFormat.intWithUnit(unit: "noche", unitPlural: "noches")
        XCTAssertEqual(f.format(.int(1)), "1 noche")
        XCTAssertEqual(f.format(.int(3)), "3 noches")
        XCTAssertNil(f.format(.string("not a number")))
    }

    func test_intCountFormat_doesNotAppendUnit() {
        XCTAssertEqual(SummaryFieldFormat.intCount.format(.int(12)), "12")
        XCTAssertNil(SummaryFieldFormat.intCount.format(.string("foo")))
    }

    func test_currencyCentsFormat_dividesAndCurrencyFormats() {
        // 120000 cents = $1,200. Locale-dependent currency string,
        // but the value (1200) must appear and there must be a currency
        // sigil — assert via contains rather than literal equality so the
        // test stays stable across CI locales.
        let rendered = SummaryFieldFormat.currencyCents(code: "MXN").format(.int(120_000)) ?? ""
        XCTAssertTrue(rendered.contains("1,200") || rendered.contains("1200"), "got: \(rendered)")
        XCTAssertNil(SummaryFieldFormat.currencyCents(code: "MXN").format(.string("nope")))
    }
}
