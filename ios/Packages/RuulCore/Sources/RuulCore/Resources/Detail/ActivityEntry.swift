import Foundation

/// One row in the inline activity feed at the bottom of every
/// UniversalResourceDetailView. Builders synthesize these from
/// `system_events` rows — the feed never reads SQL directly.
public struct ActivityEntry: Sendable, Hashable, Identifiable {
    public let id: UUID
    /// One human sentence: "Ana fue asignada como anfitriona".
    public let sentence: String
    /// Relative time: "hace 2h", "4 mar".
    public let relativeTime: String
    /// Optional SF Symbol for the leading icon.
    public let icon: String?
    public init(id: UUID, sentence: String, relativeTime: String, icon: String?) {
        self.id = id; self.sentence = sentence
        self.relativeTime = relativeTime; self.icon = icon
    }
}
