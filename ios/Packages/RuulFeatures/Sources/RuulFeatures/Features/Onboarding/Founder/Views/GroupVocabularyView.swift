import SwiftUI
import RuulUI
import RuulCore

/// Onboarding step: founder picks the vocabulary for "events" in this group.
///
/// Post BigBang the frequency / day / time pickers are gone — recurrence is
/// not a group-level concept anymore. When the founder creates a recurring
/// event later (Phase 2 ResourceWizard), the schedule lives on the
/// ResourceSeries, not on the group.
public struct GroupVocabularyView: View {
    @Environment(FounderOnboardingCoordinator.self) private var coord

    private static let vocabularyOptions: [RuulFlowChips<String>.Option] = [
        .init(value: "cena",      label: "Cena"),
        .init(value: "junta",     label: "Junta"),
        .init(value: "ronda",     label: "Ronda"),
        .init(value: "sesion",    label: "Sesión"),
        .init(value: "reunion",   label: "Reunión"),
        .init(value: "encuentro", label: "Encuentro")
    ]

    public var body: some View {
        OnboardingScreenTemplate(
            mesh: .cool,
            progress: progressValue,
            stepCount: FounderStep.allCases.count,
            title: "Sobre las reuniones",
            subtitle: nil,
            primaryCTA: ("Continuar", coord.isLoading, { Task { await coord.advanceFromVocabulary() } }),
            onSkip: { Task { await coord.skipVocabulary() } },
            canContinue: true
        ) {
            VStack(alignment: .leading, spacing: RuulSpacing.xxl) {
                vocabularySection
            }
        }
    }

    private var progressValue: Double {
        Double(FounderStep.vocabulary.index) / Double(FounderStep.allCases.count - 1)
    }

    private var vocabularySection: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text("¿Cómo le dicen?")
                .ruulTextStyle(RuulTypography.headline)
                .foregroundStyle(Color.ruulTextPrimary)
            RuulFlowChips(
                selection: Binding(
                    get: { coord.draft.eventVocabulary },
                    set: { coord.draft.eventVocabulary = $0 ?? "evento" }
                ),
                options: Self.vocabularyOptions,
                allowOther: true,
                otherSentinel: "otro",
                customValue: Binding(
                    get: { coord.draft.customVocabulary ?? "" },
                    set: { coord.draft.customVocabulary = $0 }
                )
            )
        }
    }
}
