import SwiftUI
import RuulCore

/// R.5Y.A2 — Único punto de navegación para cualquier `AttentionItem` presente o futuro.
///
/// Doctrina founder-signed (2026-06-07):
/// > "El usuario piensa '¿qué requiere mi atención?', no '¿qué requiere atención dentro
/// > de este contexto?'. AttentionDispatcher debe ser el único punto de navegación para
/// > cualquier attention item presente o futuro."
///
/// Cualquier vista que muestra items de atención (HomeView, ContextDetailViewV2,
/// ContextHomeView, AllAttentionView, futura R.5Y AttentionCenter, R.6 Rule Engine)
/// **DEBE** usar este dispatcher. PROHIBIDO duplicar switches por kind en pantallas.
///
/// Para agregar un kind nuevo: extender `AttentionDestination`, agregar caso en
/// `AttentionDispatcher.destination(for:container:)` + en `AttentionDestinationSheet.body`,
/// y opcionalmente registrar presentación en `AttentionPresentation`.
public enum AttentionDestination: Identifiable, Hashable {
    case decision(decisionId: UUID, contextActorId: UUID)
    case obligation(obligationId: UUID, contextActorId: UUID)
    case settlement(contextActorId: UUID, highlightItemId: UUID?)
    case resourceDetail(resourceId: UUID, contextActorId: UUID)
    case reservationConflict(conflictId: UUID, resourceId: UUID, contextActorId: UUID)
    case pendingInvitations
    /// Kind no soportado por iOS aún (e.g., R.6 va a emitir `rule_violation` antes de
    /// que iOS tenga el dispatcher correspondiente). Render UX honesto, no crash.
    case unsupported(kind: String)

    public var id: String {
        switch self {
        case .decision(let id, _):                      return "decision-\(id)"
        case .obligation(let id, _):                    return "obligation-\(id)"
        case .settlement(let ctx, let item):            return "settlement-\(ctx)-\(item?.uuidString ?? "_")"
        case .resourceDetail(let id, _):                return "resource-\(id)"
        case .reservationConflict(let id, _, _):        return "reservation-conflict-\(id)"
        case .pendingInvitations:                       return "pending-invitations"
        case .unsupported(let kind):                    return "unsupported-\(kind)"
        }
    }
}

public enum AttentionDispatcher {
    /// Resuelve `item.kind` + payload → `AttentionDestination`. Si el item carece
    /// de los UUIDs necesarios, cae a `.unsupported`.
    public static func destination(for item: AttentionItem) -> AttentionDestination {
        switch item.kind {
        case "decision_vote":
            return .decision(decisionId: item.ctaScopeId, contextActorId: item.contextActorId)
        case "governance_pending":
            // R.7.G — proponente espera aprobación. ctaScopeId=decision_id desde backend.
            return .decision(decisionId: item.ctaScopeId, contextActorId: item.contextActorId)
        case "obligation_pay", "obligation_complete":
            return .obligation(obligationId: item.ctaScopeId, contextActorId: item.contextActorId)
        case "settlement_open":
            // ctaScopeId = settlement_item.id (para highlight futuro)
            return .settlement(contextActorId: item.contextActorId, highlightItemId: item.ctaScopeId)
        case "resource_conflict_direct":
            // ctaScopeId = resource_id (R.5Y.A1 emit). conflictsCard del Resource V2
            // cubre la resolución (R.5B.5b 3-kind dialog).
            return .resourceDetail(resourceId: item.ctaScopeId, contextActorId: item.contextActorId)
        case "reservation_conflict":
            // subject_id = reservation_conflict.id · resource_id top-level (R.5Y.A1.2)
            // permite cargar ReservationConflictView con el conflict + resource.
            guard let resourceId = item.resourceId else {
                return .unsupported(kind: item.kind)
            }
            return .reservationConflict(
                conflictId: item.subjectId,
                resourceId: resourceId,
                contextActorId: item.contextActorId
            )
        case "invitation":
            return .pendingInvitations
        default:
            return .unsupported(kind: item.kind)
        }
    }
}

// MARK: - Presentation helpers (mata duplicación de symbol/tint/cta entre vistas)

/// R.5Y.A2 — Helpers visuales para listar items. Unifica los tres conjuntos de
/// funciones duplicadas que vivían en HomeView/ContextDetailViewV2/ContextHomeView.
public enum AttentionPresentation {
    public static func symbol(for kind: String) -> String {
        switch kind {
        case "reservation_conflict":    return "exclamationmark.triangle.fill"
        case "resource_conflict_direct": return "exclamationmark.octagon.fill"
        case "decision_vote":           return "hand.thumbsup.fill"
        case "governance_pending":      return "person.crop.circle.badge.questionmark"
        case "obligation_pay":          return "creditcard.fill"
        case "obligation_complete":     return "checkmark.circle"
        case "settlement_open":         return "banknote.fill"
        case "invitation":              return "envelope.fill"
        default:                        return "circle.fill"
        }
    }

    public static func tint(for kind: String) -> Color {
        switch kind {
        case "reservation_conflict",
             "resource_conflict_direct":  return .red
        case "decision_vote":             return .purple
        case "governance_pending":        return .orange
        case "obligation_pay",
             "settlement_open":           return .green
        case "obligation_complete":       return .indigo
        case "invitation":                return .blue
        default:                          return .gray
        }
    }

