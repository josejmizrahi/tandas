import SwiftUI
import RuulUI
import RuulCore

/// One-tap settlement sheet (Tier 6 final). Lets the current user
/// record a payment they made to another member of the group.
///
/// Surface: presented from `MoneySectionView`'s "Registrar pago"
/// button when the user has at least one negative-net balance in the
/// resource's scope. The sheet defaults the recipient picker to the
/// member with the largest positive net (the most-owed person) but
/// the user can switch freely.
///
/// Submit path:
///   LedgerRepository.recordSettlement → record_settlement RPC
///   (mig 00143). Balance projection views (mig 00136) refresh
///   automatically on the next read.
public struct SettlementSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    public let groupId: UUID
    public let resourceId: UUID?
    public let currency: String
    public let members: [MemberWithProfile]
    /// Pre-selected "to" member (the one with the largest positive
    /// balance, computed by the caller). nil falls back to first
    /// member in the list.
    public let suggestedToMemberId: UUID?
    /// Called after a successful settlement so the caller can refresh
    /// its balance view.
    public let onDidSettle: () -> Void

    @State private var fromMemberId: UUID?
    @State private var toMemberId: UUID?
    @State private var amountText: String = ""
    @State private var note: String = ""
    @State private var isSubmitting: Bool = false
    @State private var errorMessage: String?

    public init(
        groupId: UUID,
        resourceId: UUID?,
        currency: String,
        members: [MemberWithProfile],
        suggestedToMemberId: UUID?,
        onDidSettle: @escaping () -> Void
    ) {
        self.groupId = groupId
        self.resourceId = resourceId
        self.currency = currency
        self.members = members
        self.suggestedToMemberId = suggestedToMemberId
        self.onDidSettle = onDidSettle
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("De") {
                    memberPicker(selection: $fromMemberId, exclude: toMemberId)
                }
                Section("A") {
                    memberPicker(selection: $toMemberId, exclude: fromMemberId)
                }
                Section("Monto (\(currency))") {
                    TextField("0", text: $amountText)
                        .keyboardType(.decimalPad)
                }
                Section("Nota (opcional)") {
                    TextField("ej: Le devolví los $300 de la cena", text: $note, axis: .vertical)
                        .lineLimit(2...4)
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .ruulTextStyle(RuulTypography.caption)
                            // W2 incidental: Color.ruulDanger doesn't exist
                            // in the design system — Tier 6 SettlementSheet
                            // typo. ruulNegative is the canonical error tint.
                            .foregroundStyle(Color.ruulNegative)
                    }
                }
            }
            .navigationTitle("Registrar pago")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSubmitting ? "Registrando…" : "Registrar") {
                        Task { await submit() }
                    }
                    .disabled(isSubmitting || !isValid)
                }
            }
        }
        .onAppear {
            // Default from = current user's member row; to = suggestion or
            // the first OTHER member.
            if fromMemberId == nil {
                fromMemberId = currentUserMemberId() ?? members.first?.member.id
            }
            if toMemberId == nil {
                if let suggested = suggestedToMemberId, suggested != fromMemberId {
                    toMemberId = suggested
                } else {
                    toMemberId = members.first(where: { $0.member.id != fromMemberId })?.member.id
                }
            }
        }
    }

    @ViewBuilder
    private func memberPicker(selection: Binding<UUID?>, exclude: UUID?) -> some View {
        Picker("", selection: selection) {
            ForEach(members.filter { $0.member.id != exclude }) { m in
                Text(m.displayName).tag(Optional(m.member.id))
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
    }

    private var isValid: Bool {
        guard let from = fromMemberId, let to = toMemberId, from != to else { return false }
        guard let amount = amountInCents, amount > 0 else { return false }
        return true
    }

    /// Parses the amount text as pesos with up to 2 decimals → cents.
    /// Returns nil when the input is empty or malformed.
    private var amountInCents: Int64? {
        let trimmed = amountText.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard !trimmed.isEmpty,
              let pesos = Double(trimmed),
              pesos.isFinite else { return nil }
        let rounded = Int64((pesos * 100).rounded())
        return rounded > 0 ? rounded : nil
    }

    private func currentUserMemberId() -> UUID? {
        guard let uid = app.session?.user.id else { return nil }
        return members.first(where: { $0.member.userId == uid })?.member.id
    }

    @MainActor
    private func submit() async {
        guard let from = fromMemberId,
              let to = toMemberId,
              let amount = amountInCents else { return }
        isSubmitting = true
        errorMessage = nil
        do {
            _ = try await app.ledgerRepo.recordSettlement(
                groupId:      groupId,
                fromMemberId: from,
                toMemberId:   to,
                amountCents:  amount,
                currency:     currency,
                resourceId:   resourceId,
                note:         note.isEmpty ? nil : note
            )
            isSubmitting = false
            onDidSettle()
            dismiss()
        } catch {
            isSubmitting = false
            errorMessage = "No se pudo registrar: \(error.localizedDescription)"
        }
    }
}
