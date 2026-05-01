import SwiftUI

struct GroupVocabularyView: View {
    @Environment(FounderOnboardingCoordinator.self) private var coord

    private static let vocabularyOptions: [RuulFlowChips<String>.Option] = [
        .init(value: "cena",      label: "Cena"),
        .init(value: "junta",     label: "Junta"),
        .init(value: "ronda",     label: "Ronda"),
        .init(value: "sesion",    label: "Sesión"),
        .init(value: "reunion",   label: "Reunión"),
        .init(value: "encuentro", label: "Encuentro")
    ]

    var body: some View {
        @Bindable var bindable = coord
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
            VStack(alignment: .leading, spacing: RuulSpacing.s7) {
                vocabularySection(bindable: bindable)
                frequencySection(bindable: bindable)
                if coord.draft.frequencyType != nil && coord.draft.frequencyType != .unscheduled {
                    dayTimeSection(bindable: bindable)
                }
            }
        }
    }

    private var progressValue: Double {
        Double(FounderStep.vocabulary.index) / Double(FounderStep.allCases.count - 1)
    }

    private func vocabularySection(bindable: Bindable<FounderOnboardingCoordinator>) -> some View {
        VStack(alignment: .leading, spacing: RuulSpacing.s2) {
            Text("¿Cómo le dicen?")
                .ruulTextStyle(RuulTypography.headline)
                .foregroundStyle(Color.ruulTextPrimary)
            RuulFlowChips(
                selection: Binding(
                    get: { bindable.draft.eventVocabulary.wrappedValue },
                    set: { bindable.draft.eventVocabulary.wrappedValue = $0 ?? "evento" }
                ),
                options: Self.vocabularyOptions,
                allowOther: true,
                otherSentinel: "otro",
                customValue: Binding(
                    get: { bindable.draft.customVocabulary.wrappedValue ?? "" },
                    set: { bindable.draft.customVocabulary.wrappedValue = $0 }
                )
            )
        }
    }

    private func frequencySection(bindable: Bindable<FounderOnboardingCoordinator>) -> some View {
        VStack(alignment: .leading, spacing: RuulSpacing.s2) {
            Text("¿Cada cuánto?")
                .ruulTextStyle(RuulTypography.headline)
                .foregroundStyle(Color.ruulTextPrimary)
            RuulPicker(
                selection: Binding(
                    get: { coord.draft.frequencyType ?? .unscheduled },
                    set: { coord.draft.frequencyType = $0 }
                ),
                options: FrequencyType.allCases.map {
                    .init(value: $0, label: $0.displayName)
                }
            )
        }
    }

    private func dayTimeSection(bindable: Bindable<FounderOnboardingCoordinator>) -> some View {
        VStack(alignment: .leading, spacing: RuulSpacing.s3) {
            Text("Día y hora")
                .ruulTextStyle(RuulTypography.headline)
                .foregroundStyle(Color.ruulTextPrimary)
            RuulPicker(
                selection: Binding(
                    get: { coord.draft.frequencyConfig.dayOfWeek ?? 3 },
                    set: { day in
                        coord.draft.frequencyConfig.dayOfWeek = day
                    }
                ),
                options: dayOptions
            )
            // Time picker uses RuulDatePicker .hourAndMinute. We store back to
            // frequencyConfig hour/minute on each change.
            RuulDatePicker(
                "Hora",
                date: Binding(
                    get: { dateFromConfig() },
                    set: { newDate in
                        let comps = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                        coord.draft.frequencyConfig.hour = comps.hour
                        coord.draft.frequencyConfig.minute = comps.minute
                    }
                ),
                components: [.hourAndMinute]
            )
        }
    }

    private var dayOptions: [RuulPicker<Int>.Option] {
        let days = [
            (0, "Domingo"), (1, "Lunes"), (2, "Martes"), (3, "Miércoles"),
            (4, "Jueves"), (5, "Viernes"), (6, "Sábado")
        ]
        return days.map { .init(value: $0.0, label: $0.1) }
    }

    private func dateFromConfig() -> Date {
        var comps = DateComponents()
        comps.hour = coord.draft.frequencyConfig.hour ?? 20
        comps.minute = coord.draft.frequencyConfig.minute ?? 30
        return Calendar.current.date(from: comps) ?? .now
    }
}
