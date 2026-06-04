import SwiftUI
import RuulCore

/// Editar el perfil del usuario (`update_my_profile`): nombre completo y
/// nombre corto. El nombre corto es el `display_name` que ven los demás.
public struct EditProfileView: View {
    let container: DependencyContainer

    @Environment(\.dismiss) private var dismiss
    @State private var fullName = ""
    @State private var preferredName = ""
    @State private var runner = ActionRunner()

    public init(container: DependencyContainer) {
        self.container = container
    }

    private var actorStore: CurrentActorStore { container.currentActorStore }

    private var displayedName: String {
        let preferred = preferredName.trimmingCharacters(in: .whitespaces)
        let full = fullName.trimmingCharacters(in: .whitespaces)
        if !preferred.isEmpty { return preferred }
        if !full.isEmpty { return full }
        return actorStore.actor?.displayName ?? "?"
    }

    private var canSave: Bool {
        let preferred = preferredName.trimmingCharacters(in: .whitespaces)
        let full = fullName.trimmingCharacters(in: .whitespaces)
        guard !preferred.isEmpty || !full.isEmpty else { return false }
        return preferred != (actorStore.actor?.profile?.preferredName ?? "")
            || full != (actorStore.actor?.profile?.fullName ?? "")
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        ActorInitialsView(name: displayedName, size: 72)
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }

                Section {
                    TextField("Nombre completo", text: $fullName)
                        .textContentType(.name)
                    TextField("¿Cómo te dicen?", text: $preferredName)
                        .textContentType(.nickname)
                } header: {
                    Text("Tu nombre")
                } footer: {
                    Text("El nombre corto es el que ven los demás en tus contextos.")
                }

                if let profile = actorStore.actor?.profile {
                    accountSection(profile)
                }
            }
            .navigationTitle("Tu perfil")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await save() }
                    } label: {
                        if runner.isRunning {
                            ProgressView()
                        } else {
                            Text("Guardar")
                        }
                    }
                    .disabled(!canSave || runner.isRunning)
                }
            }
            .actionErrorAlert(runner)
            .interactiveDismissDisabled(runner.isRunning)
            .onAppear(perform: populate)
        }
        .ruulSheet()
    }

    @ViewBuilder
    private func accountSection(_ profile: PersonProfile) -> some View {
        let phone = profile.phone ?? ""
        let email = profile.email ?? ""
        if !phone.isEmpty || !email.isEmpty {
            Section {
                if !phone.isEmpty {
                    InfoRow(symbolName: "phone", title: phone)
                }
                if !email.isEmpty {
                    InfoRow(symbolName: "envelope", title: email)
                }
            } header: {
                Text("Cuenta")
            } footer: {
                Text("Tu teléfono y correo vienen de tu inicio de sesión.")
            }
        }
    }

    private func populate() {
        fullName = actorStore.actor?.profile?.fullName ?? ""
        preferredName = actorStore.actor?.profile?.preferredName ?? ""
    }

    private func save() async {
        let preferred = preferredName.trimmingCharacters(in: .whitespaces)
        let full = fullName.trimmingCharacters(in: .whitespaces)
        let success = await runner.run {
            try await actorStore.updateProfile(
                fullName: full.isEmpty ? nil : full,
                preferredName: preferred.isEmpty ? nil : preferred
            )
        }
        if success { dismiss() }
    }
}

#Preview("Editar perfil") {
    EditProfileView(container: .demo())
}
