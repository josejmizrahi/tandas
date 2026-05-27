import SwiftUI
import RuulCore

/// Invite-by-email-or-phone form. After a successful `invite_member`
/// call, the dev backend sends the redemption code out-of-band (SMS or
/// email). The inviter only sees a confirmation — Foundation doesn't
/// have a "list pending invites with code" RPC yet.
struct InviteMemberSheet: View {
    let container: DependencyContainer
    let groupId: UUID
    let onSubmitted: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var method: Method = .email
    @State private var email: String = ""
    @State private var phone: String = "+52"
    @State private var message: String = ""
    @State private var isSubmitting: Bool = false
    @State private var error: UserFacingError?
    @State private var showSuccess: Bool = false

    private enum Method: String, CaseIterable, Identifiable {
        case email, phone
        var id: String { rawValue }
        var label: String { self == .email ? "Email" : "Teléfono" }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Cómo invitar") {
                    Picker("Método", selection: $method) {
                        ForEach(Method.allCases) { m in
                            Text(m.label).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                    switch method {
                    case .email:
                        TextField("correo@ejemplo.com", text: $email)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    case .phone:
                        TextField("+52 ...", text: $phone)
                            .keyboardType(.phonePad)
                            .textContentType(.telephoneNumber)
                    }
                }

                Section("Mensaje (opcional)") {
                    TextField("Agrega un mensaje…", text: $message, axis: .vertical)
                        .lineLimit(2...5)
                }
            }
            .navigationTitle("Invitar a alguien")
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
                            Text("Enviar")
                        }
                    }
                    .disabled(!isFormValid || isSubmitting)
                }
            }
            .alert("Invitación enviada", isPresented: $showSuccess) {
                Button("OK") {
                    onSubmitted()
                }
            } message: {
                Text("Recibirán un código por \(method == .email ? "correo" : "SMS").")
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
        switch method {
        case .email:
            return email.contains("@") && email.contains(".")
        case .phone:
            return phone.count >= 10
        }
    }

    private func submit() async {
        isSubmitting = true
        defer { isSubmitting = false }
        let messageClean = message.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        do {
            _ = try await container.inviteRepository.inviteMember(
                groupId: groupId,
                email: method == .email ? email.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
                phone: method == .phone ? phone.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
                membershipType: "member",
                message: messageClean
            )
            showSuccess = true
        } catch {
            self.error = UserFacingError.from(error)
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
