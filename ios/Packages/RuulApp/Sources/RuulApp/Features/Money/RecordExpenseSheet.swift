import SwiftUI
import RuulCore

/// Self-party expense form with Splitwise-style split picker.
///
/// V3-S1 surface. Founder pre-launch goal: parity-feel with Splitwise
/// on the divide-the-bill loop. The sheet:
///
/// - Pays from `paidBy = caller's membership in this group`.
/// - Writes to `resourceId = nil` (shared pool, doctrine_shared_money).
/// - Materialises peer-to-peer obligations via the per-member breakdown
///   (`record_expense` server trigger). Was hardcoded `.even` before
///   V3-S1; that branch silently emitted `p_split_breakdown = null` so
///   the server never created obligations — bug fixed implicitly here.
/// - Currency = MXN (V1 single currency).
///
/// Mints a `p_client_id` once on the first submit and reuses it across
/// retries so a flaky network can't double-post the same expense
/// (doctrine §15 / dev contract idempotency clause).
struct RecordExpenseSheet: View {
    let container: DependencyContainer
    let groupId: UUID
    let myMembershipId: UUID
    let onSubmitted: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var amountText: String = ""
    @State private var description: String = ""
    @State private var inKind: Bool = false
    @State private var isSubmitting: Bool = false
    @State private var error: UserFacingError?
    /// Stable across retries — minted on first submit attempt, reset on
    /// successful commit. Cancel discards it.
    @State private var clientId: String?
    /// V2-G5 — when the caller holds an active mandate they may record
    /// the expense on someone else's behalf. `nil` = acting in their
    /// own name (default).
    @State private var selectedMandateId: UUID?

    // MARK: - Split state

    @State private var splitMethod: ExpenseSplitCalculator.Method = .even
    /// Membership ids of selected participants. Includes the payer by
    /// default — Splitwise treats the payer as "owes themselves $0" so
    /// the server's payer-exclusion logic handles it cleanly.
    @State private var participantIds: Set<UUID> = []
    /// Per-member typed input for exact / percentage / shares modes.
    /// Keyed by membership_id; stringly typed so partial input doesn't
    /// nuke what the user is mid-typing.
    @State private var exactInput: [UUID: String] = [:]
    @State private var percentInput: [UUID: String] = [:]
    @State private var sharesInput: [UUID: String] = [:]

