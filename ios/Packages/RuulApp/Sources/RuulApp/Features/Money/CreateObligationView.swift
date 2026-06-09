import SwiftUI
import RuulCore

/// R.2R — form para crear un compromiso de acción (kind ≠ money). El backend
/// rechaza kind=money: las obligaciones monetarias se generan vía record_*.
public struct CreateObligationView: View {
    let context: AppContext
    let container: DependencyContainer
    /// Si viene seteado, el form pre-selecciona ese deudor y oculta el picker.
    let preselectedDebtorId: UUID?

    @Environment(\.dismiss) private var dismiss
    @State private var runner = ActionRunner()
    @State private var members: [ContextMember] = []
    @State private var debtorId: UUID?
    @State private var title = ""
    @State private var descriptionText = ""
    @State private var kind: ObligationKind = .action
    @State private var hasDueDate = false
    @State private var dueDate = Date().addingTimeInterval(86_400 * 3)
    /// R.6.AI.10 — AI hero state.
    @State private var suggestionService = ObligationSuggestionService()
    @State private var aiPromptText = ""
    @State private var lastConsidered: [RuulAIContext.Considered] = []

    public init(
        context: AppContext,
        container: DependencyContainer,
        preselectedDebtorId: UUID? = nil
    ) {
        self.context = context
        self.container = container
        self.preselectedDebtorId = preselectedDebtorId
        _debtorId = State(initialValue: preselectedDebtorId)
    }

    private enum ObligationKind: String, CaseIterable, Identifiable {
        case action, approval, delivery, attendance, document, reservation, custom
        var id: String { rawValue }
        var label: String {
            switch self {
            case .action: return "Acción"
            case .approval: return "Aprobación"
            case .delivery: return "Entrega"
            case .attendance: return "Asistencia"
            case .document: return "Documento"
            case .reservation: return "Reservación"
            case .custom: return "Otro"
            }
        }
        var symbolName: String {
            switch self {
            case .action: return "checkmark.circle"
            case .approval: return "checkmark.seal"
            case .delivery: return "shippingbox"
            case .attendance: return "person.crop.circle.badge.checkmark"
            case .document: return "doc.text"
            case .reservation: return "calendar.badge.clock"
            case .custom: return "circle.dashed"
            }
        }
    }

