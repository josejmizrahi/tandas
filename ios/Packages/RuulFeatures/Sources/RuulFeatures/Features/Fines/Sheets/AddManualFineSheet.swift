import SwiftUI
import RuulUI
import RuulCore

/// Modal sheet to issue an ad-hoc fine. Caller is responsible for dismissing
/// the sheet on success — coordinator returns the issued Fine and view sets
/// `isPresented = false`.
public struct AddManualFineSheet: View {
    @Binding var isPresented: Bool
    @Bindable var coordinator: AddManualFineCoordinator
    public let currentUserId: UUID

    public init(isPresented: Binding<Bool>, coordinator: AddManualFineCoordinator, currentUserId: UUID) {
        self._isPresented = isPresented
        self.coordinator = coordinator
        self.currentUserId = currentUserId
    }

    public var body: some View {
        ModalSheetTemplate(
            title: "Multar manualmente",
            dismissAction: { isPresented = false }
        ) {
            if coordinator.isLoadingMembers {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if coordinator.members.isEmpty {
                ContentUnavailableView {
                    Label("Solo estás tú", systemImage: "person.2")
                } description: {
                    Text("Para multar manualmente necesitas a alguien más. Comparte el código del grupo.")
                }
            } else {
                memberPickerSection
                amountSection
                reasonSection
                if let error = coordinator.error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(Color.red)
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
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            RuulListSectionHeader("¿A quién?")
            RuulSeparatedRows(items: coordinator.members) { mwp in
                memberRow(mwp)
            }
            .disabled(coordinator.isSubmitting)
        }
    }

    private func memberRow(_ mwp: MemberWithProfile) -> some View {
        let isSelected = coordinator.selectedMemberId == mwp.member.userId
        return Button {
            coordinator.selectedMemberId = mwp.member.userId
        } label: {
            HStack(spacing: RuulSpacing.sm) {
                RuulAvatar(name: mwp.displayName, imageURL: mwp.avatarURL, size: .medium)
                VStack(alignment: .leading, spacing: 2) {
                    Text(mwp.displayName)
                        .font(.subheadline)
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                    if mwp.member.isFounder {
                        Text("Fundador")
                            .font(.footnote)
                            .foregroundStyle(Color.ruulAccent)
                    }
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.subheadline.weight(.bold))
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
                    .stroke(isSelected ? Color.ruulAccent : Color(.separator),
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
            label: "Monto",
            style: .numeric,
            isDisabled: coordinator.isSubmitting
        )
    }

    // MARK: - Reason

    private var reasonSection: some View {
        RuulTextField(
            "Llegó tarde sin avisar",
            text: $coordinator.reason,
            label: "Motivo",
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
