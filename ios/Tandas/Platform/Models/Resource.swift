import Foundation

/// Generic platform resource — anything a group interacts with. The `events`
/// table is the V1 implementation; future templates introduce slots, funds,
/// positions, assets, contributions.
///
/// In Sprint 1a the Swift code path still reads concrete `Event` rows; this
/// protocol exists so the upcoming `ResourceRepository` and edge-function
/// rule engine speak a common shape.
public protocol Resource: Identifiable, Sendable, Codable {
    var id: UUID { get }
    var groupId: UUID { get }
    var resourceType: ResourceType { get }
    var status: String { get }
    var createdAt: Date { get }
    var updatedAt: Date { get }
}
