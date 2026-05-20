import SwiftUI
import RuulUI
import RuulCore

public struct GroupIdentityView: View {
    @Environment(FounderOnboardingCoordinator.self) private var coord
    @FocusState private var nameFocused: Bool

    private static let suggestions = ["Los Cuates", "El Grupo", "Domingo Familiar", "La Banda"]

    public var body: some View {
        @Bindable var bindable = coord
        OnboardingScreenTemplate(
            mesh: .cool,
            progress: progressValue,
            title: "Crea tu grupo",
            subtitle: "Tu grupo se vuelve vivo en cuanto le pongas nombre.",
            primaryCTA: ("Crear grupo", coord.isLoading, { Task { await coord.advanceFromGroupIdentity() } }),
            canContinue: coord.draft.isReadyToCreate
        ) {
            VStack(alignment: .leading, spacing: RuulSpacing.lg) {
                RuulTextField(
                    "Nombre del grupo",
                    text: $bindable.draft.name,
                    label: "Nombre"
                )
                .focused($nameFocused)

                VStack(alignment: .leading, spacing: RuulSpacing.xs) {
                    Text("Sugerencias")
                        .font(.footnote)
                        .foregroundStyle(Color.secondary)
                    suggestionChips
                }

                // W3-B1: cover picker removed from onboarding. Audit B
                // flagged it as a vanity decision added before the user
                // has any sense of the product. draft.coverImageName
                // stays nil; RuulCoverCatalog.cover(named:) falls back
                // to .sunset. Founders can pick a cover later in group
                // settings (once that surface lands).

                if let error = coord.error, case .createGroupFailed = error {
                    Text(error.localizedDescription)
                        .font(.caption)
                        .foregroundStyle(Color.red)
                }
            }
        }
        .onAppear { nameFocused = true }
    }

    private var progressValue: Double {
        FounderStep.group.progressFraction
    }

    private var suggestionChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: RuulSpacing.xs) {
                ForEach(Self.suggestions, id: \.self) { name in
                    RuulChip(name, style: .suggestion) {
                        coord.draft.name = name
                    }
                }
            }
        }
    }
}
