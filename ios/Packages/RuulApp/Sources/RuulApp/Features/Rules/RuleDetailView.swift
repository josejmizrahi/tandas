import SwiftUI
import RuulCore

/// F.8 — detalle de una regla: condición y consecuencia en lenguaje natural.
/// F.RULE.2 — `context`/`container`/`onChanged` opcionales habilitan el botón
/// "Editar" cuando el caller tiene `rules.manage`. Sin ellos la pantalla
/// queda read-only (preview, deep-link genérico…).
public struct RuleDetailView: View {
    let rule: Rule
    let context: AppContext?
    let container: DependencyContainer?
    let canManage: Bool
    let onChanged: (() -> Void)?

    @State private var isShowingEdit = false
    /// R.7.x — governance flow para `rule.archive`. Catalog default es
    /// `requires_decision=true`, así que iOS lleva siempre por governance.
    /// Si el contexto override la policy a no-vote, una iteración futura puede
    /// agregar branch direct cuando descriptor surface `mode` en availableActions.
    @State private var runner = ActionRunner()
    @State private var isShowingArchiveSheet = false
    @State private var governanceClientId: String = UUID().uuidString
    @State private var pendingDecisionId: UUID?
    /// P1.6/V.4 — evaluaciones de ESTA regla (rule.evaluated por payload.rule_id).
    @State private var ruleActivity: [ActivityEvent] = []

    private func loadRuleActivity() async {
        guard let context, let container else { return }
        let events = (try? await container.rpc.listActivity(
            contextId: context.id, limit: 100, before: nil, includeDescendants: false
        )) ?? []
        ruleActivity = events.filter { event in
            event.eventType == "rule.evaluated"
                && event.payload?.objectValue?["rule_id"]?.stringValue?.lowercased()
                    == rule.id.uuidString.lowercased()
        }
    }

    private func outcomeLabel(_ event: ActivityEvent) -> String {
        switch event.payload?.objectValue?["outcome"]?.stringValue {
        case "matched", "fired": return "Se cumplió la condición — consecuencia aplicada"
        case "skipped", "no_match": return "Evaluada sin coincidencia"
        case let other?: return "Evaluada (\(other))"
        case nil: return "Evaluada"
        }
    }

    public init(rule: Rule) {
        self.rule = rule
        self.context = nil
        self.container = nil
        self.canManage = false
        self.onChanged = nil
    }

    public init(
        rule: Rule,
        context: AppContext,
        container: DependencyContainer,
        canManage: Bool,
        onChanged: @escaping () -> Void
    ) {
        self.rule = rule
        self.context = context
        self.container = container
        self.canManage = canManage
        self.onChanged = onChanged
    }

