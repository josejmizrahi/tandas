import Foundation

/// Loosely-typed JSON envelope used by RuleTrigger / RuleCondition /
/// RuleConsequence configs. Stored as `jsonb` on Postgres.
///
/// Values are limited to JSON-safe primitives + recursive object/array
/// nesting. Round-trips through `JSONEncoder` / `JSONDecoder` without
/// information loss for `String`, `Int`, `Double`, `Bool`, `null`,
/// `[JSONConfig]`, `[String: JSONConfig]`.
public enum JSONConfig: Sendable, Hashable, Codable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONConfig])
    case object([String: JSONConfig])

    public static let empty: JSONConfig = .object([:])

    // MARK: - Convenience accessors

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var intValue: Int? {
        switch self {
        case .int(let i):    return i
        case .double(let d): return Int(d)
        case .string(let s): return Int(s)
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .double(let d): return d
        case .int(let i):    return Double(i)
        case .string(let s): return Double(s)
        default: return nil
        }
    }

    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public subscript(key: String) -> JSONConfig? {
        if case .object(let dict) = self { return dict[key] }
        return nil
    }

    // MARK: - Codable

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? c.decode(Int.self) {
            self = .int(i)
        } else if let d = try? c.decode(Double.self) {
            self = .double(d)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONConfig].self) {
            self = .array(a)
        } else if let o = try? c.decode([String: JSONConfig].self) {
            self = .object(o)
        } else {
            throw DecodingError.typeMismatch(
                JSONConfig.self,
                .init(codingPath: decoder.codingPath, debugDescription: "Unsupported JSON type")
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null:           try c.encodeNil()
        case .bool(let b):    try c.encode(b)
        case .int(let i):     try c.encode(i)
        case .double(let d):  try c.encode(d)
        case .string(let s):  try c.encode(s)
        case .array(let a):   try c.encode(a)
        case .object(let o):  try c.encode(o)
        }
    }
}