    var body: some View {
        NavigationStack {
            Form {
                amountSection
                detailsSection
                MandateBehalfPickerSection(
                    selection: $selectedMandateId,
                    availableMandates: availableMandates
                )
                if !inKind {
                    methodSection
                    participantsSection
                    breakdownSection
                }
            }
            .navigationTitle("Registrar gasto")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                await container.mandatesStore.refreshIfNeeded(groupId: groupId)
                await container.membersStore.refreshIfNeeded(groupId: groupId)
                seedParticipantsIfEmpty()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") {
                        clientId = nil
                        dismiss()
                    }
                    .disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await submit() }
                    } label: {
                        if isSubmitting {
                            ProgressView()
                        } else {
                            Text("Registrar")
                        }
                    }
                    .disabled(!isFormValid || isSubmitting)
                }
            }
            .alert(
                error?.title ?? "",
                isPresented: Binding(
                    get: { error != nil },
                    set: { if !$0 { error = nil } }
                ),
                actions: { Button("OK") { error = nil } },
                message: { Text(error?.message ?? "") }
            )
        }
    }

    // MARK: - Sections

    private var amountSection: some View {
        Section("Cuánto") {
            TextField("Monto en MXN", text: $amountText)
                .keyboardType(.decimalPad)
        }
    }

    private var detailsSection: some View {
        Section("Detalles (opcional)") {
            TextField("¿De qué fue?", text: $description, axis: .vertical)
                .lineLimit(1...4)
            Toggle("Fue en especie", isOn: $inKind)
        }
    }

    private var methodSection: some View {
        Section("¿Cómo se divide?") {
            Picker("Método", selection: $splitMethod) {
                Text("Por partes iguales").tag(ExpenseSplitCalculator.Method.even)
                Text("Montos exactos").tag(ExpenseSplitCalculator.Method.exact)
                Text("Porcentajes").tag(ExpenseSplitCalculator.Method.percentage)
                Text("Por partes").tag(ExpenseSplitCalculator.Method.shares)
            }
            .pickerStyle(.menu)
            Text(methodHint)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var participantsSection: some View {
        Section {
            ForEach(activeMembers, id: \.membershipId) { member in
                participantRow(for: member)
            }
        } header: {
            HStack {
                Text("Participa")
                Spacer()
                Button(allSelected ? "Quitar todos" : "Todos") {
                    toggleAllParticipants()
                }
                .font(.footnote)
            }
        } footer: {
            if participantIds.isEmpty {
                Text("Selecciona al menos un participante.")
                    .foregroundStyle(.secondary)
                    .font(.footnote)
            }
        }
    }

    @ViewBuilder
    private var breakdownSection: some View {
        if !participantIds.isEmpty, parsedAmount != nil {
            Section("Vista previa") {
                switch resolvedSplit {
                case .success(let shares):
                    breakdownPreview(shares: shares)
                case .failure(let message):
                    Text(message)
                        .foregroundStyle(.secondary)
                        .font(.footnote)
                }
            }
        }
    }

    @ViewBuilder
    private func breakdownPreview(shares: [ExpenseSplit.Share]) -> some View {
        ForEach(shares, id: \.membershipId) { share in
            HStack {
                Text(displayName(for: share.membershipId))
                Spacer()
                Text(formatMXN(share.amount))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        HStack {
            Text("Total")
                .fontWeight(.semibold)
            Spacer()
            Text(formatMXN(shares.reduce(Decimal(0)) { $0 + $1.amount }))
                .monospacedDigit()
                .fontWeight(.semibold)
        }
    }

    @ViewBuilder
    private func participantRow(for member: MembershipBoundaryItem) -> some View {
        let selected = participantIds.contains(member.membershipId ?? UUID())
        HStack(spacing: 12) {
            Button {
                toggle(member: member)
            } label: {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .imageScale(.large)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(member.displayName)
                if member.membershipId == myMembershipId {
                    Text("Tú (pagaste)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if member.status == .invited {
                    Text("Invitado · esperando")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if selected {
                participantInputField(for: member)
            }
        }
    }

    @ViewBuilder
    private func participantInputField(for member: MembershipBoundaryItem) -> some View {
        if let id = member.membershipId {
            switch splitMethod {
            case .even:
                EmptyView()
            case .exact:
                TextField("$0", text: bindingFor(map: $exactInput, key: id))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 100)
            case .percentage:
                HStack(spacing: 2) {
                    TextField("0", text: bindingFor(map: $percentInput, key: id))
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 70)
                    Text("%").foregroundStyle(.secondary)
                }
            case .shares:
                TextField("1", text: bindingFor(map: $sharesInput, key: id))
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 60)
            }
        } else {
            EmptyView()
        }
    }

    // MARK: - Derived

    /// V3-R0: includes both `active` and `invited` memberships so a
    /// pending invitee (placeholder membership with `joined_via =
    /// 'placeholder_claim'`) can be picked as participant and as payer
    /// right after the invite is sent — no need to wait for them to
    /// accept. Suspended/banned/left rows are excluded.
    private var activeMembers: [MembershipBoundaryItem] {
        container.membersStore.items.filter { item in
            item.kind == .membership
                && item.membershipId != nil
                && (item.status == .active || item.status == .invited)
        }
    }

    private var allSelected: Bool {
        let activeIds = Set(activeMembers.compactMap(\.membershipId))
        return !activeIds.isEmpty && activeIds.isSubset(of: participantIds)
    }

    /// Active mandates that authorize *me* (the caller) to act on
    /// someone else's behalf in the money scope.
    private var availableMandates: [GroupMandate] {
        container.mandatesStore.availableMandates(
            representativeMembershipId: myMembershipId,
            scope: .money
        )
    }

    /// V3 doctrine_mandate_in_money_rpcs — cuando el mandato
    /// seleccionado tiene `principalType == .membership` y
    /// `principalId != nil`, el `paid_by_membership_id` redirige al
    /// principal (acto-en-nombre-de). Para principal group/committee/
    /// role el caller queda como payer (esos mandatos modelan
    /// autoridad institucional, no identidad alternativa).
    /// Nil mandate → caller es payer (path normal).
    private var resolvedPaidByMembershipId: UUID {
        guard let mandateId = selectedMandateId,
              let mandate = availableMandates.first(where: { $0.id == mandateId }),
              mandate.principalType == .membership,
              let principalId = mandate.principalId
        else {
            return myMembershipId
        }
        return principalId
    }

    private var parsedAmount: Decimal? {
        let normalized = amountText
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, let value = Decimal(string: normalized) else { return nil }
        return value > 0 ? value : nil
    }

    private var orderedParticipantIds: [UUID] {
        // Stable order: visual order from members store, filtered by selection.
        activeMembers
            .compactMap(\.membershipId)
            .filter { participantIds.contains($0) }
    }

    /// Resolves the current UI state into a breakdown or a user-facing
    /// validation error. Both the preview and the submit path read from
    /// this single source of truth.
    private enum SplitResolution {
        case success([ExpenseSplit.Share])
        case failure(String)
    }
    private var resolvedSplit: SplitResolution {
        guard let amount = parsedAmount else {
            return .failure("Ingresa un monto válido.")
        }
        let ids = orderedParticipantIds
        guard !ids.isEmpty else {
            return .failure("Selecciona al menos un participante.")
        }
        switch splitMethod {
        case .even:
            return .success(ExpenseSplitCalculator.even(amount: amount, participants: ids))
        case .exact:
            let rows: [(membershipId: UUID, amount: Decimal)] = ids.map { id in
                (id, parseDecimal(exactInput[id]) ?? 0)
            }
            switch ExpenseSplitCalculator.exact(amount: amount, amounts: rows) {
            case .success(let shares):
                return .success(shares)
            case .failure(.sumMismatch(let expected, let actual)):
                return .failure("La suma es \(formatMXN(actual)), pero el gasto es \(formatMXN(expected)).")
            case .failure(.emptyParticipants):
                return .failure("Selecciona al menos un participante.")
            }
        case .percentage:
            let rows: [(membershipId: UUID, percent: Decimal)] = ids.map { id in
                (id, parseDecimal(percentInput[id]) ?? 0)
            }
            switch ExpenseSplitCalculator.percentages(amount: amount, percentages: rows) {
            case .success(let shares):
                return .success(shares)
            case .failure(.percentagesDoNotSumTo100(let actual)):
                return .failure("Los porcentajes suman \(formatPercent(actual)), no 100%.")
            case .failure(.emptyParticipants):
                return .failure("Selecciona al menos un participante.")
            }
        case .shares:
            let rows: [(membershipId: UUID, shareCount: Int)] = ids.map { id in
                (id, Int(sharesInput[id] ?? "") ?? 0)
            }
            switch ExpenseSplitCalculator.shares(amount: amount, shares: rows) {
            case .success(let shares):
                return .success(shares)
            case .failure(.allZeroOrNegative):
                return .failure("Asigna al menos una parte.")
            case .failure(.emptyParticipants):
                return .failure("Selecciona al menos un participante.")
            }
        }
    }

    private var isFormValid: Bool {
        guard parsedAmount != nil else { return false }
        if inKind { return true }
        if case .success = resolvedSplit { return true }
        return false
    }

    private var methodHint: String {
        switch splitMethod {
        case .even:
            return "Se divide en partes iguales entre los participantes seleccionados. Los centavos sobrantes se distribuyen de forma estable."
        case .exact:
            return "Escribe cuánto le toca a cada quien. La suma debe ser exactamente el monto del gasto."
        case .percentage:
            return "Escribe el porcentaje de cada quien. Deben sumar 100%."
        case .shares:
            return "Asigna partes enteras (ej. \"2\" si alguien paga doble). Se reparte proporcionalmente."
        }
    }

    // MARK: - Mutations

    private func seedParticipantsIfEmpty() {
        guard participantIds.isEmpty else { return }
        let ids = activeMembers.compactMap(\.membershipId)
        participantIds = Set(ids)
    }

    private func toggle(member: MembershipBoundaryItem) {
        guard let id = member.membershipId else { return }
        if participantIds.contains(id) {
            participantIds.remove(id)
            exactInput[id] = nil
            percentInput[id] = nil
            sharesInput[id] = nil
        } else {
            participantIds.insert(id)
            if sharesInput[id] == nil { sharesInput[id] = "1" }
        }
    }

    private func toggleAllParticipants() {
        let activeIds = Set(activeMembers.compactMap(\.membershipId))
        if activeIds.isSubset(of: participantIds) {
            participantIds = []
        } else {
            participantIds = activeIds
            for id in activeIds where sharesInput[id] == nil {
                sharesInput[id] = "1"
            }
        }
    }

    private func bindingFor(map: Binding<[UUID: String]>, key: UUID) -> Binding<String> {
        Binding(
            get: { map.wrappedValue[key] ?? "" },
            set: { map.wrappedValue[key] = $0 }
        )
    }

    private func displayName(for id: UUID) -> String {
        if let row = activeMembers.first(where: { $0.membershipId == id }) {
            return id == myMembershipId ? "Tú" : row.displayName
        }
        return "—"
    }

    private func parseDecimal(_ raw: String?) -> Decimal? {
        guard let raw = raw?
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        return Decimal(string: raw)
    }

    private func formatMXN(_ value: Decimal) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "MXN"
        f.locale = Locale(identifier: "es_MX")
        return f.string(from: value as NSNumber) ?? "—"
    }

    private func formatPercent(_ value: Decimal) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 2
        f.minimumFractionDigits = 0
        let n = f.string(from: value as NSNumber) ?? "\(value)"
        return "\(n)%"
    }

    private func submit() async {
        guard let amount = parsedAmount else { return }
        isSubmitting = true
        defer { isSubmitting = false }

        if clientId == nil { clientId = UUID().uuidString }
        let descriptionClean = description.trimmingCharacters(in: .whitespacesAndNewlines)

        let split: ExpenseSplit
        if inKind {
            // In-kind expenses don't produce obligations server-side
            // (RPC short-circuits when p_in_kind = true), so the split
            // payload is informational only. Carry the participant ids
            // anyway for audit symmetry.
            split = .even(participantIds: orderedParticipantIds)
        } else {
            switch resolvedSplit {
            case .success(let shares):
                split = .custom(breakdown: shares)
            case .failure(let message):
                self.error = UserFacingError(title: "Revisa el reparto", message: message)
                return
            }
        }

        // V3 doctrine_mandate_in_money_rpcs: cuando se eligió un mandato
        // cuyo principal es una membership específica, el `paid_by`
        // canonical es el principal (en cuyo nombre actúo), no yo. Si
        // el principal es group/committee/role el caller queda como
        // payer (esos mandatos cubren autorización sin redirigir
        // identidad del pagador).
        let resolvedPaidBy = resolvedPaidByMembershipId
        let draft = ExpenseDraft(
            groupId: groupId,
            resourceId: nil,
            amount: amount,
            paidByMembershipId: resolvedPaidBy,
            description: descriptionClean.isEmpty ? nil : descriptionClean,
            split: split,
            inKind: inKind,
            mandateId: selectedMandateId
        )
        do {
            _ = try await container.moneyRepository.recordOwnExpense(draft, clientId: clientId)
            clientId = nil
            onSubmitted()
        } catch {
            self.error = UserFacingError.from(error)
        }
    }
}
