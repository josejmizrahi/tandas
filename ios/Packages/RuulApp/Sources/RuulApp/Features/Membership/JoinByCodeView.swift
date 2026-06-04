import SwiftUI
import RuulCore

/// F.5 — unirse a un contexto con un código de invitación.
public struct JoinByCodeView: View {
    let container: DependencyContainer

    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var runner = ActionRunner()
    @State private var joinedContextName: String?

    public init(container: DependencyContainer, prefilledCode: String? = nil) {
        self.container = container
        _code = State(initialValue: prefilledCode ?? "")
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Código de invitación", text: $code)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.title3.monospaced())
                        .multilineTextAlignment(.center)
                } footer: {
                    Text("Pídele el código a quien administra el contexto.")
                }

                Section {
                    Button {
                        Task { await join() }
                    } label: {
                        if runner.isRunning {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Text("Unirme").frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(code.trimmingCharacters(in: .whitespaces).isEmpty || runner.isRunning)
                }

                if let joinedContextName {
                    Section {
                        Label("Te uniste a \(joinedContextName)", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
            }
            .navigationTitle("Unirme con código")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
            }
            .actionErrorAlert(runner)
        }
        .ruulSheet()
    }

    private func join() async {
        let success = await runner.run {
            let result = try await container.rpc.joinByInviteCode(code.trimmingCharacters(in: .whitespaces))
            joinedContextName = result.context.displayName
            await container.contextStore.load()
            if let new = container.contextStore.availableContexts.first(where: { $0.id == result.contextActorId }) {
                container.contextStore.switchTo(new)
            }
        }
        if success {
            try? await Task.sleep(for: .seconds(1))
            dismiss()
        }
    }
}

#Preview("Unirme con código") {
    JoinByCodeView(container: .demo())
}
