import SwiftUI
import RuulCore

/// F.8 — detalle de una regla: condición y consecuencia en lenguaje natural.
public struct RuleDetailView: View {
    let rule: Rule

    public init(rule: Rule) {
        self.rule = rule
    }

    public var body: some View {
        List {
            Section {
                HStack(spacing: 16) {
                    Image(systemName: "ruler.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.tint)
                        .frame(width: 52, height: 52)
                        .background(Color.accentColor.opacity(0.12), in: Circle())
                    VStack(alignment: .leading, spacing: 4) {
                        Text(rule.title)
                            .font(.headline)
                        StatusBadge(
                            rule.isActive ? "Activa" : "Pausada",
                            color: rule.isActive ? .green : .gray
                        )
                    }
                }
                .padding(.vertical, 4)
            }

            if let body = rule.body, !body.isEmpty {
                Section("Acuerdo") {
                    Text(body)
                }
            }

            if rule.triggerEventType != nil {
                Section("Cómo funciona") {
                    InfoRow(
                        symbolName: "bolt.fill",
                        title: "Cuándo",
                        subtitle: triggerLabel
                    )
                    InfoRow(
                        symbolName: "questionmark.circle.fill",
                        title: "Si",
                        subtitle: rule.conditionDescription
                    )
                    InfoRow(
                        symbolName: "arrow.right.circle.fill",
                        title: "Entonces",
                        subtitle: rule.consequenceDescription
                    )
                }
            }

            Section("Información") {
                InfoRow(
                    symbolName: "tag",
                    title: "Tipo",
                    value: rule.ruleType == "automation" ? "Automatización" : (rule.ruleType == "norm" ? "Norma" : "Política")
                )
                if let created = rule.createdAt {
                    InfoRow(symbolName: "calendar", title: "Creada", value: created.formatted(date: .abbreviated, time: .omitted))
                }
            }
        }
        .navigationTitle("Regla")
        .navigationBarTitleDisplayMode(.inline)
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
