import SwiftUI
import RuulCore
import RuulUI

/// SharedMoney Phase 3 (brick 4): group-scoped expense sheet, invoked
/// from `SharedMoneyCard`'s "Registrar gasto" CTA in `GroupSpaceView`.
///
/// Mig 00370 (Splitwise-style modes): four split modes — equal, exact,
/// percent, shares. Each mode drives a different per-member input but
/// all converge to the same canonical breakdown `[SplitBreakdown]`
/// stamped into `metadata.split_breakdown`. The `metadata.split_mode`
/// is kept so the editor can pre-fill the same mode on revisit.
///
/// V1 posture (per mig 00370 comment): the breakdown is metadata-only,
/// not auto-IOU-emitted. UX surfaces who-owes-what; users still settle
/// manually. V2 candidate: emit one IOU atom per non-payer participant
/// so `member_balances_per_group` reflects splits natively.
public struct RecordSharedExpenseSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    public let groupId: UUID
    public let currency: String
    public let members: [MemberWithProfile]
    /// When set, the entry is attributed to a specific resource
    /// (event/asset/space) via mig 00360 `p_source_resource_id`.
    public let sourceResource: (id: UUID, name: String)?
    /// Money UX Consolidation PR-B (2026-05-24): when set, the expense
    /// lands directly on that fund via `fund_record_expense` instead
    /// of the shared pool via `record_shared_expense`. Used for
    /// protected/legacy funds (the surface that was
    /// `RecordExpenseFromFundSheet` before the consolidation).
    public let targetFundId: UUID?
    public let targetFundName: String?
    public let onDidRecord: () -> Void

    @State private var paidByMemberId: UUID?
    @State private var toMemberId: UUID?
    @State private var toMemberManuallySet: Bool = false
    @State private var amountText: String = ""
    @State private var note: String = ""

    /// Selected split mode. Defaults to `.equal` — covers the 80% case.
    @State private var splitMode: SplitMode = .equal
    /// Set of participants for `.equal` mode (Toggle rows).
    @State private var participantIds: Set<UUID> = []
    /// Per-member raw-string inputs for `.exact` and `.percent` modes.
    /// String to preserve user typing (commas, partial numbers).
    @State private var perMemberInput: [UUID: String] = [:]
    /// Per-member integer shares for `.shares` mode (Stepper). Default 0
    /// for members not assigned; participants are members with value > 0.
    @State private var perMemberShares: [UUID: Int] = [:]

    @State private var isSubmitting: Bool = false
    @State private var errorMessage: String?
    @State private var clientId: UUID = UUID()
    /// FASE 3 Action Warmth (B.2 form-commit): el sheet NO dismissa
    /// inmediato. Frase humana ("Linda pagó $300 de la cena") respira
    /// 700ms antes del dismiss.
    @State private var successPhrase: String?

    public init(
        groupId: UUID,
        currency: String,
        members: [MemberWithProfile],
        sourceResource: (id: UUID, name: String)? = nil,
        targetFundId: UUID? = nil,
        targetFundName: String? = nil,
        onDidRecord: @escaping () -> Void
    ) {
        self.groupId = groupId
        self.currency = currency
        self.members = members
        self.sourceResource = sourceResource
        self.targetFundId = targetFundId
        self.targetFundName = targetFundName
        self.onDidRecord = onDidRecord
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let sourceResource {
                        Label("Gasto de \(sourceResource.name)", systemImage: "calendar")
                            .font(.caption)
                            .foregroundStyle(Color.secondary)
                    }
                } footer: {
                    Text(sourceResource != nil
                         ? "El gasto sale del dinero compartido y queda asociado a esto."
                         : "El gasto sale del dinero compartido y se acredita al destinatario.")
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                }

                Section {
                    Picker("¿Quién pagó?", selection: $paidByMemberId) {
                        Text("Elige…").tag(Optional<UUID>.none)
                        ForEach(members) { m in
                            Text(m.displayName).tag(Optional(m.member.id))
                        }
                    }
                    .pickerStyle(.menu)
                } footer: {
                    Text("Por defecto eres tú. Cámbialo si alguien más lo pagó de su bolsa.")
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                }

                Section("Monto (\(currency))") {
                    TextField("0", text: $amountText)
                        .keyboardType(.decimalPad)
                }

                Section {
                    Picker("Cómo dividir", selection: $splitMode) {
                        ForEach(SplitMode.allCases, id: \.self) { mode in
                            Text(mode.displayLabel).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                splitInputSection

                Section("Nota (opcional)") {
                    TextField("ej: Bocadillos para la junta", text: $note, axis: .vertical)
                        .lineLimit(2...4)
                }

                Section {
                    DisclosureGroup("Más opciones") {
                        Picker("Reembolsar a", selection: $toMemberId) {
                            Text("Elige…").tag(Optional<UUID>.none)
                            ForEach(members) { m in
                                Text(m.displayName).tag(Optional(m.member.id))
                            }
                        }
                        .pickerStyle(.menu)
                        Text("Quién recibe el dinero del fondo. Por defecto la misma persona que pagó.")
                            .font(.caption)
                            .foregroundStyle(Color.secondary)
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.caption)
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
            .ruulSheetToolbar("Registrar gasto")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirmButtonLabel) {
                        RuulHaptic.light.trigger()
                        Task { await submit() }
                    }
                    .disabled(isSubmitting || successPhrase != nil || !isFormValid)
                }
            }
            .task(id: app.session?.user.id) {
                seedDefaults()
            }
            .onChange(of: paidByMemberId) { _, newValue in
                if !toMemberManuallySet { toMemberId = newValue }
            }
            .onChange(of: toMemberId) { _, newValue in
                if newValue != nil && newValue != paidByMemberId {
                    toMemberManuallySet = true
                }
            }
        }
        .sensoryFeedback(.success, trigger: successPhrase)
    }

    // MARK: - Warmth helpers (B.2 template)

    private var confirmButtonLabel: String {
        if successPhrase != nil { return "Listo" }
        if isSubmitting { return "Registrando…" }
        return "Registrar"
    }

    private func composeSuccessPhrase(paidBy: UUID, amount: Int64) -> String {
        let formatted = formatted(amount)
        let viewerMemberId = currentUserMemberId()
        let context = sourceResource.map { " de \($0.name)" } ?? ""
        if paidBy == viewerMemberId {
            return "Pagaste \(formatted)\(context)"
        }
        let name = memberName(paidBy)
        return "\(name) pagó \(formatted)\(context)"
    }

    private func memberName(_ id: UUID) -> String {
        members.first(where: { $0.member.id == id })?.displayName ?? "alguien"
    }

    private func currentUserMemberId() -> UUID? {
        guard let uid = app.session?.user.id else { return nil }
        return members.first(where: { $0.member.userId == uid })?.member.id
    }

    // MARK: - Mode-specific section

    @ViewBuilder
    private var splitInputSection: some View {
        Section {
            switch splitMode {
            case .equal:
                ForEach(members) { m in
                    Toggle(
                        m.displayName,
                        isOn: Binding(
                            get: { participantIds.contains(m.member.id) },
                            set: { isOn in
                                if isOn { participantIds.insert(m.member.id) }
                                else { participantIds.remove(m.member.id) }
                            }
                        )
                    )
                }
            case .exact:
                ForEach(members) { m in
                    HStack {
                        Text(m.displayName)
                        Spacer()
                        TextField("0", text: bindingForInput(m.member.id))
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 100)
                        Text(currency)
                            .font(.caption)
                            .foregroundStyle(Color.secondary)
                    }
                }
            case .percent:
                ForEach(members) { m in
                    HStack {
                        Text(m.displayName)
                        Spacer()
                        TextField("0", text: bindingForInput(m.member.id))
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 80)
                        Text("%")
                            .font(.caption)
                            .foregroundStyle(Color.secondary)
                    }
                }
            case .shares:
                ForEach(members) { m in
                    Stepper(
                        value: bindingForShares(m.member.id),
                        in: 0...20
                    ) {
                        HStack {
                            Text(m.displayName)
                            Spacer()
                            Text("\(perMemberShares[m.member.id, default: 0]) \(perMemberShares[m.member.id, default: 0] == 1 ? "parte" : "partes")")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(Color.secondary)
                        }
                    }
                }
            }
        } header: {
            Text("Dividir entre")
        } footer: {
            Text(splitFooter)
                .font(.caption)
                .foregroundStyle(footerColor)
        }
    }

    private func bindingForInput(_ id: UUID) -> Binding<String> {
        Binding(
            get: { perMemberInput[id] ?? "" },
            set: { perMemberInput[id] = $0 }
        )
    }

    private func bindingForShares(_ id: UUID) -> Binding<Int> {
        Binding(
            get: { perMemberShares[id] ?? 0 },
            set: { perMemberShares[id] = $0 }
        )
    }

    // MARK: - Defaults

    @MainActor
    private func seedDefaults() {
        guard paidByMemberId == nil else { return }
        guard let uid = app.session?.user.id,
              let me = members.first(where: { $0.member.userId == uid })?.member.id else {
            return
        }
        paidByMemberId = me
        if !toMemberManuallySet { toMemberId = me }
    }

    // MARK: - Validation + breakdown

    private var amountCents: Int64? {
        let trimmed = amountText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard !trimmed.isEmpty, let pesos = Double(trimmed), pesos > 0 else {
            return nil
        }
        return Int64((pesos * 100).rounded())
    }

    /// Parse a "$"-style decimal input ("12.34", "12,34") to cents.
    private func parseCents(_ raw: String) -> Int64? {
        let trimmed = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard !trimmed.isEmpty, let d = Double(trimmed), d >= 0 else { return nil }
        return Int64((d * 100).rounded())
    }

    private func parsePercent(_ raw: String) -> Double? {
        let trimmed = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard !trimmed.isEmpty, let d = Double(trimmed), d >= 0 else { return nil }
        return d
    }

    /// Computes the canonical breakdown for the current mode + inputs.
    /// Returns nil when the inputs don't form a valid split (e.g.
    /// exact sums to a different total, percentages don't add to 100).
    /// The "submit" button is disabled when this is nil.
    private var computedBreakdown: [SplitBreakdown]? {
        guard let total = amountCents else { return nil }
        switch splitMode {
        case .equal:
            let selected = members
                .map(\.member.id)
                .filter { participantIds.contains($0) }
            guard selected.count >= 1 else { return nil }
            let baseShare = total / Int64(selected.count)
            let remainder = total - baseShare * Int64(selected.count)
            // First N members absorb the rounding remainder (cent-by-cent).
            return selected.enumerated().map { idx, id in
                SplitBreakdown(
                    memberId: id,
                    shareCents: baseShare + (Int64(idx) < remainder ? 1 : 0)
                )
            }
        case .exact:
            var rows: [SplitBreakdown] = []
            var sum: Int64 = 0
            for m in members {
                let id = m.member.id
                guard let raw = perMemberInput[id], !raw.isEmpty,
                      let cents = parseCents(raw), cents > 0 else { continue }
                rows.append(SplitBreakdown(memberId: id, shareCents: cents))
                sum += cents
            }
            guard !rows.isEmpty, sum == total else { return nil }
            return rows
        case .percent:
            var pcts: [(UUID, Double)] = []
            var pctSum: Double = 0
            for m in members {
                let id = m.member.id
                guard let raw = perMemberInput[id], !raw.isEmpty,
                      let pct = parsePercent(raw), pct > 0 else { continue }
                pcts.append((id, pct))
                pctSum += pct
            }
            guard !pcts.isEmpty, abs(pctSum - 100.0) < 0.01 else { return nil }
            // Round to cents; absorb rounding remainder on the first row.
            var rows: [SplitBreakdown] = pcts.map { id, pct in
                SplitBreakdown(
                    memberId: id,
                    shareCents: Int64((Double(total) * pct / 100.0).rounded())
                )
            }
            let sum = rows.reduce(Int64(0)) { $0 + $1.shareCents }
            let diff = total - sum
            if diff != 0, !rows.isEmpty {
                rows[0] = SplitBreakdown(
                    memberId: rows[0].memberId,
                    shareCents: rows[0].shareCents + diff
                )
            }
            return rows
        case .shares:
            var entries: [(UUID, Int)] = []
            var totalShares: Int = 0
            for m in members {
                let id = m.member.id
                let count = perMemberShares[id] ?? 0
                guard count > 0 else { continue }
                entries.append((id, count))
                totalShares += count
            }
            guard !entries.isEmpty, totalShares > 0 else { return nil }
            var rows: [SplitBreakdown] = entries.map { id, count in
                SplitBreakdown(
                    memberId: id,
                    shareCents: Int64((Double(total) * Double(count) / Double(totalShares)).rounded())
                )
            }
            let sum = rows.reduce(Int64(0)) { $0 + $1.shareCents }
            let diff = total - sum
            if diff != 0, !rows.isEmpty {
                rows[0] = SplitBreakdown(
                    memberId: rows[0].memberId,
                    shareCents: rows[0].shareCents + diff
                )
            }
            return rows
        }
    }

    private var isFormValid: Bool {
        paidByMemberId != nil
        && toMemberId != nil
        && amountCents != nil
        && computedBreakdown != nil
    }

    // MARK: - Footer copy

    private var splitFooter: String {
        guard let total = amountCents else {
            return "Ingresa el monto primero."
        }
        switch splitMode {
        case .equal:
            let count = participantIds.count
            if count == 0 { return "Selecciona quiénes participan." }
            if count == 1 {
                return formatted(total) + " va a 1 persona."
            }
            let per = total / Int64(count)
            return "\(count) personas · cada una \(formatted(per))"
        case .exact:
            let sum: Int64 = members.reduce(0) { acc, m in
                guard let raw = perMemberInput[m.member.id],
                      let c = parseCents(raw) else { return acc }
                return acc + c
            }
            if sum == total {
                return "Suma exacta ✓"
            }
            let diff = total - sum
            return "Faltan \(formatted(abs(diff))) por asignar."
        case .percent:
            let sum: Double = members.reduce(0) { acc, m in
                guard let raw = perMemberInput[m.member.id],
                      let p = parsePercent(raw) else { return acc }
                return acc + p
            }
            if abs(sum - 100.0) < 0.01 {
                return "Suman 100% ✓"
            }
            let formattedPct = String(format: "%.1f", sum)
            return "Suman \(formattedPct)%. Debe ser 100%."
        case .shares:
            let total = perMemberShares.values.reduce(0, +)
            if total == 0 { return "Asigna partes a quien participe." }
            return "\(total) \(total == 1 ? "parte" : "partes") asignadas."
        }
    }

    private var footerColor: Color {
        computedBreakdown != nil ? .secondary : Color.ruulNegative
    }

    private func formatted(_ cents: Int64) -> String {
        let amount = Decimal(cents) / 100
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = currency
        f.maximumFractionDigits = 0
        return f.string(from: amount as NSDecimalNumber) ?? "\(currency) \(cents / 100)"
    }

    // MARK: - Submit

    @MainActor
    private func submit() async {
        guard let cents = amountCents,
              let toId = toMemberId,
              let paidById = paidByMemberId,
              let breakdown = computedBreakdown else { return }
        isSubmitting = true
        errorMessage = nil
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        // Derive the legacy `participants` array from the breakdown so
        // pre-mig-00370 readers still see something useful (the set of
        // member ids that owe a share).
        let participantList = breakdown.map(\.memberId)
        do {
            if let targetFundId {
                // Money UX Consolidation PR-B: protected / legacy fund
                // target — write directly to that fund via
                // `fund_record_expense` instead of resolving the shared
                // pool. Splits + paid_by + source_resource_id all
                // forwarded so the legacy surface gets parity with the
                // Phase 3 shared sheet.
                _ = try await app.fundRepo.recordExpense(
                    fundId: targetFundId,
                    amountCents: cents,
                    toMemberId: toId,
                    currency: currency,
                    note: trimmedNote.isEmpty ? nil : trimmedNote,
                    sourceEventId: nil,
                    clientId: clientId,
                    paidByMemberId: paidById,
                    participants: participantList,
                    splitMode: splitMode,
                    splitBreakdown: breakdown,
                    sourceResourceId: sourceResource?.id
                )
            } else {
                _ = try await app.fundRepo.recordSharedExpense(
                    groupId: groupId,
                    amountCents: cents,
                    toMemberId: toId,
                    currency: currency,
                    note: trimmedNote.isEmpty ? nil : trimmedNote,
                    sourceResourceId: sourceResource?.id,
                    clientId: clientId,
                    paidByMemberId: paidById,
                    participants: participantList,
                    splitMode: splitMode,
                    splitBreakdown: breakdown
                )
            }
            isSubmitting = false
            // FASE 3 D.2 + D.3: respirar la consecuencia + atribuir al humano.
            successPhrase = composeSuccessPhrase(paidBy: paidById, amount: cents)
            try? await Task.sleep(for: .milliseconds(700))
            onDidRecord()
            dismiss()
        } catch {
            isSubmitting = false
            errorMessage = error.localizedDescription
            RuulHaptic.error.trigger()
        }
    }
}
