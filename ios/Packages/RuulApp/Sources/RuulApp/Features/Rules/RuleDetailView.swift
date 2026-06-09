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
            Section {
                HStack(spacing: 14) {
                    Image(systemName: "ruler.fill")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(Theme.Tint.primary)
                        .frame(width: 56, height: 56)
                        .background(Theme.Tint.primary.opacity(0.15), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(rule.title)
                            .font(.title3.bold())
                            .foregroundStyle(Theme.Text.primary)
                            .lineLimit(2)
                        RuulStatusBadge(rule.isActive ? .active : .inactive)
                    }
                    Spacer(minLength: 0)
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 12, leading: 4, bottom: 4, trailing: 4))
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
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Regla")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if canManage, container != nil, context != nil {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            isShowingEdit = true
                        } label: {
                            Label("Editar", systemImage: "pencil")
                        }
                        if rule.status != "archived" {
                            Section("Gestión") {
                                Button(role: .destructive) {
                                    governanceClientId = UUID().uuidString
                                    isShowingArchiveSheet = true
                                } label: {
                                    Label("Archivar regla", systemImage: "archivebox")
                                }
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
            Button("Crear decisión") {
                Task { await requestGovernanceArchive() }
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Archivar \(rule.title) requiere votación colectiva. Se creará una decisión para que los miembros aprueben.")
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

    private var triggerLabel: String {
        switch rule.triggerEventType {
        case RuleTrigger.checkedIn.rawValue: return "Al hacer check-in en un evento"
        case RuleTrigger.participationCancelled.rawValue: return "Al cancelar asistencia a un evento"
        default: return rule.triggerEventType ?? "—"
        }
    }
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
