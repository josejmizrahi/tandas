import Foundation

/// V2-G9 — `metadata.weight_strategy` jsonb on `group_decisions`. Only
/// the `manual` kind is consumed in V2; `role` + `contribution` are
/// reserved for future sub-slices and decode tolerantly.
public struct WeightStrategy: Codable, Equatable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, Hashable {
        case manual
        case role
        case contribution
    }

    public let kind: Kind
    public let maxWeight: Decimal

    public static let defaultMaxWeight: Decimal = 10

    public init(kind: Kind = .manual, maxWeight: Decimal = WeightStrategy.defaultMaxWeight) {
        self.kind = kind
        self.maxWeight = maxWeight
    }

    enum CodingKeys: String, CodingKey { case kind, config }
    enum ConfigKeys: String, CodingKey { case maxWeight = "max_weight" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawKind = (try? c.decode(String.self, forKey: .kind)) ?? Kind.manual.rawValue
        self.kind = Kind(rawValue: rawKind) ?? .manual
        if let config = try? c.nestedContainer(keyedBy: ConfigKeys.self, forKey: .config),
           let mw = try? config.decode(Decimal.self, forKey: .maxWeight) {
            self.maxWeight = mw
        } else {
            self.maxWeight = WeightStrategy.defaultMaxWeight
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind.rawValue, forKey: .kind)
        var config = c.nestedContainer(keyedBy: ConfigKeys.self, forKey: .config)
        try config.encode(maxWeight, forKey: .maxWeight)
    }
}
