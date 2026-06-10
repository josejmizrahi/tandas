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
/// AllAttentionView, futura R.5Y AttentionCenter, R.6 Rule Engine) **DEBE** usar
/// este dispatcher. PROHIBIDO duplicar switches por kind en pantallas.
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
    /// R.5Z.fix.CC.2 — context-scoped destination. Usado por items con
    /// `cta_scope_kind=context` (rule_violation, policy_violation, recordatorios
    /// genéricos del contexto). `contextDisplayName` permite construir un
    /// AppContext mínimo cuando el lookup en `availableContexts` falla (race
    /// condition contextStore loading o context not en candidates aún).
    case context(contextActorId: UUID, contextDisplayName: String)
    /// R.5Z.fix.CC.2.2 — money-transaction scope. Push a MoneyHomeView del
    /// contexto (lista de gastos + obligaciones). Usado para items emitidos
    /// por reglas sobre expense.recorded / payment.recorded etc.
    case money(contextActorId: UUID, contextDisplayName: String)
    /// R.5Z.fix.EVENT.HOST_CONFIRM — event scope. Push a EventDetailView.
    /// Usado por `event_confirmation_by_host` y futuros items event-scoped.
    case event(eventId: UUID, contextActorId: UUID, contextDisplayName: String)
    /// Kind no soportado por iOS aún. Render UX honesto, no crash.
    case unsupported(kind: String)

    public var id: String {
        switch self {
        case .decision(let id, _):                      return "decision-\(id)"
        case .obligation(let id, _):                    return "obligation-\(id)"
        case .settlement(let ctx, let item):            return "settlement-\(ctx)-\(item?.uuidString ?? "_")"
        case .resourceDetail(let id, _):                return "resource-\(id)"
        case .reservationConflict(let id, _, _):        return "reservation-conflict-\(id)"
        case .pendingInvitations:                       return "pending-invitations"
        case .context(let ctx, _):                      return "context-\(ctx)"
        case .money(let ctx, _):                        return "money-\(ctx)"
        case .event(let id, _, _):                      return "event-\(id)"
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
            // R.5Z.fix.CC.2 (founder 2026-06-09) — fallback genérico por
            // `cta_scope_kind` antes de caer a `.unsupported`. Hace al dispatcher
            // forward-compatible con kinds nuevos de R.6 (rule_violation,
            // policy_violation, etc.) siempre que usen scope_kinds canónicos.
            return scopeBasedDestination(for: item)
        }
    }

    /// R.5Z.fix.CC.2 — mapea `cta_scope_kind` a destination cuando el kind no
    /// tiene case dedicado. Cubre items dinámicos R.6.
    private static func scopeBasedDestination(for item: AttentionItem) -> AttentionDestination {
        switch item.ctaScopeKind {
        case "context":
            return .context(contextActorId: item.contextActorId, contextDisplayName: item.contextDisplayName)
        case "resource":
            return .resourceDetail(resourceId: item.ctaScopeId, contextActorId: item.contextActorId)
        case "obligation":
            return .obligation(obligationId: item.ctaScopeId, contextActorId: item.contextActorId)
        case "decision":
            return .decision(decisionId: item.ctaScopeId, contextActorId: item.contextActorId)
        case "money_transaction":
            // R.5Z.fix.CC.2.2 — items sobre gastos/payments individuales pushean
            // a la lista de movimientos del contexto.
            return .money(contextActorId: item.contextActorId, contextDisplayName: item.contextDisplayName)
        case "event":
            // R.5Z.fix.EVENT.HOST_CONFIRM — items sobre eventos (e.g.,
            // event_confirmation_by_host) pushean al EventDetailView para
            // que el participant pueda confirmar/cambiar RSVP.
            return .event(eventId: item.ctaScopeId, contextActorId: item.contextActorId, contextDisplayName: item.contextDisplayName)
        default:
            return .unsupported(kind: item.kind)
        }
    }
}

// MARK: - Presentation helpers (mata duplicación de symbol/tint/cta entre vistas)

