import Foundation

/// Minimal context the summary catalog needs to resolve a field's display
/// value. Decoupled from `ResourceDetailContext` (which lives in
/// RuulFeatures) so the catalog stays in RuulCore without a circular
/// import. View layers map their richer context into this minimal
/// shape — currently just `(metadata, memberLookup)`, future Phase 2
/// types can extend the lookup surface as new cross-references appear
/// (e.g. groupLookup for fund.holder_group_id).
public struct SummaryResolverContext: Sendable {
    /// `JSONConfig` blob from `resources.metadata`. Always available.
    public let metadata: JSONConfig
    /// Resolves an `auth.users.id` → human display name. Returns nil
    /// when the id isn't in the caller's member directory. Closures
    /// are `@Sendable` so the catalog stays usable across actor
    /// boundaries.
    public let memberLookup: @Sendable (UUID) -> String?

    public init(
        metadata: JSONConfig,
        memberLookup: @escaping @Sendable (UUID) -> String?
    ) {
        self.metadata = metadata
        self.memberLookup = memberLookup
    }
}

/// How a `SummaryFieldDescriptor` derives its display value. Two paths:
///   - `metadataKeys` — try each key in `keys` against `metadata`,
///     format the first hit. The common case (location, capacity, etc).
///   - `derived` — run an arbitrary closure over the full
///     `SummaryResolverContext`. Used when a field needs cross-lookups
///     the metadata alone can't satisfy (e.g. `host_id` → member name).
public enum SummaryFieldResolver: Sendable {
    case metadataKeys(keys: [String], format: SummaryFieldFormat)
    case derived(@Sendable (SummaryResolverContext) -> String?)
}

/// Declarative descriptor for a single row in the polymorphic
/// `DetailSummaryView`. Closes audit gap #6 — V1 had a switch over
/// `ResourceType` inside the view returning a hand-coded list of fields
/// per type. With this catalog new types add an entry here and the
/// view renders them automatically. Each descriptor resolves through
/// either a static metadata-key path or a derived context-aware closure.
public struct SummaryFieldDescriptor: Sendable, Identifiable {
    public let id: String
    public let icon: String
    public let label: String
    public let resolver: SummaryFieldResolver

    public init(
        id: String,
        icon: String,
        label: String,
        resolver: SummaryFieldResolver
    ) {
        self.id = id
        self.icon = icon
        self.label = label
        self.resolver = resolver
    }

    /// Resolves the descriptor's display value against the context.
    /// Returns nil when the value is missing or doesn't match the
    /// expected shape — the row is then dropped from the rendered list.
    public func resolve(in context: SummaryResolverContext) -> String? {
        switch resolver {
        case .metadataKeys(let keys, let format):
            for key in keys {
                if let value = context.metadata[key], let rendered = format.format(value) {
                    return rendered
                }
            }
            return nil
        case .derived(let fn):
            return fn(context)
        }
    }

    /// Back-compat: resolves with metadata only and a no-op member
    /// lookup. Used by the catalog unit tests that exercise pure
    /// metadata-key resolution without needing to construct a member
    /// directory.
    public func resolve(in metadata: JSONConfig) -> String? {
        resolve(in: SummaryResolverContext(metadata: metadata, memberLookup: { _ in nil }))
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
/// Order matters — the view renders fields in declaration order, top
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
    /// in `DetailSummaryView` so this refactor is observably equivalent,
    /// PLUS the Host row now resolves via memberLookup when metadata
    /// only carries the host_id (which is the case for events_view —
    /// the legacy projection that doesn't denormalize the host name).
    public static let v1: SummaryFieldCatalog = SummaryFieldCatalog(
        fieldsByResourceType: [
            .event: [
                SummaryFieldDescriptor(
                    id: "host",
                    icon: "star.fill",
                    label: "Host",
                    // Three-step fallback so the row renders regardless
                    // of which projection ships the resource:
                    //   1. metadata.host_name / hostName  (forward-compat
                    //      for a future events_view that denormalizes
                    //      the host display string)
                    //   2. metadata.host_id  → memberLookup            (V1 path:
                    //      events_view carries host_id only)
                    resolver: .derived { ctx in
                        if case .string(let s)? = ctx.metadata["host_name"], !s.isEmpty { return s }
                        if case .string(let s)? = ctx.metadata["hostName"], !s.isEmpty { return s }
                        if case .string(let idStr)? = ctx.metadata["host_id"],
                           let uuid = UUID(uuidString: idStr),
                           let name = ctx.memberLookup(uuid) {
                            return name
                        }
                        return nil
                    }
                ),
                SummaryFieldDescriptor(
                    id: "location",
                    icon: "mappin.and.ellipse",
                    label: "Lugar",
                    resolver: .metadataKeys(
                        keys: ["location_name", "locationName"],
                        format: .string
                    )
                ),
                SummaryFieldDescriptor(
                    id: "capacity",
                    icon: "person.3.fill",
                    label: "Capacidad",
                    resolver: .metadataKeys(
                        keys: ["capacity_max", "capacityMax"],
                        format: .intWithUnit(unit: "persona", unitPlural: "personas")
                    )
                ),
            ],
            .asset: [
                SummaryFieldDescriptor(
                    id: "owners",
                    icon: "person.2.fill",
                    label: "Dueños",
                    resolver: .metadataKeys(
                        keys: ["owners_count", "ownersCount"],
                        format: .intCount
                    )
                ),
                SummaryFieldDescriptor(
                    id: "capacity",
                    icon: "person.3.fill",
                    label: "Capacidad",
                    resolver: .metadataKeys(keys: ["capacity"], format: .string)
                ),
            ],
            .fund: [
                SummaryFieldDescriptor(
                    id: "balance",
                    icon: "banknote",
                    label: "Saldo",
                    resolver: .metadataKeys(
                        keys: ["balance_cents", "balanceCents"],
                        format: .currencyCents(code: "MXN")
                    )
                ),
            ],
            .slot: [
                SummaryFieldDescriptor(
                    id: "capacity",
                    icon: "person.3.fill",
                    label: "Capacidad",
                    resolver: .metadataKeys(keys: ["capacity"], format: .intCount)
                ),
            ],
        ]
    )
}
