import SwiftUI
import RuulUI
import RuulCore

/// Form for creating a single event-scoped rule. Bound to
/// `EventRulesCoordinator`'s form fields. Submit dismisses on success.
///
/// MVP shape: name + trigger picker (3 canonical triggers) + flat fine
/// amount. The coordinator stitches the trigger pick into a server-shaped
/// `RuleTrigger` + `[RuleCondition]` + `[RuleConsequence]`.
struct AddEventRuleSheet: View {
    @Binding var isPresented: Bool
    @Bindable var coordinator: EventRulesCoordinator

    var body: some View {
        ModalSheetTemplate(
            title: "Nueva regla",
            dismissAction: { isPresented = false }
        ) {
            nameSection
            triggerSection
            fineSection
            if let error = coordinator.error {
                Text(error)
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulNegative)
            }
            submitButton
                .padding(.top, RuulSpacing.sm)
        }
    }

    // MARK: - Name

    private var nameSection: some View {
        RuulTextField(
            "Late fee de esta cena",
            text: $coordinator.formName,
            label: "NOMBRE",
            isDisabled: coordinator.isSubmitting
        )
    }

    // MARK: - Trigger

    private var triggerSection: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text("CUÁNDO APLICA")
                .ruulTextStyle(RuulTypography.sectionLabel)
                .foregroundStyle(Color.ruulTextTertiary)
            VStack(spacing: RuulSpacing.xs) {
                ForEach(EventRulesCoordinator.TriggerKind.allCases) { kind in
                    triggerRow(kind)
                }
            }
            .disabled(coordinator.isSubmitting)
        }
    }

    private func triggerRow(_ kind: EventRulesCoordinator.TriggerKind) -> some View {
        let isSelected = coordinator.formTrigger == kind
        return Button {
            coordinator.formTrigger = kind
        } label: {
            HStack(spacing: RuulSpacing.sm) {
                ZStack {
                    Circle()
                        .fill(Color.ruulAccent.opacity(isSelected ? 0.18 : 0.10))
                        .frame(width: 36, height: 36)
                    Image(systemName: kind.iconName)
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(Color.ruulAccent)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.displayLabel)
                        .ruulTextStyle(RuulTypography.body)
                        .foregroundStyle(Color.ruulTextPrimary)
                    Text(kind.summary)
                        .ruulTextStyle(RuulTypography.caption)
                        .foregroundStyle(Color.ruulTextSecondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color.ruulAccent)
                }
            }
            .padding(.horizontal, RuulSpacing.md)
            .padding(.vertical, RuulSpacing.sm)
            .background(
                RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                    .fill(isSelected ? Color.ruulAccentMuted : Color.ruulSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                    .stroke(isSelected ? Color.ruulAccent : Color.ruulSeparator,
                            lineWidth: isSelected ? 1.5 : 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Fine amount

    private var fineSection: some View {
        RuulTextField(
            "200",
            text: $coordinator.formFineAmountText,
            label: "MULTA (MXN)",
            style: .numeric,
            isDisabled: coordinator.isSubmitting
        )
    }

    // MARK: - CTA

    private var submitButton: some View {
        let label: String = {
            if coordinator.isSubmitting { return "Guardando…" }
            return "Crear regla"
        }()
        return RuulButton(
            label,
            style: .primary,
            size: .large,
            isLoading: coordinator.isSubmitting,
            fillsWidth: true
        ) {
            Task {
                let rule = await coordinator.submit()
                if rule != nil {
                    isPresented = false
                }
            }
        }
        .disabled(!coordinator.canSubmit)
    }
}
