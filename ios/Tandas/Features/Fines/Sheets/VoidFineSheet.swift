import SwiftUI

/// Modal sheet for an admin to annul a fine. Caller is responsible for
/// dismissing the sheet on success — coordinator returns the voided Fine
/// and the View flips `isPresented = false` + fires haptic.
struct VoidFineSheet: View {
    @Binding var isPresented: Bool
    @Bindable var coordinator: VoidFineCoordinator

    var body: some View {
        ModalSheetTemplate(
            title: "Anular multa",
            dismissAction: { isPresented = false }
        ) {
            multaContextSection
            reasonSection
            if let error = coordinator.error {
                Text(error)
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulSemanticError)
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
        VStack(alignment: .leading, spacing: RuulSpacing.s2) {
            Text("MULTA")
                .ruulTextStyle(RuulTypography.sectionLabel)
                .foregroundStyle(Color.ruulTextTertiary)
            VStack(alignment: .leading, spacing: RuulSpacing.s1) {
                Text("\(coordinator.targetMemberName) — \(coordinator.fine.amountFormatted)")
                    .ruulTextStyle(RuulTypography.headline)
                    .foregroundStyle(Color.ruulTextPrimary)
                Text("\u{201C}\(coordinator.fine.reason)\u{201D}")
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextSecondary)
            }
            .padding(RuulSpacing.s4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color.ruulBackgroundElevated,
                in: RoundedRectangle(cornerRadius: RuulRadius.lg, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.lg, style: .continuous)
                    .stroke(Color.ruulBorderSubtle, lineWidth: 0.5)
            )
        }
    }

    // MARK: - Reason input

    @ViewBuilder
    private var reasonSection: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.s2) {
            Text("MOTIVO DEL ANULADO")
                .ruulTextStyle(RuulTypography.sectionLabel)
                .foregroundStyle(Color.ruulTextTertiary)
            RuulTextField(
                "Multa duplicada",
                text: $coordinator.reason,
                isDisabled: coordinator.isSubmitting
            )
            Text("Visible para \(coordinator.targetMemberName).")
                .ruulTextStyle(RuulTypography.caption)
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
