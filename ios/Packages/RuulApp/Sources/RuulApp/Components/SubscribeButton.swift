import SwiftUI
import RuulCore

/// R.3A — Sección "Mi señal" reutilizable. Muestra el estado actual de la
/// suscripción del caller a un target y permite cambiar el tipo (watch /
/// follow / stakeholder / audit / owner_interest) o cancelar. iOS NUNCA
/// decide el "score" del feed — sólo escribe la intención del usuario.
public struct SubscribeSection: View {
    let targetType: SubscriptionTargetType
    let targetId: UUID
    let store: SubscriptionsStore
    @State private var runner = ActionRunner()

    public init(targetType: SubscriptionTargetType, targetId: UUID, store: SubscriptionsStore) {
        self.targetType = targetType
        self.targetId = targetId
        self.store = store
    }

    private var current: Subscription? {
        store.current(targetType: targetType, targetId: targetId)
    }

    public var body: some View {
        Section {
            if let sub = current {
                HStack {
                    Label(sub.subscriptionType.label, systemImage: symbol(for: sub.subscriptionType))
                        .font(.callout)
                    Spacer()
                    Menu {
                        ForEach(SubscriptionType.allCases, id: \.self) { type in
                            Button {
                                Task { await change(to: type) }
                            } label: {
                                if type == sub.subscriptionType {
                                    Label(type.label, systemImage: "checkmark")
                                } else {
                                    Text(type.label)
                                }
                            }
                        }
                        Divider()
                        Button(role: .destructive) {
                            Task { await unsubscribe(sub) }
                        } label: {
                            Label("Dejar de seguir", systemImage: "bell.slash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.title3)
                    }
                    .accessibilityLabel("Cambiar tipo de seguimiento")
                }
            } else {
                Menu {
                    ForEach(SubscriptionType.allCases, id: \.self) { type in
                        Button {
                            Task { await change(to: type) }
                        } label: {
                            Label(type.label, systemImage: symbol(for: type))
                        }
                    }
                } label: {
                    Label("Seguir", systemImage: "bell.badge")
                        .font(.callout)
                }
                .disabled(runner.isRunning)
            }
            // R.3A.2 — atajo dedicado a "Soy parte interesada" (RPC
            // mark_as_stakeholder). Aparece cuando el caller no es ya
            // stakeholder/owner_interest; tap eleva la sub a stakeholder.
            if shouldShowStakeholderShortcut {
                Button {
                    Task { await markStakeholder() }
                } label: {
                    Label("Soy parte interesada", systemImage: "star.fill")
                        .font(.callout)
                        .foregroundStyle(.yellow)
                }
                .disabled(runner.isRunning)
            }
        } header: {
            Text("Mi señal")
        } footer: {
            if let sub = current {
                Text(footer(for: sub.subscriptionType))
            } else {
                Text("Recibe las novedades en \"Mi Actividad\" cuando ocurra algo aquí.")
            }
        }
        .actionErrorAlert(runner)
    }

    private var shouldShowStakeholderShortcut: Bool {
        // Si ya es stakeholder o owner_interest, no tiene sentido el shortcut.
        switch current?.subscriptionType {
        case .stakeholder, .ownerInterest: return false
        default:                           return true
        }
    }

    private func markStakeholder() async {
        await runner.run {
            try await store.markAsStakeholder(targetType: targetType, targetId: targetId)
        }
    }

    private func change(to type: SubscriptionType) async {
        await runner.run {
            try await store.subscribe(
                targetType: targetType,
                targetId: targetId,
                subscriptionType: type
            )
        }
    }

    private func unsubscribe(_ sub: Subscription) async {
        await runner.run {
            try await store.unsubscribe(subscriptionId: sub.id)
        }
    }

    private func symbol(for type: SubscriptionType) -> String {
        switch type {
        case .watch:         return "eye"
        case .follow:        return "bell"
        case .stakeholder:   return "star.fill"
        case .audit:         return "doc.text.magnifyingglass"
        case .ownerInterest: return "crown"
        }
    }

    private func footer(for type: SubscriptionType) -> String {
        switch type {
        case .watch:         return "Lo verás en Mi Actividad junto con todo lo que sigues."
        case .follow:        return "Te avisamos de cualquier novedad."
        case .stakeholder:   return "Marcado como parte interesada — prioridad alta en tu feed."
        case .audit:         return "Auditas este elemento — incluido también en revisiones."
        case .ownerInterest: return "Interés de dueño — máxima prioridad en tu feed."
        }
    }
}

#Preview("Sin sub") {
    Form {
        SubscribeSection(
            targetType: .resource,
            targetId: MockRuulRPCClient.DemoIds.casaValle,
            store: SubscriptionsStore(rpc: MockRuulRPCClient.demo())
        )
    }
}
