import SwiftUI
import RuulCore

/// F.NAV.2 — Pantalla global Home. F.NAV.1 stub: muestra el contador del
/// `attention_inbox` + placeholders para Continuar / Acciones globales /
/// Actividad relevante. Los 4 secciones completas las arma F.NAV.2.
public struct HomeView: View {
    let container: DependencyContainer

    public init(container: DependencyContainer) {
        self.container = container
    }

    public var body: some View {
        NavigationStack {
            List {
                attentionSection
                continueSection
                globalActionsSection
                relevantActivitySection
            }
            .navigationTitle("Home")
            .task {
                await container.attentionInboxStore.load()
                await container.contextPreferencesStore.load()
            }
            .refreshable {
                await container.attentionInboxStore.load()
                await container.contextPreferencesStore.load()
            }
        }
    }

    // MARK: - Sección 1: ⚠ Requiere tu atención

    @ViewBuilder
    private var attentionSection: some View {
        Section {
            let items = container.attentionInboxStore.items
            if items.isEmpty {
                Text("Sin asuntos pendientes 🎉")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } else {
                ForEach(items) { item in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: attentionSymbol(for: item.kind))
                            .foregroundStyle(attentionTint(for: item.kind))
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .font(.callout.weight(.medium))
                            Text("\(item.contextDisplayName) · \(item.reason)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        } header: {
            Label("Requiere tu atención", systemImage: "exclamationmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
        }
    }

    private func attentionSymbol(for kind: String) -> String {
        switch kind {
        case "reservation_conflict": return "exclamationmark.triangle.fill"
        case "decision_vote":        return "hand.thumbsup.fill"
        case "obligation_pay":       return "creditcard.fill"
        case "obligation_complete":  return "checkmark.circle"
        case "invitation":           return "envelope.fill"
        default:                     return "circle.fill"
        }
    }

    private func attentionTint(for kind: String) -> Color {
        switch kind {
        case "reservation_conflict": return .red
        case "decision_vote":        return .purple
        case "obligation_pay",
             "obligation_complete":  return .green
        case "invitation":           return .blue
        default:                     return .secondary
        }
    }

    // MARK: - Sección 2: Continuar (contextos recientes)

    @ViewBuilder
    private var continueSection: some View {
        let recents = container.contextPreferencesStore.recents
        if !recents.isEmpty {
            Section("Continuar") {
                ForEach(recents) { ctx in
                    HStack(spacing: 12) {
                        Image(systemName: "circle.dotted")
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading) {
                            Text(ctx.displayName).font(.callout)
                            if let visited = ctx.lastVisitedAt {
                                Text(visited.formatted(.relative(presentation: .named)))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Sección 3: Acciones globales mínimas

    @ViewBuilder
    private var globalActionsSection: some View {
        Section {
            Label("Crear", systemImage: "plus.circle.fill")
                .foregroundStyle(.primary)
            Label("Buscar", systemImage: "magnifyingglass")
            Label("Preguntar a Ruul", systemImage: "sparkles")
        } header: {
            Label("Acciones rápidas", systemImage: "bolt.fill")
                .font(.subheadline)
        } footer: {
            Text("F.NAV.5: la sheet intent-first abrirá desde el botón Crear de la tab bar.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Sección 4: Actividad relevante (placeholder)

    @ViewBuilder
    private var relevantActivitySection: some View {
        Section {
            NavigationLink {
                MyActivityFeedView(container: container)
            } label: {
                Label("Ver actividad relevante", systemImage: "antenna.radiowaves.left.and.right")
            }
        } header: {
            Text("Lo que me importa")
        } footer: {
            Text("Señales personalizadas de contextos, recursos y decisiones que te interesan.")
        }
    }
}

#Preview("Home (demo)") {
    HomeView(container: .demo())
}