/// R.5Y.A2 — Helpers visuales para listar items. Unifica los conjuntos de
/// funciones de presentación que antes vivían duplicados en cada vista.
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
        // R.5Z.fix.CC.2 — R.6.A rule-emitted kinds.
        case "rule_violation":          return "exclamationmark.shield.fill"
        case "rule_recommendation":     return "lightbulb.fill"
        case "policy_violation":        return "exclamationmark.shield.fill"
        // R.5Z.fix.EVENT.HOST_CONFIRM
        case "event_confirmation_by_host": return "calendar.badge.checkmark"
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
        // R.5Z.fix.CC.2 — R.6.A rule-emitted kinds.
        case "rule_violation",
             "policy_violation":          return .orange
        case "rule_recommendation":       return .yellow
        // R.5Z.fix.EVENT.HOST_CONFIRM
        case "event_confirmation_by_host": return .purple
        default:                          return .gray
        }
    }

    /// R.5Z.fix.CC.2.3 — `true` si el kind viene de `rule_attention_items`
    /// (tabla con status mutable). Los demás kinds (obligation_pay/decision_vote/
    /// settlement_open/etc.) son derivados runtime de las tablas operacionales y
    /// se cierran cuando la acción subyacente se completa — no admiten dismiss
    /// manual.
    public static func isDismissable(kind: String) -> Bool {
        switch kind {
        case "rule_violation",
             "rule_recommendation",
             "policy_violation":
            return true
        default:
            return false
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
        // R.5Z.fix.CC.2 — R.6.A rule-emitted kinds.
        case "rule_violation",
             "policy_violation":         return "Ver detalles"
        case "rule_recommendation":      return "Ver sugerencia"
        // R.5Z.fix.EVENT.HOST_CONFIRM
        case "event_confirmation_by_host": return "Confirmar o cambiar"
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
        case .context(let contextActorId, let contextDisplayName):
            // R.5Z.fix.CC.2 — push ContextDetailViewV2 dentro de NavigationStack
            // del sheet. Para items con cta_scope_kind=context (rule_violation, etc.).
            // Con fallback build-from-displayName si el lookup en
            // availableContexts falla (race condition contextStore.load).
            wrapped(contextActorId: contextActorId, fallbackDisplayName: contextDisplayName) { ctx in
                ContextDetailViewV2(contextId: ctx.id, context: ctx, container: container)
            }
        case .money(let contextActorId, let contextDisplayName):
            // R.5Z.fix.CC.2.2 — push MoneyHomeView (lista de gastos +
            // obligaciones del contexto). iOS no tiene detail view de
            // transacción individual; MoneyHomeView es lo más cercano a "la acción".
            wrapped(contextActorId: contextActorId, fallbackDisplayName: contextDisplayName) { ctx in
                MoneyHomeView(context: ctx, container: container)
            }
        case .event(let eventId, let contextActorId, let contextDisplayName):
            // R.5Z.fix.EVENT.HOST_CONFIRM — push EventDetailView.
            wrapped(contextActorId: contextActorId, fallbackDisplayName: contextDisplayName) { ctx in
                EventDetailView(eventId: eventId, context: ctx, container: container)
            }
        case .unsupported(let kind):
            UnsupportedAttentionView(kind: kind)
        }
    }

    @ViewBuilder
    private func wrapped<Content: View>(
        contextActorId: UUID,
        fallbackDisplayName: String? = nil,
        @ViewBuilder _ build: (AppContext) -> Content
    ) -> some View {
        // R.5Z.fix.CC.2 — primero busca en availableContexts (rápido y con
        // memberCount/roles correctos). Si falla, construye un AppContext
        // mínimo desde el fallback (e.g. nombre del attention item). El detail
        // view internamente carga el descriptor del backend; lo único crítico
        // del AppContext es id, kind, displayName.
        let resolved: AppContext? = {
            if let ctx = container.contextStore.availableContexts.first(where: { $0.id == contextActorId }) {
                return ctx
            }
            if let name = fallbackDisplayName {
                return AppContext(
                    id: contextActorId,
                    kind: .collective,
                    subtype: "collective",
                    displayName: name
                )
            }
            return nil
        }()
        if let ctx = resolved {
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
                RuulLoadingState()
            case .failed(let message):
                RuulErrorState(message: message) { Task { await load() } }
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
