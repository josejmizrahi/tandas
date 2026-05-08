import Foundation
import RuulCore

/// Estrategia para producir acciones contra un resource. Cada concrete
/// resource type tiene su provider (V1: `EventActionsProvider`, deferido
/// a Sub-fase D). El provider conoce las reglas de governance + el
/// estado del resource y decide qué acciones están disponibles.
///
/// **Associatedtype no existential**: `R: Resource` permite que el
/// provider concreto reciba el type ya tipado, sin `as!` interno.
/// Trade-off: consumers no pueden tener `[any ResourceActionsProvider]`.
/// V1 no lo necesita — cada resource type tiene su provider concreto
/// inyectado donde corresponde, accedido por switch en `resource.resourceType`.
public protocol ResourceActionsProvider: Sendable {
    associatedtype R: Resource

    func actions(
        for resource: R,
        member: Member,
        in group: Group
    ) async -> [ResourceAction]
}
