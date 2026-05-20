import SwiftUI
import RuulUI
import RuulCore

/// Form sheet for recording a single ledger entry scoped to an event.
/// Backed by `ResourceLedgerCoordinator` — view binds form fields, dispatches
/// `submit()`, and dismisses on success.
///
/// Scope contract: the parent coordinator was built with `event.id`, so
/// every write here lands as `ledger_entries.resource_id = event.id`. Do
/// NOT shortcut the coordinator's `recordEntry` — that's where the scope
/// is anchored.
struct AddLedgerEntrySheet: View {
    @Binding var isPresented: Bool
    @Bindable var coordinator: ResourceLedgerCoordinator

    var body: some View {
        ModalSheetTemplate(
            title: "Registrar movimiento",
            dismissAction: { isPresented = false }
        ) {
            kindPickerSection
            amountSection
            if coordinator.formKind.requiresCounterparty {
                counterpartySection
            }
            noteSection
            if let error = coordinator.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Color.red)
            }
            submitButton
                .padding(.top, RuulSpacing.sm)
        }
    }

    // MARK: - Kind picker

    private var kindPickerSection: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text("TIPO DE MOVIMIENTO")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color(.tertiaryLabel))
            VStack(spacing: RuulSpacing.xs) {
                ForEach(ResourceLedgerCoordinator.EntryKind.allCases) { kind in
                    kindRow(kind)
                }
            }
            .disabled(coordinator.isSubmitting)
        }
    }

    private func kindRow(_ kind: ResourceLedgerCoordinator.EntryKind) -> some View {
        let isSelected = coordinator.formKind == kind
        return Button {
            coordinator.formKind = kind
            if !kind.requiresCounterparty {
                coordinator.formCounterpartyMemberId = nil
            }
        } label: {
            HStack(spacing: RuulSpacing.sm) {
                ZStack {
                    Circle()
                        .fill(Color.ruulAccent.opacity(isSelected ? 0.18 : 0.10))
                        .frame(width: 36, height: 36)
                    Image(systemName: kind.iconName)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.ruulAccent)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.displayLabel)
                        .font(.subheadline)
                        .foregroundStyle(Color.primary)
                    Text(kind.summaryHint)
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.footnote.weight(.bold))
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
            "300",
            text: $coordinator.formAmountText,
            label: "MONTO (MXN)",
            style: .numeric,
            isDisabled: coordinator.isSubmitting
        )
    }

    // MARK: - Counter-party (settlement only)

    /// Section header reads "¿A QUIÉN LE PAGASTE?" for settlement
    /// (member-to-member) and "¿A QUIÉN LE PAGA EL GRUPO?" for payout
    /// (pot-to-member).
    private var counterpartySectionLabel: String {
        coordinator.formKind == .payout
            ? "¿A QUIÉN LE PAGA EL GRUPO?"
            : "¿A QUIÉN LE PAGASTE?"
    }

    private var counterpartySection: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text(counterpartySectionLabel)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color(.tertiaryLabel))
            if coordinator.counterpartyOptions.isEmpty {
                Text("No hay otros miembros en este grupo.")
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
            } else {
                VStack(spacing: RuulSpacing.xs) {
                    ForEach(coordinator.counterpartyOptions) { mwp in
                        counterpartyRow(mwp)
                    }
                }
                .disabled(coordinator.isSubmitting)
            }
        }
    }

    private func counterpartyRow(_ mwp: MemberWithProfile) -> some View {
        let isSelected = coordinator.formCounterpartyMemberId == mwp.member.id
        return Button {
            coordinator.formCounterpartyMemberId = mwp.member.id
        } label: {
            HStack(spacing: RuulSpacing.sm) {
                RuulAvatar(name: mwp.displayName, imageURL: mwp.avatarURL, size: .medium)
                Text(mwp.displayName)
                    .font(.subheadline)
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
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

    // MARK: - Note

    private var noteSection: some View {
        RuulTextField(
            "Pizza, mesero, propinas…",
            text: $coordinator.formNote,
            label: "NOTA (OPCIONAL)",
            isDisabled: coordinator.isSubmitting
        )
    }

    // MARK: - CTA

    private var submitButton: some View {
        let label: String = {
            if coordinator.isSubmitting { return "Guardando…" }
            return "Registrar"
        }()
        return RuulButton(
            label,
            style: .primary,
            size: .large,
            isLoading: coordinator.isSubmitting,
            fillsWidth: true
        ) {
            Task {
                let entry = await coordinator.submit()
                if entry != nil {
                    isPresented = false
                }
            }
        }
        .disabled(!coordinator.canSubmit)
    }
}
