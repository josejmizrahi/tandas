import SwiftUI
import RuulCore

/// F.NAV.6 — Red de confianza del caller. Outgoing (yo → otros) + Incoming
/// (otros → yo). Carga `list_trust_network(actor_id=nil)` que usa el actor
/// del caller por default (RLS gatea visibilidad).
public struct MyTrustNetworkView: View {
    let container: DependencyContainer

    @State private var network: TrustNetwork?
    @State private var phase: StorePhase = .idle

    public init(container: DependencyContainer) {
        self.container = container
    }

    public var body: some View {
        Group {
            switch phase {
            case .idle, .loading:
                RuulLoadingState()
            case .failed(let message):
                RuulErrorState(message: message) {
                    Task { await load() }
                }
            case .loaded:
                if let net = network, net.outgoing.isEmpty && net.incoming.isEmpty {
                    ContentUnavailableView(
                        "Tu red está vacía",
                        systemImage: "person.line.dotted.person",
                        description: Text("Aún no has declarado confianza con nadie.")
                    )
                } else if let net = network {
                    List {
                        if !net.outgoing.isEmpty {
                            Section("Confías en (\(net.outgoing.count))") {
                                ForEach(net.outgoing) { edge in
                                    Label {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(edge.targetDisplayName ?? "Persona")
                                                .font(.callout.weight(.medium))
                                                .foregroundStyle(Theme.Text.primary)
                                            Text("\(edge.trustType.label) · nivel \(edge.trustLevel)")
                                                .font(.caption)
                                                .foregroundStyle(Theme.Text.secondary)
                                        }
                                    } icon: {
                                        Image(systemName: "arrow.right.circle.fill")
                                            .foregroundStyle(Theme.Tint.primary)
                                    }
                                }
                            }
                        }
                        if !net.incoming.isEmpty {
                            Section("Confían en ti (\(net.incoming.count))") {
                                ForEach(net.incoming) { edge in
                                    Label {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(edge.sourceDisplayName ?? "Persona")
                                                .font(.callout.weight(.medium))
                                                .foregroundStyle(Theme.Text.primary)
                                            Text("\(edge.trustType.label) · nivel \(edge.trustLevel)")
                                                .font(.caption)
                                                .foregroundStyle(Theme.Text.secondary)
                                        }
                                    } icon: {
                                        Image(systemName: "arrow.left.circle.fill")
                                            .foregroundStyle(.indigo)
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
        }
        .navigationTitle("Mi red de confianza")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        if network == nil { phase = .loading }
        do {
            network = try await container.rpc.listTrustNetwork(actorId: nil)
            phase = .loaded
        } catch {
            phase = .failed(message: UserFacingError.from(error).message)
        }
    }
}

#Preview("Trust network (demo)") {
    NavigationStack {
        MyTrustNetworkView(container: .demo())
    }
}
