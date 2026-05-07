import SwiftUI

/// Modal sheet to issue an ad-hoc fine. Caller is responsible for dismissing
/// the sheet on success — coordinator returns the issued Fine and view sets
/// `isPresented = false`.
struct AddManualFineSheet: View {
    @Binding var isPresented: Bool
    @Bindable var coordinator: AddManualFineCoordinator
    let currentUserId: UUID

    var body: some View {
        ModalSheetTemplate(
            title: "Multar manualmente",
            dismissAction: { isPresented = false }
        ) {
            if coordinator.isLoadingMembers {
                RuulLoadingState()
            } else if coordinator.members.isEmpty {
                EmptyStateView(
                    systemImage: "person.2",
                    title: "Sin otros miembros",
                    message: "No hay otros miembros en este grupo."
                )
            } else {
                memberPickerSection
                amountSection
                reasonSection
                if let error = coordinator.error {
                    Text(error)
                        .ruulTextStyle(RuulTypography.caption)
                        .foregroundStyle(Color.ruulSemanticError)
                }
                submitButton
            }
        }
        .task {
            await coordinator.loadMembers(currentUserId: currentUserId)
        }
    }

    // MARK: - Member picker

    private var memberPickerSection: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.s2) {
            Text("¿A QUIÉN?")
                .ruulTextStyle(RuulTypography.sectionLabel)
                .foregroundStyle(Color.ruulTextTertiary)
            VStack(spacing: RuulSpacing.s2) {
                ForEach(coordinator.members) { mwp in
                    memberRow(mwp)
                }
            }
            .disabled(coordinator.isSubmitting)
        }
    }

    private func memberRow(_ mwp: MemberWithProfile) -> some View {
        let isSelected = coordinator.selectedMemberId == mwp.member.userId
        return Button {
            coordinator.selectedMemberId = mwp.member.userId
        } label: {
            HStack(spacing: RuulSpacing.s3) {
                RuulAvatar(name: mwp.displayName, imageURL: mwp.avatarURL, size: .medium)
                VStack(alignment: .leading, spacing: 2) {
                    Text(mwp.displayName)
                        .ruulTextStyle(RuulTypography.body)
                        .foregroundStyle(Color.ruulTextPrimary)
                        .lineLimit(1)
                    if mwp.member.isFounder {
                        Text("ADMIN")
                            .ruulTextStyle(RuulTypography.footnote)
                            .foregroundStyle(Color.ruulAccentPrimary)
                    }
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Color.ruulAccentPrimary)
                }
            }
            .padding(.horizontal, RuulSpacing.s4)
            .padding(.vertical, RuulSpacing.s3)
            .background(
                RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous)
                    .fill(isSelected ? Color.ruulAccentSubtle : Color.ruulBackgroundElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous)
                    .stroke(isSelected ? Color.ruulAccentPrimary : Color.ruulBorderSubtle,
                            lineWidth: isSelected ? 1.5 : 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Amount

    private var amountSection: some View {
        RuulTextField(
            "200",
            text: $coordinator.amountText,
            label: "MONTO",
            style: .numeric,
            isDisabled: coordinator.isSubmitting
        )
    }

    // MARK: - Reason

    private var reasonSection: some View {
        RuulTextField(
            "Llegó tarde sin avisar",
            text: $coordinator.reason,
            label: "MOTIVO",
            isDisabled: coordinator.isSubmitting
        )
    }

    // MARK: - CTA

    private var submitButton: some View {
        let label: String = {
            if coordinator.isSubmitting { return "Multando…" }
            if coordinator.canSubmit {
                let amount = coordinator.parsedAmount.map { "$\($0)" } ?? ""
                return "Multar a \(coordinator.selectedMemberName) — \(amount)"
            }
            return "Multar"
        }()
        return RuulButton(
            label,
            style: .primary,
            size: .large,
            isLoading: coordinator.isSubmitting,
            fillsWidth: true
        ) {
            Task {
                let fine = await coordinator.submit()
                if fine != nil {
                    isPresented = false
                }
            }
        }
        .disabled(!coordinator.canSubmit)
    }
}
