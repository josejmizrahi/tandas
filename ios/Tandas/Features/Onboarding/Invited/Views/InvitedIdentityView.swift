import SwiftUI
import PhotosUI

struct InvitedIdentityView: View {
    @Environment(InvitedOnboardingCoordinator.self) private var coord
    @State private var avatarItem: PhotosPickerItem?
    @State private var avatarData: Data?
    @FocusState private var nameFocused: Bool

    var body: some View {
        @Bindable var bindable = coord
        OnboardingScreenTemplate(
            mesh: .aqua,
            progress: progressValue,
            stepCount: InvitedStep.allCases.count,
            title: "¿Cómo te llamas?",
            subtitle: "El grupo necesita saber quién entra.",
            primaryCTA: ("Continuar", coord.isLoading, { Task { await coord.advanceFromIdentity() } }),
            canContinue: !coord.displayName.trimmingCharacters(in: .whitespaces).isEmpty
        ) {
            VStack(spacing: RuulSpacing.s5) {
                avatarSection
                RuulTextField("Tu nombre", text: $bindable.displayName, label: "Nombre")
                    .focused($nameFocused)
            }
        }
        .onAppear { nameFocused = true }
        .onChange(of: avatarItem) { _, newValue in
            Task { await loadAvatar(from: newValue) }
        }
    }

    private var progressValue: Double {
        Double(InvitedStep.identity.index) / Double(InvitedStep.allCases.count - 1)
    }

    private var avatarSection: some View {
        PhotosPicker(selection: $avatarItem, matching: .images) {
            ZStack {
                if let data = avatarData, let img = UIImage(data: data) {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: RuulSize.avatarXLarge, height: RuulSize.avatarXLarge)
                        .clipShape(Circle())
                } else {
                    RuulAvatar(
                        name: coord.displayName.isEmpty ? "?" : coord.displayName,
                        size: .hero,
                        border: .glass
                    )
                }
                Image(systemName: "camera.fill")
                    .font(.system(size: RuulSize.iconSmall, weight: .semibold))
                    .foregroundStyle(Color.ruulTextInverse)
                    .padding(RuulSpacing.s2)
                    .background(Color.ruulTextPrimary, in: Circle())
                    .offset(x: RuulSpacing.s7, y: RuulSpacing.s7)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Cambiar foto")
    }

    private func loadAvatar(from item: PhotosPickerItem?) async {
        guard let item else { return }
        if let data = try? await item.loadTransferable(type: Data.self) {
            avatarData = data
        }
    }
}
