import Foundation
import Observation
import OSLog
import RuulCore

/// Coordinator backing the event-scoped Rules surface. Loads rules with
/// `rules.resource_id = event.id` (Taxonomy §29) and drives the form for
/// adding a new in-event rule.
///
/// MVP form shape: a name + trigger picker (3 canonical event triggers) +
/// flat fine amount. Conditions are auto-attached based on trigger choice
/// (`alwaysTrue` for cancellation/close; `checkInRecorded` doesn't need
/// extra gating for V1). Phase 4b expands to the full trigger/condition
/// catalog.
@Observable @MainActor
public final class EventRulesCoordinator {
    public enum TriggerKind: String, CaseIterable, Identifiable, Hashable {
        case lateArrival       // Llegada tarde — fires on checkInRecorded
        case sameDayCancel     // Cancelación mismo día — rsvpChangedSameDay
        case onClose           // Al cerrar el evento — eventClosed

        public var id: String { rawValue }

        public var displayLabel: String {
            switch self {
            case .lateArrival:   return "Llegada tarde"
            case .sameDayCancel: return "Cancelación mismo día"
            case .onClose:       return "Al cerrar el evento"
            }
        }

        public var summary: String {
            switch self {
            case .lateArrival:
                return "Cuando alguien hace check-in después de la hora de inicio."
            case .sameDayCancel:
                return "Cuando alguien cambia su RSVP a 'no voy' el mismo día."
            case .onClose:
                return "Cuando el host cierra el evento (todos los presentes/ausentes ya están registrados)."
            }
        }

        public var iconName: String {
            switch self {
            case .lateArrival:   return "clock.badge.exclamationmark"
            case .sameDayCancel: return "person.crop.circle.badge.xmark"
            case .onClose:       return "checkmark.seal"
            }
        }

        var triggerEventType: SystemEventType {
            switch self {
            case .lateArrival:   return .checkInRecorded
            case .sameDayCancel: return .rsvpChangedSameDay
            case .onClose:       return .eventClosed
            }
        }
    }

    public let groupId: UUID
    public let eventId: UUID
    public let event: Event
    public let canCreate: Bool

    public private(set) var rules: [GroupRule] = []
    public private(set) var isLoading: Bool = true
    public private(set) var isSubmitting: Bool = false
    public private(set) var error: String?
    public var addSheetPresented: Bool = false

    // Form state
    public var formName: String = ""
    public var formTrigger: TriggerKind = .lateArrival
    public var formFineAmountText: String = ""

    private let ruleRepo: any RuleRepository
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "event.rules")

    public init(
        event: Event,
        canCreate: Bool,
        ruleRepo: any RuleRepository
    ) {
        self.event = event
        self.groupId = event.groupId
        self.eventId = event.id
        self.canCreate = canCreate
        self.ruleRepo = ruleRepo
    }

    // MARK: - Loading

    public func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            rules = try await ruleRepo.listForResource(eventId)
        } catch {
            log.warning("load failed: \(error.localizedDescription)")
            self.error = "No pudimos cargar las reglas."
        }
    }

    // MARK: - Derived state

    public var parsedFineAmount: Int? {
        let trimmed = formFineAmountText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Int(trimmed.filter(\.isNumber))
    }

    public var canSubmit: Bool {
        guard canCreate, !isSubmitting else { return false }
        let trimmedName = formName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedName.count >= 2 else { return false }
        guard let amount = parsedFineAmount, amount > 0, amount <= 1_000_000 else {
            return false
        }
        return true
    }

    // MARK: - Submit

    public func resetForm() {
        formName = ""
        formTrigger = .lateArrival
        formFineAmountText = ""
        error = nil
    }

    @discardableResult
    public func submit() async -> GroupRule? {
        guard canSubmit, let amount = parsedFineAmount else { return nil }
        let trimmedName = formName.trimmingCharacters(in: .whitespacesAndNewlines)

        let trigger = RuleTrigger(
            eventType: formTrigger.triggerEventType,
            config: .object([:])
        )
        let conditions: [RuleCondition] = [
            RuleCondition(type: .alwaysTrue, config: .object([:]))
        ]
        let consequences: [RuleConsequence] = [
            RuleConsequence(
                type: .fine,
                config: .object(["amount": .int(amount)])
            )
        ]

        isSubmitting = true
        error = nil
        defer { isSubmitting = false }

        do {
            let rule = try await ruleRepo.createEventRule(
                groupId: groupId,
                resourceId: eventId,
                name: trimmedName,
                trigger: trigger,
                conditions: conditions,
                consequences: consequences
            )
            // Refresh from server so the projection matches what the DB
            // returns (decoded `consequences` envelope, server-set fields).
            rules.insert(rule, at: 0)
            resetForm()
            return rule
        } catch {
            self.error = humanize(error: error)
            log.warning("submit failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func humanize(error: Error) -> String {
        let raw = (error as NSError).localizedDescription.lowercased()
        if raw.contains("auth required") { return "Tu sesión expiró. Volvé a entrar." }
        if raw.contains("only group admins or the event host") {
            return "Sólo el host del evento o un admin pueden crear reglas aquí."
        }
        if raw.contains("only group admins") {
            return "Sólo los admins del grupo pueden crear reglas para este recurso."
        }
        if raw.contains("resource does not belong") {
            return "Esta regla no pertenece a este evento."
        }
        if raw.contains("rule name must be") {
            return "El nombre debe tener al menos 2 caracteres."
        }
        return "No pudimos crear la regla. Intenta de nuevo."
    }
}
