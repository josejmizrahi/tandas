import SwiftUI
import RuulCore

/// F.6 — otorgar un derecho sobre un recurso a un miembro del contexto.
public struct GrantRightSheet: View {
    let resource: Resource
    let context: AppContext
    let container: DependencyContainer
    let onGranted: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var membersStore: MembersStore
    @State private var selectedActorId: UUID?
    @State private var rightKind: RightKind = .use
    @State private var runner = ActionRunner()

    public init(resource: Resource, context: AppContext, container: DependencyContainer, onGranted: @escaping () -> Void) {
        self.resource = resource
        self.context = context
        self.container = container
        self.onGranted = onGranted
        _membersStore = State(initialValue: MembersStore(rpc: container.rpc))
    }

    /// Derechos que la UI expone para otorgar (los ejecutivos como SELL/
    /// TRANSFER/LIEN se quedan en el backend para fases posteriores).
    private static let grantableKinds: [RightKind] = [.use, .manage, .view, .beneficiary, .govern]

    public var body: some View {
        NavigationStack {
            Form {
                Section("A quién") {
                    if membersStore.members.isEmpty {
                        Text("Cargando miembros…")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(membersStore.members) { member in
                            Button {
                                selectedActorId = member.actorId
                            } label: {
                                HStack {
                                    ActorInitialsView(name: member.displayName, size: 30)
                                    Text(member.displayName)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    if selectedActorId == member.actorId {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.tint)
                                    }
                                }
                            }
                        }
                    }
                }

                Section("Qué derecho") {
                    Picker("Derecho", selection: $rightKind) {
                        ForEach(Self.grantableKinds) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                Section {
                    Button {
                        Task { await grant() }
                    } label: {
                        if runner.isRunning {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Text("Otorgar").frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(selectedActorId == nil || runner.isRunning)
                } footer: {
                    // 7.E.2 (audit 2026-06-14) — hint inline cuando falta elegir
                    // a quién, en lugar de botón disabled mudo.
                    if selectedActorId == nil {
                        Label("Elige a quién le vas a otorgar el derecho.", systemImage: "exclamationmark.circle")
                            .font(.caption)
                            .foregroundStyle(Theme.Tint.warning)
                    } else {
                        Text(footerText)
                    }
                }
            }
            .navigationTitle("Otorgar derecho")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
            }
            .task {
                await membersStore.load(context: context)
            }
            .actionErrorAlert(runner)
        }
        .ruulSheet()
    }

    private var footerText: String {
        switch rightKind {
        case .use: return "Podrá usar y solicitar reservaciones de \(resource.displayName)."
        case .manage: return "Podrá administrar \(resource.displayName) y otorgar derechos no ejecutivos."
        case .view: return "Solo podrá ver \(resource.displayName); no podrá reservarlo."
        case .beneficiary: return "Queda registrado como beneficiario de \(resource.displayName)."
        case .govern: return "Podrá gobernar las decisiones sobre \(resource.displayName)."
        default: return ""
        }
    }

    private func grant() async {
        guard let selectedActorId else { return }
        let success = await runner.run {
            _ = try await container.rpc.grantRight(GrantRightInput(
                resourceId: resource.id,
                holderActorId: selectedActorId,
                rightKind: rightKind
            ))
        }
        if success {
            onGranted()
            dismiss()
        }
    }
}

#Preview("Otorgar derecho") {
    GrantRightSheet(
        resource: Resource(
            id: MockRuulRPCClient.DemoIds.casaValle,
            resourceType: "house",
            displayName: "Casa Valle"
        ),
        context: AppContext(
            id: MockRuulRPCClient.DemoIds.familia,
            kind: .collective,
            subtype: "family",
            displayName: "Familia Mizrahi"
        ),
        container: .demo(),
        onGranted: {}
    )
}
