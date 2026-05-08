import Foundation
import RuulCore

/// Acción que un host puede ejecutar contra un resource. Producida por
/// un `ResourceActionsProvider`, consumida por `ResourceActionsSection`
/// (Sub-fase D). Diseñada como data + closure: el provider arma la lista,
/// la view la renderiza.
///
/// **Retain cycle warning**: `onTap` captura coordinator/services
/// lexicalmente. Cuando el provider construye la action, el closure
/// debe ser `[weak coordinator] in await coordinator?.foo()` — el
/// coordinator es @Observable (reference type) y guardarlo strong
/// dentro del closure crea ciclo. Patrón obligado en Sub-fase D.
///
/// **`governanceAction` role en V1**: metadata only. El provider ya
/// filtró las actions disponibles según governance antes de emitirlas;
/// este field documenta a qué permission key corresponde la action
/// (útil para analytics, logs y futuro re-check). V1 NO re-chequea
/// en `onTap`. Sub-fase D puede expandir a defense-in-depth con UI
/// fallback ("La gobernanza cambió, refrescá") si decide.
struct ResourceAction: Identifiable, Sendable {
    let id: String
    let icon: String
    let title: String
    let subtitle: String?
    let isDestructive: Bool
    let governanceAction: GovernanceAction
    let onTap: @Sendable () async -> Void

    init(
        id: String,
        icon: String,
        title: String,
        subtitle: String? = nil,
        isDestructive: Bool = false,
        governanceAction: GovernanceAction,
        onTap: @escaping @Sendable () async -> Void
    ) {
        self.id = id
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.isDestructive = isDestructive
        self.governanceAction = governanceAction
        self.onTap = onTap
    }
}
