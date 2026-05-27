import SwiftUI
import RuulCore

/// Redeem-a-code form. The invitee enters the code they received via
/// SMS/email and the dev `accept_invite` RPC joins them to the group
/// with the default role (canonical_followup_12).
struct AcceptInviteSheet: View {
    let container: DependencyContainer
    let onAccepted: (AcceptInviteResult) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var code: String = ""
    @State private var isSubmitting: Bool = false
    @State private var error: UserFacingError?

    var body: some View {
        NavigationStack {
            Form {
                Section("Tu código") {
                    TextField("Pega o escribe el código", text: $code)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                }

                Section {
                    Text("Lo recibiste por SMS o correo cuando te invitaron.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Aceptar invitación")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                        .disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await submit() }
                    } label: {
                        if isSubmitting {
                            ProgressView()
                        } else {
                            Text("Unirme")
                        }
                    }
                    .disabled(!isFormValid || isSubmitting)
                }
            }
            .alert(
                error?.title ?? "",
                isPresented: Binding(
                    get: { error != nil },
                    set: { if !$0 { error = nil } }
                ),
                actions: { Button("OK") { error = nil } },
                message: { Text(error?.message ?? "") }
            )
        }
    }

    private var isFormValid: Bool {
        !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit() async {
        isSubmitting = true
        defer { isSubmitting = false }
        let cleaned = code.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let result = try await container.inviteRepository.acceptInvite(code: cleaned)
            onAccepted(result)
        } catch {
            self.error = UserFacingError.from(error)
        }
    }
}
