import SwiftUI
import RuulUI
import RuulCore

/// Modal sheet for an admin to annul a fine. Caller is responsible for
/// dismissing the sheet on success — coordinator returns the voided Fine
/// and the View flips `isPresented = false` + fires haptic.
public struct VoidFineSheet: View {
    @Binding var isPresented: Bool
    @Bindable var coordinator: VoidFineCoordinator

    public var body: some View {
        ModalSheetTemplate(
            title: "Anular multa",
            dismissAction: { isPresented = false }
        ) {
            multaContextSection
            reasonSection
            if let error = coordinator.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Color.ruulNegative)
            }
            submitButton
        }
        .task {
            await coordinator.resolveTargetName()
        }
    }

    // MARK: - Read-only context card

    @ViewBuilder
    private var multaContextSection: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            RuulListSectionHeader("MULTA")
            VStack(alignment: .leading, spacing: RuulSpacing.xxs) {
                HStack(alignment: .firstTextBaseline, spacing: RuulSpacing.xs) {
                    Text(coordinator.targetMemberName)
                        .font(.headline)
                        .foregroundStyle(Color.ruulTextPrimary)
                    Spacer()
                    RuulMoneyView(
                        amount: coordinator.fine.amount,
                        currency: "MXN",
                        size: .medium,
                        color: .negative
                    )
                }
                Text("\u{201C}\(coordinator.fine.reason)\u{201D}")
                    .font(.subheadline)
                    .foregroundStyle(Color.ruulTextSecondary)
            }
            .padding(RuulSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color.ruulSurface,
                in: RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous)
                    .stroke(Color.ruulSeparator, lineWidth: 0.5)
            )
        }
    }

    // MARK: - Reason input

    @ViewBuilder
    private var reasonSection: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            RuulListSectionHeader("MOTIVO DEL ANULADO")
            RuulTextField(
                "Multa duplicada",
                text: $coordinator.reason,
                isDisabled: coordinator.isSubmitting
            )
            Text("Visible para \(coordinator.targetMemberName).")
                .font(.caption)
                .foregroundStyle(Color.ruulTextTertiary)
        }
    }

    // MARK: - Submit

    @ViewBuilder
    private var submitButton: some View {
        RuulButton(
            coordinator.isSubmitting ? "Anulando…" : "Anular multa",
            style: .destructive,
            size: .large,
            isLoading: coordinator.isSubmitting,
            fillsWidth: true
        ) {
            Task {
                if await coordinator.submit() != nil {
                    isPresented = false
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                }
            }
        }
        .disabled(!coordinator.canSubmit)
    }
}
