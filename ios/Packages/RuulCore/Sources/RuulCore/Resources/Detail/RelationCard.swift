import Foundation

/// One card on the Relations rail. Tapping it pushes the related
/// resource's own UniversalResourceDetailView — recursion works
/// because the model is universal.
public struct RelationCard: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let icon: String
    public let tint: ResourceFamilyTint
    public let label: String        // "Acuerdo", "Fondo"
    public let statusLine: String?  // "Firmado", "$4,3k", "Open"
    /// Deep link id the host resolves to a navigation push.
    public let deepLink: String
    public init(
        id: UUID, icon: String, tint: ResourceFamilyTint,
        label: String, statusLine: String?, deepLink: String
    ) {
        self.id = id; self.icon = icon; self.tint = tint
        self.label = label; self.statusLine = statusLine
        self.deepLink = deepLink
    }
}
