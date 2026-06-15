import Foundation
import RuulCore

/// F.2X — Objeto sobre el cual una acción se ejecuta.
public enum ActionScope: Sendable, Equatable, Hashable {
    case context(UUID)
    case resource(UUID)
    case event(UUID)
    case decision(UUID)
    case reservation(UUID)
    case obligation(UUID)

    public var idValue: UUID {
        switch self {
        case .context(let id), .resource(let id), .event(let id),
             .decision(let id), .reservation(let id), .obligation(let id): return id
        }
    }

    public var label: String {
        switch self {
        case .context:     return "espacio"
        case .resource:    return "recurso"
        case .event:       return "evento"
        case .decision:    return "decisión"
        case .reservation: return "reservación"
        case .obligation:  return "obligación"
        }
    }
}

/// F.2X — Destino canónico de una Quick Action. Se construye con
/// `action_key` y `scope`; el flow real lo decide el handler.
///
/// Skeleton F.2X.1: el destino es simplemente un par `(actionKey, scope)`.
/// F.2X.2+ extenderá con flows específicos cuando ContextHome/ResourceDetail/
/// EventDetail wiren las acciones reales.
public struct ActionDestination: Sendable, Equatable, Hashable {
    public let actionKey: String
    public let scope: ActionScope

    public init(actionKey: String, scope: ActionScope) {
        self.actionKey = actionKey
        self.scope = scope
    }

    /// Intent humano para debugging/previews. Devuelve algo como
    /// "→ CreateResourceFlow(context: …)" — no es UX visible.
    public var debugIntent: String {
        switch (scope, actionKey) {
        case let (.context(id), "create_resource"):      return "→ CreateResourceFlow(context: \(id))"
        case let (.context(id), "create_event"):         return "→ CreateEventFlow(context: \(id))"
        case let (.context(id), "create_decision"):      return "→ CreateDecisionFlow(context: \(id))"
        case let (.context(id), "record_expense"):       return "→ RecordExpenseFlow(context: \(id))"
        case let (.context(id), "invite_member"):        return "→ InviteMembersFlow(context: \(id))"
        case let (.context(id), "create_rule"):          return "→ CreateRuleWizard(context: \(id))"
        case let (.context(id), "create_child_context"): return "→ CreateChildContextSheet(parent: \(id))"

        case let (.event(id), "rsvp_event"):             return "→ RSVPSheet(event: \(id))"
        case let (.event(id), "check_in_participant"):   return "→ CheckInSheet(event: \(id))"
        case let (.event(id), "cancel_participation"):   return "→ CancelParticipationSheet(event: \(id))"
        case let (.event(id), "close_event"):            return "→ CloseEventSheet(event: \(id))"
        case let (.event(id), "record_expense"):         return "→ RecordExpenseFlow(fromEvent: \(id))"
        case let (.event(id), "create_decision"):        return "→ CreateDecisionFlow(fromEvent: \(id))"
        case let (.event(id), "attach_document"):        return "→ AttachDocumentView(event: \(id))"

        case let (.resource(id), "reserve_resource"):    return "→ RequestReservationView(resource: \(id))"
        case let (.resource(id), "view_beneficiaries"):  return "→ ResourceBeneficiariesView(resource: \(id))"
        case let (.resource(id), "view_ownership"):      return "→ ResourceOwnershipView(resource: \(id))"
        case let (.resource(id), "attach_document"):     return "→ AttachDocumentView(resource: \(id))"

        case let (.decision(id), "vote"):                return "→ VoteSheet(decision: \(id))"
        case let (.decision(id), "change_vote"):         return "→ VoteSheet(decision: \(id))"
        case let (.decision(id), "close_decision"):      return "→ CloseDecisionSheet(decision: \(id))"
        case let (.decision(id), "cancel_decision"):     return "→ CancelDecisionSheet(decision: \(id))"
        case let (.decision(id), "execute_decision"):    return "→ ExecuteDecisionSheet(decision: \(id))"

        case let (.reservation(id), "approve"):          return "→ ApproveReservation(reservation: \(id))"
        case let (.reservation(id), "reject"):           return "→ RejectReservation(reservation: \(id))"
        case let (.reservation(id), "confirm"):          return "→ ConfirmReservation(reservation: \(id))"
        case let (.reservation(id), "cancel"):           return "→ CancelReservation(reservation: \(id))"
        case let (.reservation(id), "resolve_conflict"): return "→ ReservationConflictView(reservation: \(id))"

        case let (.obligation(id), "pay"):               return "→ PayObligationSheet(obligation: \(id))"
        case let (.obligation(id), "mark_completed"):    return "→ MarkCompletedSheet(obligation: \(id))"
        case let (.obligation(id), "dispute"):           return "→ DisputeObligationSheet(obligation: \(id))"
        case let (.obligation(id), "forgive"):           return "→ ForgiveObligationSheet(obligation: \(id))"
        case let (.obligation(id), "cancel"):            return "→ CancelObligationSheet(obligation: \(id))"

        case let (s, k):                                  return "→ unknown(\(k)) on \(s.label) \(s.idValue)"
        }
    }
}

/// F.2X — Protocol del router de Quick Actions. La conformidad real (sheets,
/// navigation paths) la añadirá cada feature en F.2X.2–F.2X.4.
@MainActor
public protocol ActionRouting: AnyObject {
    func open(_ destination: ActionDestination)
}

