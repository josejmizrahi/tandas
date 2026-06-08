import SwiftUI
import RuulCore

/// F.NAV.6 — Lista plana de las suscripciones del caller. Reusa el
/// `SubscriptionsStore` long-lived del container.
public struct MySubscriptionsView: View {
    let container: DependencyContainer

    public init(container: DependencyContainer) {
        self.container = container
    }

    private var store: SubscriptionsStore { container.subscriptionsStore }

    public var body: some View {
        Group {
            switch store.phase {
            case .idle, .loading:
                LoadingStateView()
            case .failed(let message):
                ErrorStateView(message: message) {
                    Task { await store.load() }
                }
            case .loaded:
                if store.subscriptions.isEmpty {
                    ContentUnavailableView(
                        "Sin suscripciones",
                        systemImage: "antenna.radiowaves.left.and.right",
                        description: Text("Cuando te suscribes a un recurso o decisión, aparece aquí.")
                    )
                } else {
                    List {
                        Section {
                            ForEach(store.subscriptions) { sub in
                                row(sub)
                            }
                        } header: {
                            Text("\(store.subscriptions.count) suscripción\(store.subscriptions.count == 1 ? "" : "es")")
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
        }
        .navigationTitle("Mis suscripciones")
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.load() }
        .refreshable { await store.load() }
    }

    @ViewBuilder
    private func row(_ sub: Subscription) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(sub.targetDisplayName ?? targetTypeLabel(sub.targetType))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Theme.Text.primary)
                Text("\(targetTypeLabel(sub.targetType)) · \(sub.subscriptionType.label)")
                    .font(.caption)
                    .foregroundStyle(Theme.Text.secondary)
            }
        } icon: {
            Image(systemName: symbol(for: sub.targetType))
                .foregroundStyle(Theme.Tint.primary)
        }
    }

    private func symbol(for target: SubscriptionTargetType) -> String {
        switch target {
        case .resource:   return "shippingbox.fill"
        case .decision:   return "checkmark.bubble.fill"
        case .event:      return "calendar.badge.clock"
        case .obligation: return "creditcard.fill"
        case .actor:      return "person.crop.circle"
        case .context:    return "rectangle.split.2x1.fill"
        }
    }

    private func targetTypeLabel(_ target: SubscriptionTargetType) -> String {
        switch target {
        case .resource:   return "Recurso"
        case .decision:   return "Decisión"
        case .event:      return "Evento"
        case .obligation: return "Obligación"
        case .actor:      return "Persona"
        case .context:    return "Contexto"
        }
    }
}

#Preview("Subscriptions (demo)") {
    NavigationStack {
        MySubscriptionsView(container: .demo())
    }
}
