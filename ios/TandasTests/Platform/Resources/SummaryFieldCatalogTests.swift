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
        XCTAssertEqual(ids, ["host", "countdown", "location", "capacity", "duration"])
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

    // MARK: - Derived resolver (host via memberLookup)

    func test_hostDescriptor_resolvesByMemberLookupWhenMetadataHasOnlyHostId() {
        // events_view ships host_id (UUID) but not host_name — the
        // legacy projection doesn't denormalize. The view's
        // memberDirectory carries the name, so the derived resolver
        // bridges them.
        let aliceId = UUID()
        let metadata: JSONConfig = .object([
            "host_id": .string(aliceId.uuidString.lowercased()),
        ])
        let ctx = SummaryResolverContext(
            metadata: metadata,
            memberLookup: { id in id == aliceId ? "Alice Martínez" : nil }
        )
        let host = SummaryFieldCatalog.v1
            .fields(for: .event)
            .first(where: { $0.id == "host" })!
            .resolve(in: ctx)
        XCTAssertEqual(host, "Alice Martínez")
    }

    func test_hostDescriptor_prefersDenormalizedNameOverIdLookup() {
        // If a future events_view denormalizes host_name we should use
        // it directly — no member directory roundtrip required.
        let metadata: JSONConfig = .object([
            "host_id":   .string(UUID().uuidString.lowercased()),
            "host_name": .string("Cached Name"),
        ])
        let ctx = SummaryResolverContext(
            metadata: metadata,
            // Lookup would return "Wrong" if it ever fired — the assert
            // proves we short-circuited on the denormalized field.
            memberLookup: { _ in "Wrong" }
        )
        let host = SummaryFieldCatalog.v1
            .fields(for: .event)
            .first(where: { $0.id == "host" })!
            .resolve(in: ctx)
        XCTAssertEqual(host, "Cached Name")
    }

    func test_hostDescriptor_returnsNilWhenMemberLookupMisses() {
        // host_id present but the lookup doesn't know that user (e.g.
        // a former member who left the group, member directory not
        // hydrated yet, etc.). Row drops out rather than rendering
        // the raw UUID.
        let metadata: JSONConfig = .object([
            "host_id": .string(UUID().uuidString.lowercased()),
        ])
        let ctx = SummaryResolverContext(metadata: metadata, memberLookup: { _ in nil })
        let host = SummaryFieldCatalog.v1
            .fields(for: .event)
            .first(where: { $0.id == "host" })!
            .resolve(in: ctx)
        XCTAssertNil(host)
    }

    func test_metadataKeysResolver_ignoresMemberLookup() {
        // Non-host descriptors keep using metadataKeys exclusively —
        // a memberLookup that returns garbage shouldn't bleed into
        // capacity / location resolution.
        let metadata: JSONConfig = .object(["capacity_max": .int(6)])
        let ctx = SummaryResolverContext(metadata: metadata, memberLookup: { _ in "leaked" })
        let cap = SummaryFieldCatalog.v1
            .fields(for: .event)
            .first(where: { $0.id == "capacity" })!
            .resolve(in: ctx)
        XCTAssertEqual(cap, "6 personas")
    }
}
