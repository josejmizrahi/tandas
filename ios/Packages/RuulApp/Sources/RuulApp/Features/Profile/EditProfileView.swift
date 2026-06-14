import SwiftUI
import PhotosUI
import RuulCore

/// Editar el perfil del usuario (`update_my_profile`): nombre completo,
/// nombre corto y foto (P1.2 — sube a Storage `avatars/` y guarda la URL).
/// El nombre corto es el `display_name` que ven los demás.
public struct EditProfileView: View {
    let container: DependencyContainer

    @Environment(\.dismiss) private var dismiss
    @State private var fullName = ""
    @State private var preferredName = ""
    @State private var runner = ActionRunner()
    // P1.2 — avatar
    @State private var photoItem: PhotosPickerItem?
    @State private var pickedImageData: Data?

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

    /// 7.B.4 (audit 2026-06-14) — antes el botón Guardar quedaba disabled si
    /// ambos nombres estaban vacíos, incluso si solo se cambió la foto. Ahora
    /// permitimos guardar solo avatar mientras exista al menos un nombre
    /// guardado previo (no se puede crear cuenta sin nombre, pero sí cambiar
    /// solo la foto si la cuenta ya existía).
    private var canSave: Bool {
        let preferred = preferredName.trimmingCharacters(in: .whitespaces)
        let full = fullName.trimmingCharacters(in: .whitespaces)
        let storedPreferred = actorStore.actor?.profile?.preferredName ?? ""
        let storedFull = actorStore.actor?.profile?.fullName ?? ""

        // Hay foto nueva, y la cuenta tiene al menos un nombre persistido: OK.
        if pickedImageData != nil && (!storedPreferred.isEmpty || !storedFull.isEmpty) {
            return true
        }
        // Cualquier cambio de nombre con al menos uno no-vacío: OK.
        guard !preferred.isEmpty || !full.isEmpty else { return false }
        return preferred != storedPreferred || full != storedFull
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 10) {
                        avatarPreview
                        PhotosPicker(selection: $photoItem, matching: .images) {
                            Text(pickedImageData == nil ? "Cambiar foto" : "Foto seleccionada ✓")
                                .font(.footnote.weight(.medium))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }
                .onChange(of: photoItem) {
                    Task {
                        guard let item = photoItem,
                              let data = try? await item.loadTransferable(type: Data.self),
                              let image = UIImage(data: data) else { return }
                        // Downscale a 512pt y JPEG (< 2MB, límite del bucket).
                        pickedImageData = image.ruulResized(maxDimension: 512)
                            .jpegData(compressionQuality: 0.8)
                    }
                }

                Section {
                    TextField("Nombre completo", text: $fullName)
                        .textContentType(.name)
                    TextField("¿Cómo te dicen?", text: $preferredName)
                        .textContentType(.nickname)
                } header: {
                    Text("Tu nombre")
                } footer: {
                    Text("El nombre corto es el que ven los demás en tus espacios.")
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
    private var avatarPreview: some View {
        if let data = pickedImageData, let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 72, height: 72)
                .clipShape(Circle())
        } else if let urlString = actorStore.actor?.profile?.avatarUrl,
                  let url = URL(string: urlString) {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                ActorInitialsView(name: displayedName, size: 72)
            }
            .frame(width: 72, height: 72)
            .clipShape(Circle())
        } else {
            ActorInitialsView(name: displayedName, size: 72)
        }
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
            var avatarUrl: String?
            if let data = pickedImageData, let actorId = actorStore.actorId {
                avatarUrl = try await container.rpc.uploadAvatar(
                    actorId: actorId, data: data, contentType: "image/jpeg"
                ).absoluteString
            }
            try await actorStore.updateProfile(
                fullName: full.isEmpty ? nil : full,
                preferredName: preferred.isEmpty ? nil : preferred,
                avatarUrl: avatarUrl
            )
        }
        if success { dismiss() }
    }
}

private extension UIImage {
    /// Reescala manteniendo proporción para que el lado mayor sea `maxDimension`.
    func ruulResized(maxDimension: CGFloat) -> UIImage {
        let largest = max(size.width, size.height)
        guard largest > maxDimension else { return self }
        let scale = maxDimension / largest
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        return UIGraphicsImageRenderer(size: newSize).image { _ in
            draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}

#Preview("Editar perfil") {
    EditProfileView(container: .demo())
}