    public var body: some View {
        // R.6.E.3 — Apple-native pattern firmada V.4/V.5: Section { hero row } +
        // Label native con icon/title/subtitle para "Cómo funciona" + LabeledContent
        // para "Información" + RuulStatusBadge V.2 + Theme tokens.
        List {
            // R.11.K — Hero canonical (RuulDetailHero) — gana glass card +
            // consistencia con Resource/Document/Decision/Obligation/Context
            // Detail. Status badge en el slot canonical.
            Section {
                RuulDetailHero(
                    title: rule.title,
                    subtitle: nil,
                    systemImage: "ruler.fill",
                    tint: Theme.Tint.primary,
                    status: rule.isActive ? .active : .inactive,
                    chips: []
                )
                .ruulHeroRow()
            }

            if let body = rule.body, !body.isEmpty {
                Section {
                    Text(body)
                } header: {
                    Text("Acuerdo")
                }
            }

            if rule.triggerEventType != nil {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Cuándo").font(.callout)
                            Text(triggerLabel).font(.caption).foregroundStyle(Theme.Text.secondary)
                        }
                    } icon: {
                        Image(systemName: "bolt.fill").foregroundStyle(Theme.Tint.warning)
                    }
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Si").font(.callout)
                            Text(rule.conditionDescription).font(.caption).foregroundStyle(Theme.Text.secondary)
                        }
                    } icon: {
                        Image(systemName: "questionmark.circle.fill").foregroundStyle(Theme.Tint.info)
                    }
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Entonces").font(.callout)
                            Text(rule.consequenceDescription).font(.caption).foregroundStyle(Theme.Text.secondary)
                        }
                    } icon: {
                        Image(systemName: "arrow.right.circle.fill").foregroundStyle(Theme.Tint.success)
                    }
                } header: {
                    Text("Cómo funciona")
                }
            }

            Section {
                LabeledContent(
                    "Tipo",
                    value: rule.ruleType == "automation" ? "Automatización"
                        : (rule.ruleType == "norm" ? "Norma" : "Política")
                )
                if let created = rule.createdAt {
                    LabeledContent("Creada", value: created.formatted(date: .abbreviated, time: .omitted))
                }
            } header: {
                Text("Información")
            }

            // P1.6/V.4 — doctrina R.5V §1: la regla muestra su historial real
            // (rule.evaluated del motor R.6 filtrado por payload.rule_id) con
            // KPIs de disparos. Solo cuando el caller trae context+container.
            if context != nil, container != nil {
                Section {
                    if ruleActivity.isEmpty {
                        Label("Esta regla aún no se ha disparado", systemImage: "moon.zzz")
                            .font(.callout)
                            .foregroundStyle(Theme.Text.secondary)
                    } else {
                        LabeledContent("Veces evaluada", value: "\(ruleActivity.count)")
                        if let last = ruleActivity.first?.occurredAt {
                            LabeledContent("Última vez", value: last.formatted(.relative(presentation: .named)))
                        }
                        ForEach(ruleActivity.prefix(5)) { event in
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(outcomeLabel(event))
                                        .font(.callout)
                                    if let at = event.occurredAt {
                                        Text(at.formatted(date: .abbreviated, time: .shortened))
                                            .font(.caption)
                                            .foregroundStyle(Theme.Text.secondary)
                                    }
                                }
                            } icon: {
                                Image(systemName: "bolt.badge.clock")
                                    .foregroundStyle(Theme.Tint.warning)
                            }
                        }
                    }
                } header: {
                    Text("Historial")
                }
            }
        }
        .task { await loadRuleActivity() }
        .listStyle(.insetGrouped)
        .navigationTitle("Regla")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if canManage, container != nil, context != nil {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        // R.5Z.fix.2.a — Menu plano sin Section "Gestión" con
                        // un solo item. Divider antes de destructive action.
                        Button {
                            isShowingEdit = true
                        } label: {
                            Label("Editar", systemImage: "pencil")
                        }
                        if rule.status != "archived" {
                            Divider()
                            Button(role: .destructive) {
                                governanceClientId = UUID().uuidString
                                isShowingArchiveSheet = true
                            } label: {
                                Label("Archivar regla", systemImage: "archivebox")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Acciones de la regla")
                }
            } else if canManage, container != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isShowingEdit = true
                    } label: {
                        Label("Editar", systemImage: "pencil")
                    }
                }
            }
        }
        .sheet(isPresented: $isShowingEdit) {
            if let container {
                EditRuleView(
                    rule: rule,
                    container: container,
                    onSaved: { onChanged?() }
                )
            }
        }
        .actionErrorAlert(runner)
        // R.7.x — governance sheet (catalog default: rule.archive requires decision).
        .confirmationDialog(
            "Esta acción requiere aprobación",
            isPresented: $isShowingArchiveSheet,
            titleVisibility: .visible
        ) {
            Button("Crear votación") {
                Task { await requestGovernanceArchive() }
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Archivar \(rule.title) requiere aprobación del grupo. Se creará una votación para que los miembros aprueben.")
        }
        // R.7.x — push DecisionDetailView cuando request_governance_action devuelve decisionId.
        .sheet(item: Binding(
            get: { pendingDecisionId.map { RuleDecisionSheetWrapper(id: $0) } },
            set: { pendingDecisionId = $0?.id }
        ), onDismiss: {
            onChanged?()
        }) { wrapper in
            if let context, let container {
                NavigationStack {
                    DecisionDetailView(decisionId: wrapper.id, context: context, container: container)
                }
            }
        }
    }

    /// R.7.x — pide aprobación colectiva para `rule.archive`.
    private func requestGovernanceArchive() async {
        guard let context, let container else { return }
        let input = RequestGovernanceActionInput(
            contextActorId: context.id,
            actionKey: "rule.archive",
            targetType: "rule",
            targetId: rule.id,
            payload: .object([:]),
            title: "Archivar regla: \(rule.title)",
            closesAt: nil,
            clientId: governanceClientId
        )
        var capturedDecisionId: UUID?
        let success = await runner.run {
            let result = try await container.rpc.requestGovernanceAction(input)
            capturedDecisionId = result.decisionId
        }
        if success, let decisionId = capturedDecisionId {
            pendingDecisionId = decisionId
        }
    }

    /// Slice 7.A.4 — usa el helper canónico `rule.triggerHumanLabel` (exhaustivo
    /// para los 20+ triggers del catálogo R.6) en lugar del switch local de 2
    /// cases que dejaba expuesto el raw `event.checked_in`.
    private var triggerLabel: String { rule.triggerHumanLabel }
}

/// R.7.x — wrapper Identifiable para presentar `DecisionDetailView` via `.sheet(item:)`.
private struct RuleDecisionSheetWrapper: Identifiable {
    let id: UUID
}

#Preview("Detalle de regla") {
    NavigationStack {
        RuleDetailView(
            rule: Rule(
                id: UUID(),
                contextActorId: UUID(),
                title: "Multa por llegar tarde (>15 min)",
                triggerEventType: RuleTrigger.checkedIn.rawValue,
                conditionTree: RuleConditionBuilder.lateMoreThan(minutes: 15),
                consequences: RuleConsequenceBuilder.fine(amount: 100, currency: "MXN"),
                createdAt: Date()
            )
        )
    }
}
