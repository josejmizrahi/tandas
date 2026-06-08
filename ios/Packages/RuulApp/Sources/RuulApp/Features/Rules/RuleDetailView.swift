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
            if canManage, container != nil {
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
    }

    private var triggerLabel: String {
        switch rule.triggerEventType {
        case RuleTrigger.checkedIn.rawValue: return "Al hacer check-in en un evento"
        case RuleTrigger.participationCancelled.rawValue: return "Al cancelar asistencia a un evento"
        default: return rule.triggerEventType ?? "—"
        }
    }
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
