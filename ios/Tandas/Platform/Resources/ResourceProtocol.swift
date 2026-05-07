import Foundation

/// UI-layer protocol — habilita dispatch genérico de resources en views,
/// containers y providers. Distinta de `Platform/Models/Resource.swift`
/// (data-layer protocol con Codable + status + timestamps).
///
/// Mantener minimal: si tu vista necesita un campo type-specific, accedé
/// al concrete type via cast en el branch correspondiente del switch.
/// El invariante es: `resource.resourceType == .event ⇒ resource is EventResource`.
public protocol ResourceProtocol: Identifiable, Sendable {
    var id: UUID { get }
    var groupId: UUID { get }
    var resourceType: ResourceType { get }
}
