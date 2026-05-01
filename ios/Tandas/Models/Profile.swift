import Foundation

struct Profile: Identifiable, Codable, Sendable, Hashable {
    let id: UUID
    var displayName: String
    var avatarUrl: String?
    var phone: String?

    var needsOnboarding: Bool { displayName.trimmingCharacters(in: .whitespaces).isEmpty }
}
