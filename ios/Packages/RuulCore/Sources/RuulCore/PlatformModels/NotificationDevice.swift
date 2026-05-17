import Foundation

/// One row from `notification_tokens` projected as a user-facing device.
public struct NotificationDevice: Identifiable, Sendable, Hashable, Codable {
    public let id: UUID
    public let userId: UUID
    public let token: String
    public let platform: String
    public let createdAt: Date
    public let updatedAt: Date

    public enum CodingKeys: String, CodingKey {
        case id, token, platform
        case userId    = "user_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    /// Masked representation for display (first 8 + last 4).
    public var tokenMasked: String {
        guard token.count > 12 else { return "•••" }
        return "\(token.prefix(8))…\(token.suffix(4))"
    }
}
