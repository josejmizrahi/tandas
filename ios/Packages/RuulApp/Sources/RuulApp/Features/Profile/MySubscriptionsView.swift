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
                        ForEach(store.subscriptions) { sub in
                            row(sub)
                        }
                    }
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
        HStack(spacing: 12) {
            Image(systemName: symbol(for: sub.targetType))
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(sub.targetDisplayName ?? targetTypeLabel(sub.targetType))
                    .font(.callout.weight(.medium))
                HStack(spacing: 6) {
                    Text(targetTypeLabel(sub.targetType))
                    Text("·")
                    Text(sub.subscriptionType.label)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
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