    public var body: some View {
        NavigationStack {
            Form {
                // R.6.AI.10 — Hero AI sólo cuando no viene pre-rellenado.
                if preselectedDebtorId == nil {
                    aiHero
                }

                Section("Quién se compromete") {
                    if preselectedDebtorId != nil, let debtorId, let member = members.first(where: { $0.actorId == debtorId }) {
                        HStack(spacing: 12) {
                            ActorInitialsView(name: member.displayName, size: 32)
                            Text(member.displayName)
                        }
                    } else {
                        Picker("Deudor", selection: $debtorId) {
                            Text("Selecciona…").tag(UUID?.none)
                            ForEach(members) { member in
                                Text(member.displayName).tag(Optional(member.actorId))
                            }
                        }
                    }
                }

                Section("Tipo") {
                    Picker("Tipo", selection: $kind) {
                        ForEach(ObligationKind.allCases) { k in
                            Label(k.label, systemImage: k.symbolName).tag(k)
                        }
                    }
                    .pickerStyle(.menu)
                }

                Section("Detalle") {
                    TextField("Qué se compromete a hacer", text: $title)
                    TextField("Notas (opcional)", text: $descriptionText, axis: .vertical)
                        .lineLimit(2...5)
                }

                Section {
                    Toggle("Tiene fecha límite", isOn: $hasDueDate.animation())
                    if hasDueDate {
                        DatePicker("Vence", selection: $dueDate, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                    }
                }

                Section {
                    Button {
                        Task { await submit() }
                    } label: {
                        if runner.isRunning {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Text("Crear compromiso").frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(!canSubmit || runner.isRunning)
                } footer: {
                    Text("Las obligaciones de dinero se crean desde Gastos / Multas / Juegos — no aquí.")
                }
            }
            .navigationTitle("Nuevo compromiso")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
            }
            .task {
                await loadMembers()
            }
            .actionErrorAlert(runner)
        }
        .ruulSheet()
    }

    private var canSubmit: Bool {
        debtorId != nil && !title.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - R.6.AI.10 — AI Hero

    private var aiHero: some View {
        RuulAIHeroView(
            headline: "Pídele a Ruul",
            subtitle: "Describe el compromiso y lo armamos por ti",
            placeholder: "Ej: Aaron entrega el reporte el viernes",
            ctaLabel: "Pensar compromiso",
            examples: [
                "Aaron entrega el reporte el viernes",
                "Maria aprueba el gasto",
                "Moshe lleva el postre el sábado",
                "Yo firmo el contrato hoy"
            ],
            footerWhenIdle: "Descríbelo con tus palabras o llena los campos abajo.",
            footerWhenLoaded: "El compromiso ya está armado. Ajústalo si quieres.",
            prompt: $aiPromptText,
            considered: $lastConsidered,
            phase: aiPhase,
            onSuggest: { await aiSuggest() },
            onReset: {
                lastConsidered = []
                aiPromptText = ""
                suggestionService.reset()
            }
        )
    }

    private var aiPhase: RuulAIHeroView.HeroPhase {
        switch suggestionService.phase {
        case .idle, .loaded: return .idle
        case .loading:       return .loading
        case .failed(let m): return .failed(message: m)
        case .unavailable(let r): return .unavailable(reason: r)
        }
    }

    private func aiSuggest() async {
        // Asegura members antes del apply (si .task aún no completó).
        if members.isEmpty { await loadMembers() }
        await suggestionService.suggest(
            prompt: aiPromptText,
            rpc: container.rpc,
            contextId: context.id
        )
        if case .loaded(let suggestion, let considered) = suggestionService.phase {
            applyAISuggestion(suggestion)
            lastConsidered = considered
            suggestionService.reset()
        }
    }

    private func applyAISuggestion(_ s: ObligationSuggestion) {
        if !s.title.isEmpty { title = s.title }
        if !s.detail.isEmpty { descriptionText = s.detail }
        if !s.debtorName.isEmpty, let match = matchMember(name: s.debtorName) {
            debtorId = match.actorId
        }
        if let mapped = ObligationKind(rawValue: s.kindKey) {
            kind = mapped
        }
        hasDueDate = s.hasDueDate
    }

    private func matchMember(name: String) -> ContextMember? {
        let needle = name.lowercased().trimmingCharacters(in: .whitespaces)
        if let exact = members.first(where: { $0.displayName.lowercased() == needle }) {
            return exact
        }
        return members.first { $0.displayName.lowercased().contains(needle) }
    }

    private func loadMembers() async {
        do {
            let summary = try await container.rpc.contextSummary(contextId: context.id)
            members = summary.members
        } catch {
            members = []
        }
    }

    private func submit() async {
        guard let debtorId else { return }
        let success = await runner.run {
            _ = try await container.rpc.createActionObligation(CreateActionObligationInput(
                contextId: context.id,
                debtorActorId: debtorId,
                title: title.trimmingCharacters(in: .whitespaces),
                kind: kind.rawValue,
                description: descriptionText.trimmingCharacters(in: .whitespaces).isEmpty
                    ? nil
                    : descriptionText.trimmingCharacters(in: .whitespaces),
                dueAt: hasDueDate ? dueDate : nil
            ))
        }
        if success { dismiss() }
    }
}

#Preview("Crear compromiso") {
    CreateObligationView(
        context: AppContext(
            id: MockRuulRPCClient.DemoIds.cenaSemanal,
            kind: .collective,
            subtype: "friend_group",
            displayName: "Cena Semanal",
            roles: ["admin"]
        ),
        container: .demo()
    )
}
