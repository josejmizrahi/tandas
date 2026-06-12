import Foundation
import Observation

/// F.10 — store de decisiones del contexto.
@MainActor
@Observable
public final class DecisionsStore {
    public private(set) var decisions: [Decision] = []
    public private(set) var myPermissions: [String] = []
    public private(set) var members: [ContextMember] = []
    public private(set) var phase: StorePhase = .idle
    /// R.4B — catálogo de plantillas (`decision_templates_catalog`) para el picker.
    public private(set) var templates: [DecisionTemplate] = []
    /// R.4B — recursos del contexto (para los pickers de payload que apuntan a un recurso).
    public private(set) var resources: [ContextResource] = []
    /// R.4B — reglas activas del contexto (para `archive_rule`).
    public private(set) var rules: [Rule] = []

    private let rpc: any RuulRPCClient
    /// Para resolver "Tú" cuando el actor no está en members
    /// (contexto personal o un actor que ya salió del contexto).
    private var myActorId: UUID?

    public init(rpc: any RuulRPCClient, myActorId: UUID? = nil) {
        self.rpc = rpc
        self.myActorId = myActorId
    }

    public init(rpc: any RuulRPCClient, previewDecisions: [Decision], members: [ContextMember] = [], permissions: [String] = []) {
        self.rpc = rpc
        self.decisions = previewDecisions
        self.members = members
        self.myPermissions = permissions
        self.phase = .loaded
    }

    public var open: [Decision] { decisions.filter(\.isOpen) }
    public var closed: [Decision] { decisions.filter { !$0.isOpen } }

    public func load(context: AppContext) async {
        if decisions.isEmpty { phase = .loading }
        do {
            async let decisionsTask = rpc.listDecisions(contextId: context.id)
            async let summaryTask = rpc.contextSummary(contextId: context.id)
            let (loaded, summary) = try await (decisionsTask, summaryTask)
            decisions = loaded
            members = summary.members
            myPermissions = summary.myPermissions
            phase = .loaded
        } catch {
            phase = .failed(message: UserFacingError.from(error).message)
        }
    }

    /// R.4B — carga el catálogo de plantillas + los datos que alimentan los
    /// pickers del form (miembros del summary, recursos y reglas). Todo best-effort:
    /// si algo falla (RLS, red), el form cae a sólo las plantillas que sí cargaron.
    public func loadCreateCatalog(context: AppContext) async {
        async let templatesTask: [DecisionTemplate]? = try? await rpc.listDecisionTemplates()
        async let summaryTask: ContextSummary? = try? await rpc.contextSummary(contextId: context.id)
        async let resourcesTask: [ContextResource]? = try? await rpc.listContextResources(contextId: context.id)
        async let rulesTask: [Rule]? = try? await rpc.listRules(contextId: context.id)
        let (loadedTemplates, summary, loadedResources, loadedRules) =
            await (templatesTask, summaryTask, resourcesTask, rulesTask)
        if let loadedTemplates { templates = loadedTemplates }
        if let summary {
            members = summary.members
            myPermissions = summary.myPermissions
        }
        if let loadedResources { resources = loadedResources.filter { $0.status != "archived" } }
        if let loadedRules { rules = loadedRules.filter(\.isActive) }
    }

    public func displayName(for actorId: UUID?) -> String {
        guard let actorId else { return "—" }
        if let member = members.first(where: { $0.actorId == actorId }) { return member.displayName }
        if actorId == myActorId { return "Tú" }
        return "Alguien"
    }

    public func canCreate(in context: AppContext) -> Bool {
        context.isPersonal || myPermissions.contains("decisions.create")
    }

    public func canVote(in context: AppContext) -> Bool {
        context.isPersonal || myPermissions.contains("decisions.vote")
    }

    public func canExecute(in context: AppContext) -> Bool {
        context.isPersonal || myPermissions.contains("decisions.execute")
    }

    // MARK: - Acciones

    public func createDecision(_ input: CreateDecisionInput, context: AppContext) async throws -> Decision {
        let decision = try await rpc.createDecision(input)
        await load(context: context)
        return decision
    }

    /// R.2Q — crea la decisión y agrega las opciones manuales (para single_choice
    /// arbitrario que no se auto-seedea desde payload.options).
    public func createDecision(
        _ input: CreateDecisionInput,
        options drafts: [DecisionOptionDraft],
        context: AppContext
    ) async throws -> Decision {
        let decision = try await rpc.createDecision(input)
        for (idx, draft) in drafts.enumerated() {
            _ = try await rpc.createDecisionOption(CreateDecisionOptionInput(
                decisionId: decision.id,
                optionKey: draft.optionKey,
                title: draft.title,
                description: draft.description,
                payload: draft.payload,
                sortOrder: idx
            ))
        }
        await load(context: context)
        return decision
    }
}

/// Opción que el usuario configura antes de crear la decisión (R.2Q).
public struct DecisionOptionDraft: Sendable, Identifiable, Equatable {
    public let id: UUID
    public var title: String
    public var description: String?
    public var optionKey: String
    public var payload: JSONValue?

    public init(
        id: UUID = UUID(),
        title: String,
        description: String? = nil,
        optionKey: String? = nil,
        payload: JSONValue? = nil
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.optionKey = optionKey ?? Self.slugify(title)
        self.payload = payload
    }

    /// Genera un option_key estable a partir del title (lowercase + guiones).
    /// Si el slug queda vacío usa el UUID como fallback.
    public static func slugify(_ raw: String) -> String {
        let lowered = raw.lowercased()
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-_")
        let mapped = lowered.map { ch -> Character in
            if allowed.contains(ch) { return ch }
            if ch.isWhitespace { return "-" }
            return "-"
        }
        let collapsed = String(mapped)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed.isEmpty ? UUID().uuidString.lowercased() : collapsed
    }
}

