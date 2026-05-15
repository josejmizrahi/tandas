import SwiftUI
import PhotosUI
import UIKit
import RuulUI
import RuulCore

/// Sheet para editar el perfil propio del usuario.
///
/// V1: nombre + avatar. `phone` y deletion siguen viviendo en flujos
/// dedicados (OTP re-verify, DataRightsSheet).
public struct EditProfileSheet: View {
    public let coordinator: ProfileCoordinator

    @State private var draftName: String
    @State private var isSaving: Bool = false
    @State private var photoItem: PhotosPickerItem?
    /// Preview optimista del avatar mientras subimos.
    @State private var pendingAvatar: UIImage?

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
                        avatarPicker
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
                        .disabled(isSaving || coordinator.isUploadingAvatar)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Guardar") {
                        Task { await save() }
                    }
                    .bold()
                    .disabled(!canSave || isSaving || coordinator.isUploadingAvatar)
                }
            }
            .interactiveDismissDisabled(isSaving || coordinator.isUploadingAvatar)
            .onChange(of: coordinator.error?.title) { _, newError in
                if newError != nil { isSaving = false }
            }
            .onChange(of: photoItem) { _, newItem in
                guard let newItem else { return }
                Task { await handlePickedItem(newItem) }
            }
        }
    }

    // MARK: - Avatar picker

    @ViewBuilder
    private var avatarPicker: some View {
        PhotosPicker(
            selection: $photoItem,
            matching: .images,
            photoLibrary: .shared()
        ) {
            ZStack {
                if let pending = pendingAvatar {
                    Image(uiImage: pending)
                        .resizable()
                        .scaledToFill()
                        .frame(width: RuulSize.avatarXLarge, height: RuulSize.avatarXLarge)
                        .clipShape(Circle())
                } else {
                    RuulPersonAvatar(
                        name: avatarName,
                        imageURL: avatarURL,
                        size: .hero
                    )
                }

                if coordinator.isUploadingAvatar {
                    Circle()
                        .fill(Color.black.opacity(0.35))
                        .frame(width: RuulSize.avatarXLarge, height: RuulSize.avatarXLarge)
                    ProgressView()
                        .tint(.white)
                }

                Image(systemName: "camera.fill")
                    .font(.system(size: RuulSize.iconSmall, weight: .semibold))
                    .foregroundStyle(Color.ruulTextInverse)
                    .padding(RuulSpacing.xs)
                    .background(Color.ruulTextPrimary, in: Circle())
                    .offset(x: RuulSize.avatarXLarge * 0.35, y: RuulSize.avatarXLarge * 0.35)
            }
        }
        .buttonStyle(.plain)
        .disabled(coordinator.isUploadingAvatar || isSaving)
        .accessibilityLabel("Cambiar foto de perfil")
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

    private func handlePickedItem(_ item: PhotosPickerItem) async {
        coordinator.clearError()
        guard let raw = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: raw) else {
            coordinator.error = nil
            return
        }
        // Optimistic preview + downscale + recompress as JPEG.
        let processed = image.ruul_downscaled(maxDimension: 1024)
        await MainActor.run { pendingAvatar = processed }
        guard let jpeg = processed.jpegData(compressionQuality: 0.85) else { return }
        await coordinator.updateAvatar(data: jpeg, contentType: "image/jpeg")
        // Reset selection so the same photo can be re-picked if the user wants
        // to retry after an error.
        photoItem = nil
        if coordinator.error != nil {
            pendingAvatar = nil  // upload failed → drop optimistic preview
        }
    }
}

// MARK: - UIImage helper

private extension UIImage {
    /// Returns a copy of the image whose largest dimension does not exceed
    /// `maxDimension`. Preserves aspect ratio. Returns `self` if already small.
    func ruul_downscaled(maxDimension: CGFloat) -> UIImage {
        let largest = max(size.width, size.height)
        guard largest > maxDimension else { return self }
        let scale = maxDimension / largest
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: newSize))
        }
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
        ))
    )
    return Color.ruulBackground.ignoresSafeArea()
        .fullScreenCover(isPresented: .constant(true)) {
            EditProfileSheet(coordinator: coord)
        }
}
#endif
