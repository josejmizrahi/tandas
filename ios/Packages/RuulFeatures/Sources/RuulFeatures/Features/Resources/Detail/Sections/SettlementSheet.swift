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
///   (mig 00145). Balance projection views (mig 00136) refresh
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
    /// FASE 3 Action Warmth (B.2 form-commit). Doctrine: el sheet NO
    /// dismissa antes de mostrar éxito. Cuando este string toma valor
    /// renderizamos un row de confirmación humana ("Le pagaste $X a
    /// Linda") y esperamos ~700ms para dejar respirar la consecuencia
    /// antes del dismiss.
    @State private var successPhrase: String?

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
                            .font(.caption)
                            // W2 incidental: Color.ruulDanger doesn't exist
                            // in the design system — Tier 6 SettlementSheet
                            // typo. ruulNegative is the canonical error tint.
                            .foregroundStyle(Color.red)
                    }
                }
                if let successPhrase {
                    Section {
                        HStack(spacing: RuulSpacing.sm) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.title3)
                                .foregroundStyle(Color.ruulSemanticSuccess)
                                .accessibilityHidden(true)
                            Text(successPhrase)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.primary)
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .animation(.snappy(duration: 0.22), value: successPhrase)
            .ruulSheetToolbar("Registrar pago")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirmButtonLabel) {
                        RuulHaptic.light.trigger()
                        Task { await submit() }
                    }
                    .disabled(isSubmitting || successPhrase != nil || !isValid)
                }
            }
        }
        .sensoryFeedback(.success, trigger: successPhrase)
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
            // FASE 3 D.2 + D.3: la consecuencia respira antes del dismiss
            // y se atribuye al humano. Frase tri-role (paga/cobra/tercero)
            // según quién es el viewer en la transacción.
            successPhrase = composeSuccessPhrase(from: from, to: to, amount: amount)
            try? await Task.sleep(for: .milliseconds(700))
            onDidSettle()
            dismiss()
        } catch {
            isSubmitting = false
            errorMessage = "No se pudo registrar: \(error.localizedDescription)"
            RuulHaptic.error.trigger()
        }
    }

    // MARK: - Warmth helpers (B.2 template)

    private var confirmButtonLabel: String {
        if successPhrase != nil { return "Listo" }
        if isSubmitting { return "Registrando…" }
        return "Registrar"
    }

    private func composeSuccessPhrase(from: UUID, to: UUID, amount: Int64) -> String {
        let formatted = formatAmount(cents: amount)
        let toName = memberName(to)
        let fromName = memberName(from)
        let viewerMemberId = currentUserMemberId()
        if from == viewerMemberId {
            return "Le pagaste \(formatted) a \(toName)"
        }
        if to == viewerMemberId {
            return "\(fromName) te pagó \(formatted)"
        }
        return "\(fromName) le pagó \(formatted) a \(toName)"
    }

    private func memberName(_ id: UUID) -> String {
        members.first(where: { $0.member.id == id })?.displayName ?? "alguien"
    }

    private func formatAmount(cents: Int64) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = currency
        f.locale = Locale(identifier: "es_MX")
        let decimal = Decimal(cents) / 100
        return f.string(from: decimal as NSDecimalNumber) ?? "$\(cents/100)"
    }
}