/// F.10 — store del detalle de una decisión: decisión + votos + opciones (R.2Q).
@MainActor
@Observable
public final class DecisionDetailStore {
    public private(set) var decision: Decision?
    public private(set) var detail: DecisionDetail?
    public private(set) var votes: [DecisionVote] = []
    public private(set) var options: [DecisionOption] = []
    public private(set) var members: [ContextMember] = []
    public private(set) var myPermissions: [String] = []
    public private(set) var phase: StorePhase = .idle
    /// Resultado de la última acción de voto/cierre.
    public private(set) var lastResult: VoteResult?

    private let rpc: any RuulRPCClient
    /// Para resolver "Tú" cuando el actor no está en members
    /// (contexto personal o un actor que ya salió del contexto).
    private var myActorId: UUID?

    public init(rpc: any RuulRPCClient, myActorId: UUID? = nil) {
        self.rpc = rpc
        self.myActorId = myActorId
    }

    public func load(decisionId: UUID, context: AppContext) async {
        if decision == nil { phase = .loading }
        do {
            // Required: decisión (vía listDecisions PostgREST, RLS-safe) + summary
            // del contexto (debe pasar — el caller llegó aquí desde el contexto).
            async let decisionsTask = rpc.listDecisions(contextId: context.id)
            async let summaryTask = rpc.contextSummary(contextId: context.id)
            let (decisions, summary) = try await (decisionsTask, summaryTask)
            decision = decisions.first { $0.id == decisionId }
            members = summary.members
            myPermissions = summary.myPermissions

            // Best-effort: las RPCs que chequean is_context_member sobre el
            // contexto de la decisión pueden raise 42501 si el caller llegó
            // a la decisión desde un contexto distinto (deep link, my_world,
            // historial). No rompemos la vista — caemos al gateado por summary.
            async let votesTask: [DecisionVote]? = try? await rpc.listDecisionVotes(decisionId: decisionId)
            async let optionsTask: [DecisionOption]? = try? await rpc.listDecisionOptions(decisionId: decisionId)
            async let detailTask: DecisionDetail? = try? await rpc.decisionDetail(decisionId: decisionId)
            let (loadedVotes, loadedOptions, loadedDetail) = await (votesTask, optionsTask, detailTask)
            votes = loadedVotes ?? []
            options = (loadedOptions ?? []).filter(\.isActive).sorted { $0.sortOrder < $1.sortOrder }
            detail = loadedDetail
            phase = .loaded
        } catch {
            phase = .failed(message: UserFacingError.from(error).message)
        }
    }

    /// R.2S — gateado por backend (`available_actions[]`). Devuelve la acción
    /// canónica si el actor puede ejecutarla ahora; nil si no aplica.
    public func availableAction(_ key: String) -> AvailableAction? {
        detail?.action(key)
    }

    /// R.2S — ¿la acción está habilitada para este actor? Si no hay detail
    /// (best-effort falló), cae al gateado por `myPermissions` del summary.
    public func canDo(_ key: String) -> Bool {
        if let detail { return detail.can(key) }
        switch key {
        case "vote", "change_vote":
            return myPermissions.contains("decisions.vote") || myPermissions.contains("decisions.create")
        case "close_decision", "execute_decision", "cancel_decision":
            return myPermissions.contains("decisions.execute") || myPermissions.contains("context.manage")
        default:
            return false
        }
    }

    public func displayName(for actorId: UUID?) -> String {
        guard let actorId else { return "—" }
        if let member = members.first(where: { $0.actorId == actorId }) { return member.displayName }
        if actorId == myActorId { return "Tú" }
        return "Alguien"
    }

    public func myVote(myActorId: UUID?) -> DecisionVote? {
        guard let myActorId else { return nil }
        return votes.first { $0.voterActorId == myActorId }
    }

    public func canVote(in context: AppContext) -> Bool {
        context.isPersonal || myPermissions.contains("decisions.vote")
    }

    public func canExecute(in context: AppContext) -> Bool {
        context.isPersonal || myPermissions.contains("decisions.execute")
    }

    /// Conteo de votos por opción para single_choice (R.2Q).
    public func voteCount(for option: DecisionOption) -> Int {
        votes.filter { $0.optionId == option.id }.count
    }

    /// Opción ganadora resuelta a partir del result jsonb.
    public func winningOption() -> DecisionOption? {
        guard let id = decision?.winningOptionId else { return nil }
        return options.first { $0.id == id }
    }

    // MARK: - Acciones

    public func vote(_ choice: VoteChoice, decisionId: UUID, context: AppContext) async throws -> VoteResult {
        let result = try await rpc.voteDecision(decisionId: decisionId, vote: choice, option: nil)
        lastResult = result
        await load(decisionId: decisionId, context: context)
        return result
    }

    /// R.2Q — votar por una opción específica.
    public func vote(for option: DecisionOption, decisionId: UUID, context: AppContext) async throws -> VoteResult {
        let result = try await rpc.voteForOption(decisionId: decisionId, optionId: option.id)
        lastResult = result
        await load(decisionId: decisionId, context: context)
        return result
    }

    public func close(decisionId: UUID, context: AppContext) async throws -> VoteResult {
        let result = try await rpc.closeDecision(decisionId: decisionId)
        lastResult = result
        await load(decisionId: decisionId, context: context)
        return result
    }

    public func execute(decisionId: UUID, context: AppContext) async throws {
        try await rpc.executeDecision(decisionId: decisionId, result: nil)
        await load(decisionId: decisionId, context: context)
    }
}
