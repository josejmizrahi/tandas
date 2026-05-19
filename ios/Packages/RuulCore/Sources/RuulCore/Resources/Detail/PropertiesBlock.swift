import Foundation

/// Properties layer payload. 4-7 facts max per doctrine §4.
/// More than 7 → push the overflow into its own capability block.
public struct PropertiesBlock: Sendable, Hashable {
    public let rows: [FactRow]
    public init(rows: [FactRow]) {
        self.rows = rows
    }
}

/// One key/value pair. Both sides are pre-formatted strings — the
/// renderer does NOT format dates, currency, etc. Builders do that
/// so the resolver/renderer stay locale-aware via the builder layer.
public struct FactRow: Sendable, Hashable, Identifiable {
    public let id: String   // stable for diffing (e.g. "starts_at", "host")
    public let key: String  // "Cuándo"
    public let value: String // "Mañana · 20:00"
    public init(id: String, key: String, value: String) {
        self.id = id; self.key = key; self.value = value
    }
}
