import Foundation

enum ViewState<T: Sendable>: Sendable {
    case idle
    case loading
    case loaded(T)
    case empty
    case error(String)
}

extension JSONDecoder {
    /// Models with snake_case columns (Profile, Member, Group, etc.) use
    /// explicit CodingKeys with snake_case raw values. Don't use
    /// `convertFromSnakeCase` here — that strategy collides with the
    /// CodingKey raw values and breaks decoding.
    static let tandas: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

extension JSONEncoder {
    static let tandas: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}
