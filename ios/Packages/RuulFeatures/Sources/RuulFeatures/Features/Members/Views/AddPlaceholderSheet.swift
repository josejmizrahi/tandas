import SwiftUI
import RuulUI
import RuulCore

/// Sheet shown from MembersListView (admin path) to create a placeholder
/// member with (name, phone). Calls `create-placeholder-member` edge fn
/// (mig 00315). Handles the three server responses:
///   - created → dismiss and bubble up `onCreated(memberId)`
///   - existing_user → message: ese teléfono ya es usuario, agrégalo
///     directo desde "Invitar miembros"
///   - duplicate_placeholder → message: ya hay otro pendiente con ese phone
@MainActor
public struct AddPlaceholderSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    public let group: RuulCore.Group
    public let onCreated: (UUID) -> Void

    @State private var displayName: String
    @State private var phone: String
    @State private var isWorking = false
    @State private var existingUser: (id: UUID, name: String?)?
    @State private var duplicatePlaceholder: UUID?
    @State private var errorMessage: String?

    /// `prefillName` and `prefillPhone` let upstream flows (the Contacts
    /// picker, sharesheet drop, paste detection) seed the form so the
    /// admin doesn't retype anything. Both are optional; either or both
    /// can be nil for the manual entry path.
    public init(
        group: RuulCore.Group,
        prefillName: String? = nil,
        prefillPhone: String? = nil,
        onCreated: @escaping (UUID) -> Void
    ) {
        self.group = group
        self.onCreated = onCreated
        self._displayName = State(initialValue: prefillName ?? "")
        self._phone = State(initialValue: prefillPhone ?? "")
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: RuulSpacing.lg) {
                    intro
                    form
                    if let existingUser { existingUserCard(existingUser) }
                    if duplicatePlaceholder != nil { duplicateCard }
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(Color.red)
                    }
                }
                .padding(RuulSpacing.lg)
            }
            .background(Color.ruulBackground.ignoresSafeArea())
            .ruulSheetToolbar("Agregar pendiente")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: submit) {
                        if isWorking { ProgressView() } else { Text("Agregar") }
                    }
                    .disabled(!canSubmit || isWorking)
                }
            }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text("Agrega a alguien que aún no está en Ruul")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color(.tertiaryLabel))
            Text("Ya cuenta para turnos, RSVP, fines y votos. Cuando active su cuenta, su historial se une al suyo.")
                .font(.footnote)
                .foregroundStyle(Color.secondary)
        }
    }

    private var form: some View {
        VStack(spacing: RuulSpacing.md) {
            TextField("Nombre", text: $displayName)
                .textContentType(.name)
                .textInputAutocapitalization(.words)
                .padding(RuulSpacing.md)
                .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.md))

            TextField("Teléfono (+52...)", text: $phone)
                .keyboardType(.phonePad)
                .textContentType(.telephoneNumber)
                .padding(RuulSpacing.md)
                .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.md))
        }
    }

    private func existingUserCard(_ user: (id: UUID, name: String?)) -> some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text("Ese número ya es usuario de Ruul")
                .font(.footnote)
                .foregroundStyle(Color.primary)
            Text("\(user.name ?? "Esta persona") ya tiene una cuenta. Para agregarla al grupo usa “Invitar miembros” con el código.")
                .font(.footnote)
                .foregroundStyle(Color.secondary)
        }
        .padding(RuulSpacing.md)
        .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.md))
    }

    private var duplicateCard: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text("Ya hay un miembro pendiente con ese número")
                .font(.footnote)
                .foregroundStyle(Color.primary)
            Text("Si esto es un error, revisa la lista de miembros para confirmar quién está pendiente.")
                .font(.footnote)
                .foregroundStyle(Color.secondary)
        }
        .padding(RuulSpacing.md)
        .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.md))
    }

    private var canSubmit: Bool {
        let trimmedName = displayName.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return false }
        guard phone.hasPrefix("+") else { return false }
        let digits = phone.dropFirst()
        return digits.count >= 8 && digits.allSatisfy { $0.isWholeNumber }
    }

    private func submit() {
        guard let repo = app.placeholderMemberRepo else {
            errorMessage = "Servicio no disponible en este entorno."
            return
        }
        isWorking = true
        existingUser = nil
        duplicatePlaceholder = nil
        errorMessage = nil
        let groupId = group.id
        let name = displayName.trimmingCharacters(in: .whitespaces)
        let e164 = phone
        Task {
            defer { isWorking = false }
            do {
                let result = try await repo.create(
                    groupId: groupId,
                    displayName: name,
                    phoneE164: e164
                )
                switch result {
                case .created(let memberId, _, _):
                    onCreated(memberId)
                    dismiss()
                case .existingUser(let uid, let displayName):
                    existingUser = (uid, displayName)
                case .duplicatePlaceholder(let uid):
                    duplicatePlaceholder = uid
                case .failed(let msg):
                    errorMessage = msg
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
