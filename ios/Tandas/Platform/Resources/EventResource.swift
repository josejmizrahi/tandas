import Foundation

/// Wrapper de `Event` que conforma a `ResourceProtocol` (UI dispatch).
/// V1: el único concrete resource shippeado. Cuando llegue Slot/Fund,
/// vivirán como hermanos en este directorio.
///
/// Por qué wrapper y no extension: `Event` no debería conocer la capa
/// de UI. El wrapper es la traducción explícita — si mañana cambia el
/// shape de `ResourceProtocol`, solo este archivo se actualiza.
///
/// Invariante: `EventResource` es el único conformer de `ResourceProtocol`
/// con `resourceType == .event` en V1. Bodies concretos pueden hacer
/// `(resource as! EventResource)` con seguridad dentro del case `.event`.
struct EventResource: ResourceProtocol {
    let event: Event

    init(_ event: Event) { self.event = event }

    var id: UUID { event.id }
    var groupId: UUID { event.groupId }
    var resourceType: ResourceType { .event }
}
