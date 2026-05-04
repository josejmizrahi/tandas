import SwiftUI

/// Founder onboarding step 2: pick the platform template that the group
/// will run. V1 only enables "Cena recurrente"; the Recurso compartido and
/// Tanda de ahorro cards are visible-as-coming-soon so the user perceives
/// ruul as a platform from day one.
///
/// Auto-advances 600ms after selection so users don't need to tap a CTA.
struct TemplateSelectorView: View {
    @Environment(FounderOnboardingCoordinator.self) private var coord
    @State private var selected: DinnerRecurringTemplate.TemplateID? = .dinnerRecurring
    @State private var advanceTimer: Task<Void, Never>?

    var body: some View {
        OnboardingScreenTemplate(
            mesh: nil,
            progress: progress,
            stepCount: FounderStep.allCases.count,
            title: "¿Qué tipo de grupo es?",
            subtitle: "Elige el template — define cómo se comporta. Después puedes personalizar todo.",
            primaryCTA: nil
        ) {
            VStack(spacing: RuulSpacing.s3) {
                TemplatePickerCard(
                    icon: "fork.knife.circle.fill",
                    title: "Cena recurrente",
                    subtitle: "Cenas, juntas, reuniones que se repiten con el mismo grupo.",
                    bullets: [
                        "Rotación de host",
                        "RSVP con check-in",
                        "Multas por reglas que ustedes definen"
                    ],
                    isSelected: selected == .dinnerRecurring,
                    onSelect: { select(.dinnerRecurring) }
                )
                TemplatePickerCard(
                    icon: "ticket.fill",
                    title: "Recurso compartido",
                    subtitle: "Palco, casa de fin de semana, suscripción que rotan.",
                    bullets: ["Asignación rotativa", "Cascada al saltar"],
                    isComingSoon: true,
                    onSelect: {}
                )
                TemplatePickerCard(
                    icon: "banknote.fill",
                    title: "Tanda de ahorro",
                    subtitle: "Sistema de aportes y cobros programados.",
                    bullets: ["Aportes mensuales", "Cobro por turno"],
                    isComingSoon: true,
                    onSelect: {}
                )
            }
        }
        .onDisappear { advanceTimer?.cancel() }
    }

    private func select(_ template: DinnerRecurringTemplate.TemplateID) {
        selected = template
        coord.draft.template = template.rawValue
        // Auto-advance — feels like Apple's onboarding picks. Cancellable in
        // case the user changes their mind before the 600ms elapses.
        advanceTimer?.cancel()
        advanceTimer = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            await coord.advanceFromTemplateSelect()
        }
    }

    private var progress: Double {
        let index = Double(FounderStep.templateSelect.index)
        let total = Double(max(1, FounderStep.allCases.count - 1))
        return index / total
    }
}
