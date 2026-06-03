import Foundation

// MARK: - Postgres timestamps

/// Postgres serializa `timestamptz` dentro de jsonb (y PostgREST en respuestas
/// de tabla) como ISO8601 **con microsegundos**: `2026-06-03T18:15:30.123456+00:00`.
/// El strategy `.iso8601` de Foundation no parsea fracciones de segundo, así que
/// todo el decoding de RuulCore pasa por este parser tolerante.
public enum PostgresTimestamp {
    /// `ISO8601DateFormatter` está documentado como thread-safe; solo le falta
    /// la anotación `Sendable` en el SDK.
    nonisolated(unsafe) private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public static func parse(_ string: String) -> Date? {
        withFraction.date(from: string) ?? plain.date(from: string)
    }

    public static func format(_ date: Date) -> String {
        withFraction.string(from: date)
    }
}

// MARK: - Decoder / Encoder

public extension JSONDecoder {
    /// Decoder canónico de RuulCore: fechas tolerantes (con/sin microsegundos).
    /// Los modelos usan CodingKeys explícitos en snake_case — NO usar
    /// `convertFromSnakeCase` (colisiona con los raw values).
    static var ruul: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            guard let date = PostgresTimestamp.parse(raw) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Fecha no reconocida: \(raw)"
                )
            }
            return date
        }
        return decoder
    }
}

public extension JSONEncoder {
    /// Encoder canónico: fechas en ISO8601 con fracciones (Postgres las parsea).
    static var ruul: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(PostgresTimestamp.format(date))
        }
        return encoder
    }
}

// MARK: - JSONValue

/// Contenedor mínimo para valores jsonb arbitrarios (metadata, payload,
/// condition_tree, consequences). Codable en ambas direcciones.
public indirect enum JSONValue: Codable, Sendable, Equatable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b):   try c.encode(b)
        case .array(let a):  try c.encode(a)
        case .object(let o): try c.encode(o)
        case .null:          try c.encodeNil()
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let n = try? c.decode(Double.self) { self = .number(n); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Valor jsonb no soportado")
    }
}

public extension JSONValue {
    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var numberValue: Double? {
        switch self {
        case .number(let n): return n
        case .string(let s): return Double(s)
        default: return nil
        }
    }

    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }
}
