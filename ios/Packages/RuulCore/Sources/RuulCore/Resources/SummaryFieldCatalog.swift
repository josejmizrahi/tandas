import Foundation

/// Declarative descriptor for a single row in the polymorphic
/// `DetailSummaryView` zone. Closes audit gap #6 — V1 had a switch over
/// `ResourceType` inside the view returning a hand-coded list of fields
/// per type, so each new type meant editing the View. With this catalog
/// new types add an entry here and the View renders them automatically.
public struct SummaryFieldDescriptor: Sendable, Hashable, Identifiable {
    /// Stable id used by the View for diffing (ForEach key).
    public let id: String

    /// SF Symbol name rendered on the left of the row.
    public let icon: String

    /// Human label shown next to the icon. Keep short — the value
    /// occupies the right column.
    public let label: String

    /// Metadata keys to try in order; first hit wins. Supports both
    /// snake_case (server canonical) and camelCase (Swift-encoded
    /// drafts) so round-trips don't drop the row.
    public let metadataKeys: [String]

    /// How to turn the raw `JSONConfig` value into a display string.
    public let format: SummaryFieldFormat

    public init(
        id: String,
        icon: String,
        label: String,
        metadataKeys: [String],
        format: SummaryFieldFormat
    ) {
        self.id = id
        self.icon = icon
        self.label = label
        self.metadataKeys = metadataKeys
        self.format = format
    }
}

/// Value formatting strategy. Decoupled from SwiftUI so the catalog can
/// live in RuulCore. Renderer-agnostic — a future macOS / web client can
/// reuse the same catalog.
public enum SummaryFieldFormat: Sendable, Hashable {
    /// Raw string value (must be non-empty).
    case string

    /// Integer value with a unit suffix. `unitPlural` defaults to `unit`
    /// when nil. Example: `intWithUnit(unit: "persona", unitPlural: "personas")`
    /// → "1 persona" / "8 personas".
    case intWithUnit(unit: String, unitPlural: String?)

    /// Integer value rendered as a count without unit. Example: "8" for
    /// `int(8)`.
    case intCount

    /// Cents integer rendered as a currency string in the given ISO code.
    case currencyCents(code: String)

    /// Resolves the descriptor's value out of the supplied JSONConfig.
    /// Returns nil when the value is missing or doesn't match the
    /// expected shape — the row is then dropped from the rendered list.
    public func format(_ value: JSONConfig) -> String? {
        switch self {
        case .string:
            guard let s = value.stringValue, !s.isEmpty else { return nil }
            return s
        case .intWithUnit(let unit, let unitPlural):
            guard let n = value.intValue else { return nil }
            let suffix = (n == 1 ? unit : (unitPlural ?? unit))
            return "\(n) \(suffix)"
        case .intCount:
            guard let n = value.intValue else { return nil }
            return "\(n)"
        case .currencyCents(let code):
            guard let cents = value.intValue else { return nil }
            let nf = NumberFormatter()
            nf.numberStyle = .currency
            nf.currencyCode = code
            nf.maximumFractionDigits = 0
            return nf.string(from: NSDecimalNumber(value: cents / 100))
                ?? "$\(cents / 100)"
        }
    }
}

/// Static catalog of summary fields per `ResourceType`. V1 mirrors the
/// previously-hardcoded switch in `DetailSummaryView` so behaviour is
/// preserved exactly; Phase 2 modules will ship their own descriptors
/// via `ModuleRegistry` (out of scope for this slice).
///
/// Order matters — the View renders fields in declaration order, top
/// to bottom. Keep the most identity-relevant row first (host for an
/// event, balance for a fund, …).
public struct SummaryFieldCatalog: Sendable {
    public let fieldsByResourceType: [ResourceType: [SummaryFieldDescriptor]]

    public init(fieldsByResourceType: [ResourceType: [SummaryFieldDescriptor]]) {
        self.fieldsByResourceType = fieldsByResourceType
    }

    /// Returns the configured fields for `type`, or an empty array when
    /// the type has no catalog entry. An empty list is a valid answer —
    /// the View collapses to an empty section in that case.
    public func fields(for type: ResourceType) -> [SummaryFieldDescriptor] {
        fieldsByResourceType[type] ?? []
    }

    /// V1 catalog. Field set mirrors the previously hard-coded behaviour
    /// in `DetailSummaryView` so this refactor is observably equivalent.
    public static let v1: SummaryFieldCatalog = SummaryFieldCatalog(
        fieldsByResourceType: [
            .event: [
                SummaryFieldDescriptor(
                    id: "host",
                    icon: "star.fill",
                    label: "Host",
                    metadataKeys: ["host_name", "hostName"],
                    format: .string
                ),
                SummaryFieldDescriptor(
                    id: "location",
                    icon: "mappin.and.ellipse",
                    label: "Lugar",
                    metadataKeys: ["location_name", "locationName"],
                    format: .string
                ),
                SummaryFieldDescriptor(
                    id: "capacity",
                    icon: "person.3.fill",
                    label: "Capacidad",
                    metadataKeys: ["capacity_max", "capacityMax"],
                    format: .intWithUnit(unit: "persona", unitPlural: "personas")
                ),
            ],
            .asset: [
                SummaryFieldDescriptor(
                    id: "owners",
                    icon: "person.2.fill",
                    label: "Dueños",
                    metadataKeys: ["owners_count", "ownersCount"],
                    format: .intCount
                ),
                SummaryFieldDescriptor(
                    id: "capacity",
                    icon: "person.3.fill",
                    label: "Capacidad",
                    metadataKeys: ["capacity"],
                    format: .string
                ),
            ],
            .fund: [
                SummaryFieldDescriptor(
                    id: "balance",
                    icon: "banknote",
                    label: "Saldo",
                    metadataKeys: ["balance_cents", "balanceCents"],
                    format: .currencyCents(code: "MXN")
                ),
            ],
            .slot: [
                SummaryFieldDescriptor(
                    id: "capacity",
                    icon: "person.3.fill",
                    label: "Capacidad",
                    metadataKeys: ["capacity"],
                    format: .intCount
                ),
            ],
        ]
    )
}

extension SummaryFieldDescriptor {
    /// Resolves the first matching metadata value for this descriptor
    /// and runs it through `format`. Returns nil when no key hits or
    /// the formatter rejects the value.
    public func resolve(in metadata: JSONConfig) -> String? {
        for key in metadataKeys {
            if let value = metadata[key], let rendered = format.format(value) {
                return rendered
            }
        }
        return nil
    }
}