    public static func ctaLabel(for kind: String) -> String {
        switch kind {
        case "reservation_conflict":     return "Resolver conflicto"
        case "resource_conflict_direct": return "Revisar recurso"
        case "decision_vote":            return "Votar"
        case "governance_pending":       return "Ver decisión"
        case "obligation_pay":           return "Pagar"
        case "obligation_complete":      return "Marcar completado"
        case "settlement_open":          return "Marcar pagado"
        case "invitation":               return "Aceptar invitación"
        default:                         return "Ver"
        }
    }
}

// MARK: - Sheet render

/// R.5Y.A2 — Sheet que renderiza un `AttentionDestination`. Único entry point de
/// presentación. Las vistas consumidoras usan:
///
/// ```swift
/// @State private var presentedAttention: AttentionDestination?
/// ...
/// .sheet(item: $presentedAttention) { dest in
///     AttentionDestinationSheet(destination: dest, container: container)
/// }
/// ```
public struct AttentionDestinationSheet: View {
    let destination: AttentionDestination
    let container: DependencyContainer

    public init(destination: AttentionDestination, container: DependencyContainer) {
        self.destination = destination
        self.container = container
    }

    public var body: some View {
        switch destination {
        case .decision(let decisionId, let contextActorId):
            wrapped(contextActorId: contextActorId) { ctx in
                DecisionDetailView(decisionId: decisionId, context: ctx, container: container)
            }
        case .obligation(let obligationId, let contextActorId):
            wrapped(contextActorId: contextActorId) { ctx in
                ObligationDetailView(obligationId: obligationId, context: ctx, container: container)
            }
        case .settlement(let contextActorId, _):
            wrapped(contextActorId: contextActorId) { ctx in
                SettlementView(context: ctx, container: container)
            }
        case .resourceDetail(let resourceId, let contextActorId):
            wrapped(contextActorId: contextActorId) { ctx in
                ResourceDetailViewV2(resourceId: resourceId, context: ctx, container: container)
            }
        case .reservationConflict(let conflictId, let resourceId, let contextActorId):
            wrapped(contextActorId: contextActorId) { ctx in
                ReservationConflictBootstrap(
                    conflictId: conflictId,
                    resourceId: resourceId,
                    context: ctx,
                    container: container
                )
            }
        case .pendingInvitations:
            PendingInvitationsView(container: container)
        case .unsupported(let kind):
            UnsupportedAttentionView(kind: kind)
        }
    }

    @ViewBuilder
    private func wrapped<Content: View>(
        contextActorId: UUID,
        @ViewBuilder _ build: (AppContext) -> Content
    ) -> some View {
        if let ctx = container.contextStore.availableContexts.first(where: { $0.id == contextActorId }) {
            NavigationStack {
                build(ctx)
            }
        } else {
            UnsupportedAttentionView(kind: "context_not_found")
        }
    }
}

// MARK: - Reservation conflict bootstrap

/// R.5Y.A2 — Carga el `ReservationConflict` + lista de reservaciones del recurso
/// antes de renderizar `ReservationConflictView`. Necesario porque
/// `ReservationConflictView` requiere `(conflict, resource, context, store)`.
private struct ReservationConflictBootstrap: View {
    let conflictId: UUID
    let resourceId: UUID
    let context: AppContext
    let container: DependencyContainer

    @State private var phase: StorePhase = .idle
    @State private var conflict: ReservationConflict?
    @State private var resource: Resource?
    @State private var store: ReservationsStore?

    var body: some View {
        Group {
            switch phase {
            case .idle, .loading:
                LoadingStateView()
            case .failed(let message):
                ErrorStateView(message: message) { Task { await load() } }
            case .loaded:
                if let conflict, let resource, let store {
                    ReservationConflictView(
                        conflict: conflict,
                        resource: resource,
                        context: context,
                        store: store,
                        container: container
                    )
                } else {
                    UnsupportedAttentionView(kind: "reservation_conflict_unavailable")
                }
            }
        }
        .navigationTitle("Conflicto de reservación")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        phase = .loading
        do {
            let newStore = ReservationsStore(
                rpc: container.rpc,
                myActorId: container.currentActorStore.actorId
            )
            await newStore.load(resourceId: resourceId, context: context)
            let conflicts = try await container.rpc.listConflicts(resourceId: resourceId)
            guard let match = conflicts.first(where: { $0.id == conflictId }) else {
                phase = .failed(message: "El conflicto ya no está abierto.")
                return
            }
            let resources = try await container.rpc.listContextResources(contextId: context.id)
            guard let res = resources.first(where: { $0.resourceId == resourceId }) else {
                phase = .failed(message: "No se encontró el recurso.")
                return
            }
            self.conflict = match
            self.resource = Resource(
                id: res.resourceId,
                resourceType: res.resourceType,
                displayName: res.displayName,
                status: res.status,
                estimatedValue: res.estimatedValue,
                currency: res.currency,
                canonicalOwnerActorId: res.canonicalOwnerActorId
            )
            self.store = newStore
            phase = .loaded
        } catch {
            phase = .failed(message: UserFacingError.from(error).message)
        }
    }
}

// MARK: - Unsupported fallback

/// R.5Y.A2 — UX honesto cuando el dispatcher no sabe abrir un kind (e.g., R.6 va a
/// emitir `rule_violation` antes de que iOS lo cubra). NO crashea, NO desaparece.
private struct UnsupportedAttentionView: View {
    let kind: String

    var body: some View {
        ContentUnavailableView(
            "Próximamente",
            systemImage: "sparkles",
            description: Text("Esta funcionalidad ya está modelada en Ruul, pero todavía no está disponible.")
        )
    }
}
