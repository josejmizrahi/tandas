import SwiftUI
import PhotosUI

struct FounderIdentityView: View {
    @Environment(FounderOnboardingCoordinator.self) private var coord
    @State private var selectedItem: PhotosPickerItem?
    @State private var avatarImageData: Data?
    @FocusState private var nameFocused: Bool

    var body: some View {
        @Bindable var bindable = coord
        OnboardingScreenTemplate(
            mesh: .cool,
            progress: progressValue,
            stepCount: FounderStep.allCases.count,
            title: "¿Cómo te llamas?",
            subtitle: "Así te van a ver tus grupos.",
            primaryCTA: ("Continuar", coord.isLoading, primaryAction),
            onSkip: { Task { await coord.skipIdentity() } },
            canContinue: !coord.displayName.trimmingCharacters(in: .whitespaces).isEmpty
        ) {
            VStack(spacing: RuulSpacing.s5) {
                avatarSection
                RuulTextField(
                    "Tu nombre",
                    text: $bindable.displayName,
                    label: "Nombre"
                )
                .focused($nameFocused)
            }
        }
        .onAppear { nameFocused = true }
        .onChange(of: selectedItem) { _, newValue in
            Task { await loadAvatar(from: newValue) }
        }
    }

    private var progressValue: Double {
        Double(FounderStep.identity.index) / Double(FounderStep.allCases.count - 1)
    }

    private func primaryAction() {
        Task { await coord.advanceFromIdentity() }
    }

    @ViewBuilder
    private var avatarSection: some View {
        PhotosPicker(selection: $selectedItem, matching: .images) {
            ZStack {
                if let data = avatarImageData, let img = UIImage(data: data) {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 96, height: 96)
                        .clipShape(Circle())
                } else {
                    RuulAvatar(
                        name: coord.displayName.isEmpty ? "?" : coord.displayName,
                        size: .hero,
                        border: .glass
                    )
                }
                Image(systemName: "camera.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .padding(8)
                    .background(Color.ruulAccentPrimary, in: Circle())
                    .offset(x: 32, y: 32)
            }
        }
        .buttonStyle(.plain)
    }

    private func loadAvatar(from item: PhotosPickerItem?) async {
        guard let item else { return }
        if let data = try? await item.loadTransferable(type: Data.self) {
            avatarImageData = data
            // For V1, we keep the avatar local until the founder completes
            // OTP. Upload to storage is a follow-up (not in V1 plan).
        }
    }
}
