import SwiftUI
import RuulUI
import RuulCore

/// Sheet para editar el perfil propio del usuario. V1 permite cambiar
/// solo el `displayName`. Avatar URL + phone reservados para fases futuras
/// cuando `ProfileRepository` los soporte.
public struct EditProfileSheet: View {
    public let coordinator: ProfileCoordinator

    @State private var draftName: String
    @State private var isSaving: Bool = false

    @Environment(\.dismiss) private var dismiss

    public init(coordinator: ProfileCoordinator) {
        self.coordinator = coordinator
        self._draftName = State(initialValue: coordinator.profile?.displayName ?? "")
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        RuulPersonAvatar(
                            name: avatarName,
                            imageURL: avatarURL,
                            size: .hero
                        )
                        Spacer()
                    }
                    .padding(.vertical, RuulSpacing.md)
                    .listRowBackground(Color.clear)
                }

                Section("Nombre") {
                    TextField("Tu nombre", text: $draftName)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                }

                if let error = coordinator.error {
                    Section {
                        Text(error.message ?? error.title)
                            .ruulTextStyle(RuulTypography.caption)
                            .foregroundStyle(Color.ruulNegative)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Editar perfil")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Guardar") {
                        Task { await save() }
                    }
                    .bold()
                    .disabled(!canSave || isSaving)
                }
            }
            .interactiveDismissDisabled(isSaving)
            .onChange(of: coordinator.error?.title) { _, newError in
                if newError != nil { isSaving = false }
            }
        }
    }

    // MARK: - Derived state

    private var canSave: Bool {
        let trimmed = draftName.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && trimmed != coordinator.profile?.displayName
    }

    /// Para el avatar fallback (gradient + iniciales): preferimos el draft
    /// para que el preview vaya cambiando mientras el user escribe; cae al
    /// displayName actual si el draft está vacío.
    private var avatarName: String {
        let trimmed = draftName.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return trimmed }
        return coordinator.profile?.displayName ?? "?"
    }

    private var avatarURL: URL? {
        coordinator.profile?.avatarUrl.flatMap(URL.init(string:))
    }

    // MARK: - Actions

    private func save() async {
        isSaving = true
        coordinator.clearError()
        await coordinator.updateDisplayName(draftName)
        if coordinator.error == nil {
            isSaving = false
            dismiss()
        }
        // Si error sigue set, isSaving lo apaga el .onChange de arriba.
    }
}

#if DEBUG
#Preview("EditProfileSheet") {
    let coord = ProfileCoordinator(
        userId: UUID(),
        profileRepo: MockProfileRepository(seed: Profile(
            id: UUID(),
            displayName: "José Mizrahi",
            avatarUrl: nil,
            phone: nil
        )),
        fineRepo: MockFineRepository()
    )
    return Color.ruulBackground.ignoresSafeArea()
        .sheet(isPresented: .constant(true)) {
            EditProfileSheet(coordinator: coord)
        }
}
#endif
