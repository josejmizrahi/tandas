import SwiftUI
import RuulCore
import Contacts
import ContactsUI

/// V3-INV Invite-by-email-or-phone form with three usability upgrades:
///
/// 1. **Pick from Contacts**: tap the contacts icon to open the system
///    contact picker (`CNContactPickerViewController`) and auto-fill the
///    selected name + email or phone.
/// 2. **Share the code**: after a successful `invite_member` the sheet
///    flips into a "Listo" screen showing the redemption code and a
///    `ShareLink` for the native share sheet (Messages / WhatsApp / Mail
///    / copy / etc.).
/// 3. **Placeholder membership**: the V3-R0 backend creates a
///    `group_memberships` row with `status='invited'` so the invitee
///    can be a payer/participant in splits before they accept. The
///    sheet copy reflects that ("Ya puedes incluirla en gastos.").
struct InviteMemberSheet: View {
    let container: DependencyContainer
    let groupId: UUID
    let onSubmitted: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var method: Method = .phone
    @State private var contactName: String = ""
    @State private var email: String = ""
    @State private var phone: String = "+52"
    @State private var message: String = ""
    @State private var isSubmitting: Bool = false
    @State private var error: UserFacingError?
    @State private var isPresentingContacts: Bool = false

    /// V3-INV — once the invite is created the sheet flips into the
    /// "Listo" state with code + share affordance. Nil = form mode.
    @State private var created: InviteCreated?

    private enum Method: String, CaseIterable, Identifiable {
        case phone, email
        var id: String { rawValue }
        var label: String { self == .phone ? "Teléfono" : "Email" }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let created {
                    successView(created: created)
                } else {
                    formView
                }
            }
            .navigationTitle(created == nil ? "Invitar a alguien" : "Invitación lista")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if created == nil {
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
                } else {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Listo") {
                            onSubmitted()
                            dismiss()
                        }
                    }
                }
            }
            .sheet(isPresented: $isPresentingContacts) {
                ContactsPickerView { contact in
                    apply(contact: contact)
                }
                .ignoresSafeArea()
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

    // MARK: - Form mode

    @ViewBuilder
    private var formView: some View {
        Form {
            Section {
                Button {
                    isPresentingContacts = true
                } label: {
                    Label("Escoger de Contactos", systemImage: "person.crop.circle.badge.plus")
                }
            } footer: {
                Text("Importa nombre y teléfono o correo directamente desde tu libreta de contactos.")
                    .font(.footnote)
            }

            Section("Cómo invitar") {
                Picker("Método", selection: $method) {
                    ForEach(Method.allCases) { m in
                        Text(m.label).tag(m)
                    }
                }
                .pickerStyle(.segmented)

                if !contactName.isEmpty {
                    LabeledContent("Nombre") {
                        Text(contactName).foregroundStyle(.secondary)
                    }
                }

                switch method {
                case .phone:
                    TextField("+52 ...", text: $phone)
                        .keyboardType(.phonePad)
                        .textContentType(.telephoneNumber)
                case .email:
                    TextField("correo@ejemplo.com", text: $email)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }

            Section("Mensaje (opcional)") {
                TextField("Agrega un mensaje…", text: $message, axis: .vertical)
                    .lineLimit(2...5)
            }
        }
    }

    // MARK: - Success mode

    @ViewBuilder
    private func successView(created: InviteCreated) -> some View {
        let shareText = composedShareText(code: created.code)
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Código")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(created.code)
                        .font(.system(.title2, design: .monospaced).weight(.semibold))
                        .textSelection(.enabled)
                }
                .padding(.vertical, 4)
            } footer: {
                Text("Caduca en 14 días. Compártelo por el canal que prefieras.")
                    .font(.footnote)
            }

            Section {
                ShareLink(item: shareText) {
                    Label("Compartir invitación", systemImage: "square.and.arrow.up")
                }
                Button {
                    UIPasteboard.general.string = shareText
                } label: {
                    Label("Copiar texto + código", systemImage: "doc.on.doc")
                }
                Button {
                    UIPasteboard.general.string = created.code
                } label: {
                    Label("Copiar sólo el código", systemImage: "number.square")
                }
            }

            if created.placeholderMembershipId != nil {
                Section {
                    Label {
                        Text("Ya puedes incluirla en gastos del grupo sin esperar a que acepte. Cuando lo haga, su balance se reconcilia automático.")
                    } icon: {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.tint)
                    }
                    .font(.subheadline)
                }
            }
        }
    }

    /// V3-DOMAIN — share text bundles a Universal Link
    /// (`https://ruul.mx/invite/CODE`) so a tap from WhatsApp / Messages
    /// / Mail opens the app straight into `AcceptInviteSheet` with the
    /// code pre-filled. The fallback raw code is included in case the
    /// recipient is reading from somewhere that strips URLs.
    private func composedShareText(code: String) -> String {
        let prefix = "Te invité a un grupo en Ruul. Únete con este link:"
        let url = "https://ruul.mx/invite/\(code)"
        let fallback = "O usa el código: \(code)"
        return "\(prefix)\n\n\(url)\n\n\(fallback)"
    }

    // MARK: - Validation

    private var isFormValid: Bool {
        switch method {
        case .email:
            let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.contains("@") && trimmed.contains(".")
        case .phone:
            let trimmed = phone.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.count >= 10
        }
    }

    // MARK: - Submit

    private func submit() async {
        isSubmitting = true
        defer { isSubmitting = false }
        let messageClean = message.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        do {
            let result = try await container.inviteRepository.inviteMember(
                groupId: groupId,
                email: method == .email ? email.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
                phone: method == .phone ? phone.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
                membershipType: "member",
                message: messageClean
            )
            created = result
        } catch {
            self.error = UserFacingError.from(error)
        }
    }

    // MARK: - Contacts picker handler

    private func apply(contact: CNContact) {
        contactName = [contact.givenName, contact.familyName]
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        // Prefer phone over email when both are present — Ruul's
        // OTP path is phone-first.
        if let firstPhone = contact.phoneNumbers.first?.value.stringValue,
           !firstPhone.isEmpty {
            phone = firstPhone
            method = .phone
        } else if let firstEmail = contact.emailAddresses.first?.value as String?,
                  !firstEmail.isEmpty {
            email = firstEmail
            method = .email
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - ContactsPickerView (UIKit bridge)

/// Wraps `CNContactPickerViewController` so SwiftUI can present it via
/// `.sheet`. Returns the picked `CNContact` to the caller; cancellation
/// just dismisses without firing the callback.
private struct ContactsPickerView: UIViewControllerRepresentable {
    let onPick: (CNContact) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    func makeUIViewController(context: Context) -> CNContactPickerViewController {
        let vc = CNContactPickerViewController()
        vc.delegate = context.coordinator
        // Restrict the visible properties for predictable picking.
        vc.displayedPropertyKeys = [
            CNContactPhoneNumbersKey,
            CNContactEmailAddressesKey
        ]
        return vc
    }

    func updateUIViewController(_ uiViewController: CNContactPickerViewController, context: Context) {}

    final class Coordinator: NSObject, CNContactPickerDelegate {
        let onPick: (CNContact) -> Void
        init(onPick: @escaping (CNContact) -> Void) { self.onPick = onPick }

        func contactPicker(_ picker: CNContactPickerViewController, didSelect contact: CNContact) {
            onPick(contact)
        }
    }
}
