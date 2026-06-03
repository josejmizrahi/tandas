import SwiftUI
import RuulCore

/// F.6 — detalle de un recurso. Explica **por qué aparece aquí** (los
/// derechos activos: OWN / USE / MANAGE / VIEW / BENEFICIARY / …) y permite
/// otorgar derechos y navegar a reservaciones.
public struct ResourceDetailView: View {
    let resourceId: UUID
    let context: AppContext
    let container: DependencyContainer

    @State private var store: ResourceDetailStore
    @State private var isShowingGrantRight = false
    @State private var runner = ActionRunner()

    public init(resourceId: UUID, context: AppContext, container: DependencyContainer) {
        self.resourceId = resourceId
        self.context = context
        self.container = container
        _store = State(initialValue: ResourceDetailStore(rpc: container.rpc))
    }

    private var myActorId: UUID? { container.currentActorStore.actorId }

    public var body: some View {
        Group {
            switch store.phase {
            case .idle, .loading:
                LoadingStateView()

            case .failed(let message):
                ErrorStateView(message: message) {
                    Task { await store.load(resourceId: resourceId) }
                }

            case .loaded:
                if let detail = store.detail {
                    detailList(detail)
                }
            }
        }
        .navigationTitle(store.detail?.resource.displayName ?? "Recurso")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await store.load(resourceId: resourceId)
        }
        .refreshable {
            await store.load(resourceId: resourceId)
        }
        .refreshOnReappear(if: store.phase.isLoaded) {
            await store.load(resourceId: resourceId)
        }
        .sheet(isPresented: $isShowingGrantRight) {
            if let detail = store.detail {
                GrantRightSheet(resource: detail.resource, context: context, container: container) {
                    Task { await store.load(resourceId: resourceId) }
                }
            }
        }
        .actionErrorAlert(runner)
    }

    @ViewBuilder
    private func detailList(_ detail: ResourceDetail) -> some View {
        List {
            // Header
            Section {
                HStack(spacing: 16) {
                    Image(systemName: detail.resource.type.symbolName)
                        .font(.system(size: 32))
                        .foregroundStyle(.tint)
                        .frame(width: 56, height: 56)
                        .background(Color.accentColor.opacity(0.12), in: Circle())
                    VStack(alignment: .leading, spacing: 4) {
                        Text(detail.resource.displayName)
                            .font(.headline)
                        Text(detail.resource.type.label)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)

                if let description = detail.resource.description, !description.isEmpty {
                    Text(description)
                        .font(.body)
                }
                if let value = detail.resource.estimatedValue {
                    InfoRow(
                        symbolName: "banknote",
                        title: "Valor estimado",
                        value: value.currencyLabel(detail.resource.currency)
                    )
                }
            }

            // Por qué aparece aquí
            if let myActorId {
                let myRights = detail.reasons(for: myActorId)
                Section("Por qué lo ves") {
                    if myRights.isEmpty {
                        Label("Lo ves a través de \(context.displayName)", systemImage: "person.3")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(myRights) { right in
                            Label(right.kindLabel, systemImage: rightSymbol(right.rightKind))
                                .font(.callout)
                        }
                    }
                }
            }

            // Derechos activos
            Section("Derechos sobre este recurso") {
                ForEach(detail.rights) { right in
                    HStack {
                        Image(systemName: rightSymbol(right.rightKind))
                            .foregroundStyle(.tint)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(right.holderDisplayName ?? "Actor")
                            Text(right.kindLabel + (right.percent.map { " · \($0.formatted(.number))%" } ?? ""))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        StatusBadge(right.rightKind, color: rightColor(right.rightKind))
                    }
                    .swipeActions(edge: .trailing) {
                        Button("Revocar", role: .destructive) {
                            Task {
                                await runner.run {
                                    try await store.revokeRight(rightId: right.rightId, resourceId: resourceId)
                                }
                            }
                        }
                    }
                }

                Button {
                    isShowingGrantRight = true
                } label: {
                    Label("Otorgar derecho", systemImage: "plus")
                }
            }

            // Reservaciones
            Section {
                NavigationLink {
                    ReservationsListView(
                        resource: detail.resource,
                        context: context,
                        reservationContextId: governingContextId(detail),
                        container: container
                    )
                } label: {
                    Label("Reservaciones", systemImage: "calendar.badge.clock")
                }
            } footer: {
                Text("Quien tenga derecho de uso (USE/MANAGE/OWN) puede solicitar reservar este recurso.")
            }
        }
    }

    /// El contexto que gobierna las reservaciones del recurso: el holder del
    /// right GOVERN. Si no hay GOVERN, el contexto desde el que se navega.
    private func governingContextId(_ detail: ResourceDetail) -> UUID {
        detail.rights.first { $0.rightKind == "GOVERN" }?.holderActorId ?? context.id
    }

    private func rightSymbol(_ kind: String) -> String {
        switch RightKind(rawValue: kind) {
        case .own: return "crown.fill"
        case .use: return "hand.raised.fill"
        case .manage: return "gearshape.fill"
        case .view: return "eye.fill"
        case .govern: return "checkmark.seal.fill"
        case .beneficiary: return "gift.fill"
        case .sell, .transfer: return "arrow.left.arrow.right"
        case .lease: return "key.fill"
        case .lien: return "lock.fill"
        case .approve: return "checkmark.circle.fill"
        case .audit: return "doc.text.magnifyingglass"
        case .none: return "questionmark.circle"
        }
    }

    private func rightColor(_ kind: String) -> Color {
        switch RightKind(rawValue: kind) {
        case .own: return .purple
        case .use: return .blue
        case .manage: return .orange
        case .view: return .gray
        case .govern: return .indigo
        case .beneficiary: return .pink
        default: return .secondary
        }
    }
}

#Preview("Casa Valle") {
    NavigationStack {
        ResourceDetailView(
            resourceId: MockRuulRPCClient.DemoIds.casaValle,
            context: AppContext(
                id: MockRuulRPCClient.DemoIds.familia,
                kind: .collective,
                subtype: "family",
                displayName: "Familia Mizrahi",
                roles: ["admin"]
            ),
            container: .demo()
        )
    }
}