/// F.2X.1 — Router no-op observable. Persiste el último destino abierto en
/// `lastOpened`; las vistas que lo consumen pueden reaccionar con
/// `.onChange(of: router.lastOpened)` y disparar sheets / navegación.
///
/// Para previews/tests basta con leer `lastOpened` directamente.
@MainActor
@Observable
public final class NoopActionRouter: ActionRouting {
    public var lastOpened: ActionDestination?

    public init() {}

    public func open(_ destination: ActionDestination) {
        self.lastOpened = destination
    }
}

/// F.2X — Destino canónico tipado de una Quick Action. Centraliza el mapeo
/// `action_key` (string crudo del backend) → caso tipado, para que las vistas
/// NO hagan switch sobre strings crudos (doctrina intent-first). Cada vista
/// decide localmente cómo presentar el caso (push de tab, sheet, flow).
///
/// Si el backend introduce un `action_key` nuevo, se agrega un caso aquí —
/// igual que `ActionPresentationCatalog`.
public enum QuickActionDestination: Sendable, Equatable {
    // ── Context-level (F.2X.0) ─────────────────────────────────────────
    case createResource
    case createEvent
    case createDecision
    case inviteMember
    case createRule
    case createChildContext

    // ── Money (context-scoped) ─────────────────────────────────────────
    case recordExpense
    case recordFine
    case recordGameResult

    // ── Obligation-level (R.2S.9 / R.5V.X) ─────────────────────────────
    case markObligationCompleted
    case editObligation
    case forgiveObligation
}

/// F.2X — Helpers de construcción y debugging del router.
public enum ActionRouter {

    /// Construye el destino canónico desde una `AvailableAction` + `ActionScope`.
    public static func destination(for action: AvailableAction, in scope: ActionScope) -> ActionDestination {
        ActionDestination(actionKey: action.actionKey, scope: scope)
    }

    /// Mapeo canónico `action_key` → `QuickActionDestination`. ÚNICA fuente
    /// de verdad para routing por key; las vistas consumen el caso tipado.
    /// Keys desconocidos devuelven `nil` y el caller decide el fallback
    /// (mismo patrón que el caso unknown de `ActionDestination.debugIntent`).
    public static func quickActionDestination(for actionKey: String) -> QuickActionDestination? {
        switch actionKey {
        case "create_resource":      return .createResource
        case "create_event":         return .createEvent
        case "create_decision":      return .createDecision
        case "invite_member":        return .inviteMember
        case "create_rule":          return .createRule
        case "create_child_context": return .createChildContext

        case "record_expense":       return .recordExpense
        case "record_fine":          return .recordFine
        case "record_game_result":   return .recordGameResult

        case "mark_completed":       return .markObligationCompleted
        case "edit_obligation":      return .editObligation
        case "forgive":              return .forgiveObligation

        default:                     return nil
        }
    }

    /// R.13.B (founder lock 2026-06-16: "nada que no tenga que estar") —
    /// whitelist global de `action_key`s que algún handler iOS sabe ejecutar.
    /// Las DetailViews que renderean `availableActions[]` del descriptor
    /// FILTRAN por esta whitelist; lo que no esté aquí no se muestra como
    /// botón. Antes algunos detail views mostraban el button y disparaban un
    /// alert "Próximamente" cuando el handler no existía: doctrina derogada
    /// 2026-06-16 — esconder en vez de mostrar honestidad falsa.
    ///
    /// Mantener sincronizada con los handlers de cada feature
    /// (ObligationDetailView.handleObligationAction, ContextDetailV2 quickAction,
    /// ResourceDetailV2Actions, DecisionDetailView toolbar, etc.).
    public static let knownActionKeys: Set<String> = [
        // Context-level
        "create_resource",
        "create_event",
        "create_decision",
        "invite_member",
        "create_rule",
        "create_child_context",
        "archive_context",

        // Money
        "record_expense",
        "record_fine",
        "record_game_result",

        // Event lifecycle
        "rsvp_event",
        "check_in_participant",
        "cancel_participation",
        "close_event",
        "attach_document",
        "add_event_participants",
        "remove_event_participants",
        "host_confirm_participant",
        "set_event_participant_plus_one",
        "set_event_participant_plus_count",
        "update_calendar_event",
        "add_event_guest",
        "remove_event_guest",

        // Resource lifecycle
        "reserve_resource",
        "edit_resource",
        "archive_resource",
        "transfer_resource",
        "grant_right",
        "revoke_right",

        // Decision
        "vote",
        "change_vote",
        "close_decision",
        "cancel_decision",
        "execute_decision",

        // Reservation
        "approve",
        "confirm",
        "cancel",
        "resolve_conflict",

        // Obligation (handler en ObligationDetailView.handleObligationAction)
        "mark_completed",
        "edit_obligation",
        "forgive",

        // Rule
        "archive_rule",

        // Document (Documents V2)
        "archive_document"
    ]

    /// Helper conveniente: `true` si el actionKey tiene handler iOS en alguna
    /// vista. Las vistas filtran `availableActions` con esto.
    public static func isWired(_ actionKey: String) -> Bool {
        knownActionKeys.contains(actionKey)
    }
}
