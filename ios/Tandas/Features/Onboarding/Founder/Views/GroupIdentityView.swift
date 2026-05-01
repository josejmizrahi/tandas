import SwiftUI

struct GroupIdentityView: View {
    @Environment(FounderOnboardingCoordinator.self) private var coord
    @FocusState private var nameFocused: Bool

    private static let suggestions = ["Los Cuates", "El Grupo", "Domingo Familiar", "La Banda"]

    var body: some View {
        @Bindable var bindable = coord
        OnboardingScreenTemplate(
            mesh: .cool,
            progress: progressValue,
            stepCount: FounderStep.allCases.count,
            title: "Crea tu grupo",
            subtitle: "Tu grupo se vuelve vivo en cuanto le pongas nombre.",
            primaryCTA: ("Crear grupo", coord.isLoading, { Task { await coord.advanceFromGroupIdentity() } }),
            canContinue: coord.draft.isReadyToCreate
        ) {
            VStack(alignment: .leading, spacing: RuulSpacing.s5) {
                RuulTextField(
                    "Nombre del grupo",
                    text: $bindable.draft.name,
                    label: "Nombre"
                )
                .focused($nameFocused)

                VStack(alignment: .leading, spacing: RuulSpacing.s2) {
                    Text("Sugerencias")
                        .ruulTextStyle(RuulTypography.footnote)
                        .foregroundStyle(Color.ruulTextSecondary)
                    suggestionChips
                }

                VStack(alignment: .leading, spacing: RuulSpacing.s2) {
                    Text("Cover")
                        .ruulTextStyle(RuulTypography.footnote)
                        .foregroundStyle(Color.ruulTextSecondary)
                    RuulCoverPicker(selectedCoverId: $bindable.draft.coverImageName)
                        .padding(.horizontal, -RuulSpacing.s5) // bleed past container padding
                }

                if let error = coord.error, case .createGroupFailed = error {
                    Text(error.localizedDescription)
                        .ruulTextStyle(RuulTypography.caption)
                        .foregroundStyle(Color.ruulSemanticError)
                }
            }
        }
        .onAppear { nameFocused = true }
    }

    private var progressValue: Double {
        Double(FounderStep.group.index) / Double(FounderStep.allCases.count - 1)
    }

    private var suggestionChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: RuulSpacing.s2) {
                ForEach(Self.suggestions, id: \.self) { name in
                    RuulChip(name, style: .suggestion) {
                        coord.draft.name = name
                    }
                }
            }
        }
    }
}
