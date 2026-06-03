import SwiftUI
import RuulCore

/// F.5 — generar y compartir un código de invitación al contexto.
public struct InviteMembersView: View {
    let context: AppContext
    let store: MembersStore

    @Environment(\.dismiss) private var dismiss
    @State private var invite: InviteCreated?
    @State private var runner = ActionRunner()
    @State private var limitUses = false
    @State private var maxUses = 5

    public init(context: AppContext, store: MembersStore) {
        self.context = context
        self.store = store
    }

    public var body: some View {
        NavigationStack {
            Form {
                if let invite {
                    Section("Código de invitación") {
                        HStack {
                            Text(invite.code)
                                .font(.system(.title, design: .monospaced).weight(.bold))
                                .frame(maxWidth: .infinity)
                                .textSelection(.enabled)
                        }
                        .padding(.vertical, 8)

                        ShareLink(item: shareMessage(invite)) {
                            Label("Compartir invitación", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                    }

                    Section {
                        Button("Generar otro código") {
                            self.invite = nil
                        }
                    }
                } else {
                    Section("Opciones") {
                        Toggle("Limitar usos", isOn: $limitUses)
                        if limitUses {
                            Stepper("Máximo \(maxUses) personas", value: $maxUses, in: 1...50)
                        }
                    }

                    Section {
                        Button {
                            Task { await generate() }
                        } label: {
                            if runner.isRunning {
                                ProgressView().frame(maxWidth: .infinity)
                            } else {
                                Label("Generar código", systemImage: "ticket")
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .disabled(runner.isRunning)
                    } footer: {
                        Text("Cualquier persona con el código puede unirse a \(context.displayName) como miembro.")
                    }
                }
            }
            .navigationTitle("Invitar miembros")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cerrar") { dismiss() }
                }
            }
            .actionErrorAlert(runner)
        }
    }

    private func generate() async {
        await runner.run {
            invite = try await store.createInvite(
                contextId: context.id,
                maxUses: limitUses ? maxUses : nil
            )
        }
    }

    private func shareMessage(_ invite: InviteCreated) -> String {
        "Únete a \(context.displayName) en Ruul con el código: \(invite.code)"
    }
}

#Preview("Invitar") {
    InviteMembersView(
        context: AppContext(
            id: MockRuulRPCClient.DemoIds.cenaSemanal,
            kind: .collective,
            subtype: "friend_group",
            displayName: "Cena Semanal"
        ),
        store: MembersStore(rpc: MockRuulRPCClient.demo())
    )
}
