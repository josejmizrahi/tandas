import SwiftUI
import RuulCore

/// F.NAV.2 — Pantalla global Home. Doctrina:
///
/// - Sección 1: **Requiere tu atención** — items canónicos de
///   `attention_inbox()` con CTA directa (tap → sheet/jump al detail).
/// - Sección 2: **Continuar** — contextos visitados recientemente.
/// - Sección 3: **Acciones globales** — Crear / Buscar / Preguntar a Ruul
///   (placeholders hasta F.NAV.5).
/// - Sección 4: **Lo que me importa** — feed personalizado (R.3A).
public struct HomeView: View {
    let container: DependencyContainer
    /// Callback para cambiar al tab Contextos con un contexto específico
    /// (usado para `reservation_conflict` y "Continuar").
    let jumpToContext: (AppContext) -> Void
    /// F.NAV.8+: dispara la sheet intent-first ("¿Qué quieres hacer?") sin
    /// pasar por el tab Crear. Le delega al MainTabShell.
    let onTriggerCreate: () -> Void

    @State private var presentedAttention: AttentionItem?
    @State private var isShowingPendingInvitations = false

    public init(container: DependencyContainer, jumpToContext: @escaping (AppContext) -> Void, onTriggerCreate: @escaping () -> Void) {
        self.container = container
        self.jumpToContext = jumpToContext
        self.onTriggerCreate = onTriggerCreate
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
                await container.invitationsStore.load(actorId: container.currentActorStore.actorId)
            }
            .refreshable {
                await container.attentionInboxStore.load()
                await container.contextPreferencesStore.load()
                await container.invitationsStore.load(actorId: container.currentActorStore.actorId)
            }
            .sheet(item: $presentedAttention) { item in
                attentionDestination(for: item)
            }
            .sheet(isPresented: $isShowingPendingInvitations) {
                PendingInvitationsView(container: container)
            }
        }
    }

    // MARK: - Routing de atención

    /// Resuelve el `AppContext` para un attention item desde el ContextStore.
    private func appContext(for contextActorId: UUID) -> AppContext? {
        container.contextStore.availableContexts.first { $0.id == contextActorId }
    }

    /// Dispara la acción del attention item. Para conflictos cambiamos a la
    /// tab Contextos con el contexto correcto; el resto abren un sheet con
    /// el detail apropiado.
    private func handleTap(_ item: AttentionItem) {
        switch item.kind {
        case "invitation":
            // Las invitaciones tienen sheet propia (lista global).
            isShowingPendingInvitations = true

        case "reservation_conflict":
            // No tenemos el conflict object aquí — saltamos al contexto.
            if let ctx = appContext(for: item.contextActorId) {
                jumpToContext(ctx)
            }

        case "decision_vote", "obligation_pay", "obligation_complete":
            // Sheet con detail view (NavigationStack interno).
            presentedAttention = item

        default:
            break
        }
    }

    @ViewBuilder
    private func attentionDestination(for item: AttentionItem) -> some View {
        if let ctx = appContext(for: item.contextActorId) {
            NavigationStack {
                switch item.kind {
                case "decision_vote":
                    DecisionDetailView(
                        decisionId: item.ctaScopeId,
                        context: ctx,
                        container: container
                    )
                case "obligation_pay", "obligation_complete":
                    ObligationDetailView(
                        obligationId: item.ctaScopeId,
                        context: ctx,
                        container: container
                    )
                default:
                    EmptyView()
                }
            }
        } else {
            ContextNotAvailableView(contextName: item.contextDisplayName)
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
                    Button {
                        handleTap(item)
                    } label: {
                        attentionRow(item)
                    }
                    .buttonStyle(.plain)
                }
            }
        } header: {
            Label("Requiere tu atención", systemImage: "exclamationmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private func attentionRow(_ item: AttentionItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: attentionSymbol(for: item.kind))
                .foregroundStyle(attentionTint(for: item.kind))
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                HStack(spacing: 6) {
                    Text(item.contextDisplayName)
                        .font(.caption.weight(.medium))
                    Text("·")
                    Text(item.reason)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                Text(ctaLabel(for: item.ctaActionKey))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(attentionTint(for: item.kind))
                    .padding(.top, 2)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
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

    /// El backend manda `cta_action_key`; iOS traduce a label corto para el
    /// affordance ("Resolver / Votar / Pagar / Aceptar / Marcar"). No es
    /// inferencia doctrinal: es presentation translation, mismo espíritu que
    /// `ActionPresentationCatalog`.
    private func ctaLabel(for actionKey: String) -> String {
        switch actionKey {
        case "resolve_conflict":    return "Resolver →"
        case "vote":                return "Votar →"
        case "pay":                 return "Pagar →"
        case "mark_completed":      return "Marcar como cumplida →"
        case "accept_invitation":   return "Aceptar →"
        default:                    return "Ver →"
        }
    }

    // MARK: - Sección 2: Continuar (contextos recientes)

    @ViewBuilder
    private var continueSection: some View {
        let recents = container.contextPreferencesStore.recents
        if !recents.isEmpty {
            Section("Continuar") {
                ForEach(recents) { ctx in
                    Button {
                        if let appCtx = appContext(for: ctx.contextActorId) {
                            jumpToContext(appCtx)
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: ctx.isFavorite ? "star.fill" : "circle.dotted")
                                .foregroundStyle(ctx.isFavorite ? Color.yellow : Color.accentColor)
                                .frame(width: 24)
                            VStack(alignment: .leading) {
                                Text(ctx.displayName).font(.callout).foregroundStyle(.primary)
                                if let visited = ctx.lastVisitedAt {
                                    Text(visited.formatted(.relative(presentation: .named)))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Sección 3: Acciones globales mínimas

    @ViewBuilder
    private var globalActionsSection: some View {
        Section {
            Button {
                onTriggerCreate()
            } label: {
                HStack {
                    Label("Crear", systemImage: "plus.circle.fill")
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            // Buscar y Preguntar a Ruul: aún no implementados.
            Label("Buscar", systemImage: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Buscar. Próximamente.")
            Label("Preguntar a Ruul", systemImage: "sparkles")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Preguntar a Ruul. Próximamente.")
        } header: {
            Label("Acciones rápidas", systemImage: "bolt.fill")
                .font(.subheadline)
        } footer: {
            Text("Buscar global y \"Preguntar a Ruul\" llegarán en un slice futuro.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Sección 4: Actividad relevante

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

// MARK: - Fallback view cuando el contexto no está disponible

private struct ContextNotAvailableView: View {
    let contextName: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.fill")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Contexto no disponible")
                .font(.title3.weight(.semibold))
            Text("Ya no puedes acceder a \(contextName).")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Cerrar") { dismiss() }
                .buttonStyle(.bordered)
        }
        .padding()
    }
}

#Preview("Home (demo)") {
    HomeView(container: .demo(), jumpToContext: { _ in }, onTriggerCreate: {})
}
