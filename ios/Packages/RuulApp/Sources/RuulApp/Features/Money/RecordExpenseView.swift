import SwiftUI
import RuulCore

/// F.11 — registrar un gasto con split equal o custom (SplitEditor).
/// El backend crea las obligations de cada deudor hacia quien pagó.
public struct RecordExpenseView: View {
    let context: AppContext
    let store: MoneyStore
    let container: DependencyContainer

    @Environment(\.dismiss) private var dismiss
    @State private var description = ""
    @State private var amountText = ""
    @State private var currency = "MXN"
    @State private var paidByActorId: UUID?
    @State private var splitMethod: SplitMethod = .equal
    @State private var excludedActorIds: Set<UUID> = []
    @State private var customAmounts: [UUID: String] = [:]
    @State private var runner = ActionRunner()
    @State private var resultNotice: String?

    private enum SplitMethod: String, CaseIterable, Identifiable {
        case equal = "Partes iguales"
        case custom = "Montos personalizados"
        var id: String { rawValue }
    }

    public init(context: AppContext, store: MoneyStore, container: DependencyContainer) {
        self.context = context
        self.store = store
        self.container = container
    }

    private var myActorId: UUID? { container.currentActorStore.actorId }
    private var amount: Double? { Double(amountText.replacingOccurrences(of: ",", with: "")) }

    /// Miembros que participan en el split (no excluidos).
    private var participants: [ContextMember] {
        store.members.filter { !excludedActorIds.contains($0.actorId) }
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("Gasto") {
                    TextField("¿Qué se pagó? (Cena, súper…)", text: $description)
                    HStack {
                        Text("$")
                        TextField("0.00", text: $amountText)
                            .keyboardType(.decimalPad)
                        TextField("MXN", text: $currency)
                            .textInputAutocapitalization(.characters)
                            .frame(width: 64)
                            .multilineTextAlignment(.trailing)
                    }
                }

                Section("Quién pagó") {
                    Picker("Pagó", selection: $paidByActorId) {
                        Text("Yo").tag(nil as UUID?)
                        ForEach(store.members) { member in
                            Text(member.displayName).tag(member.actorId as UUID?)
                        }
                    }
                }

                // SplitEditor
                Section("Cómo se reparte") {
                    Picker("Método", selection: $splitMethod) {
                        ForEach(SplitMethod.allCases) { method in
                            Text(method.rawValue).tag(method)
                        }
                    }
                    .pickerStyle(.segmented)

                    ForEach(store.members) { member in
                        splitRow(member)
                    }
                }

                splitSummarySection

                Section {
                    Button {
                        Task { await record() }
                    } label: {
                        if runner.isRunning {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Text("Registrar gasto").frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(!isValid || runner.isRunning)
                }
            }
            .navigationTitle("Registrar gasto")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
            }
            .task {
                if store.members.isEmpty {
                    await store.load(context: context)
                }
            }
            .actionErrorAlert(runner)
            .alert("Gasto registrado", isPresented: Binding(
                get: { resultNotice != nil },
                set: { if !$0 { resultNotice = nil; dismiss() } }
            )) {
                Button("OK") {
                    resultNotice = nil
                    dismiss()
                }
            } message: {
                Text(resultNotice ?? "")
            }
        }
    }

    // MARK: - SplitEditor rows

    @ViewBuilder
    private func splitRow(_ member: ContextMember) -> some View {
        let isExcluded = excludedActorIds.contains(member.actorId)

        HStack(spacing: 12) {
            Button {
                toggleExclusion(member.actorId)
            } label: {
                Image(systemName: isExcluded ? "circle" : "checkmark.circle.fill")
                    .foregroundStyle(isExcluded ? Color.secondary : Color.accentColor)
                    .font(.title3)
            }
            .buttonStyle(.borderless)

            Text(member.displayName)
                .foregroundStyle(isExcluded ? .secondary : .primary)
                .strikethrough(isExcluded)

            Spacer()

            if !isExcluded {
                switch splitMethod {
                case .equal:
                    if let amount, !participants.isEmpty {
                        Text((amount / Double(participants.count)).currencyLabel(nil))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                case .custom:
                    TextField("0.00", text: Binding(
                        get: { customAmounts[member.actorId] ?? "" },
                        set: { customAmounts[member.actorId] = $0 }
                    ))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 90)
                    .textFieldStyle(.roundedBorder)
                }
            }
        }
    }

    @ViewBuilder
    private var splitSummarySection: some View {
        if splitMethod == .custom, let amount {
            let total = customTotal
            Section {
                HStack {
                    Text("Suma del reparto")
                    Spacer()
                    Text(total.currencyLabel(currency))
                        .foregroundStyle(abs(total - amount) < 0.01 ? .green : .red)
                }
                if abs(total - amount) >= 0.01 {
                    Text("Debe sumar exactamente \(amount.currencyLabel(currency))")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    // MARK: - Lógica

    private var customTotal: Double {
        participants.reduce(0) { sum, member in
            sum + (Double(customAmounts[member.actorId] ?? "") ?? 0)
        }
    }

    private var isValid: Bool {
        guard let amount, amount > 0,
              !description.trimmingCharacters(in: .whitespaces).isEmpty,
              !participants.isEmpty else { return false }
        if splitMethod == .custom {
            return abs(customTotal - amount) < 0.01
        }
        return true
    }

    private func toggleExclusion(_ actorId: UUID) {
        if excludedActorIds.contains(actorId) {
            excludedActorIds.remove(actorId)
        } else {
            excludedActorIds.insert(actorId)
            customAmounts[actorId] = nil
        }
    }

    private func record() async {
        guard let amount else { return }
        let success = await runner.run {
            let input: RecordExpenseInput
            if splitMethod == .custom {
                let splits = participants.compactMap { member -> ExpenseSplit? in
                    guard let value = Double(customAmounts[member.actorId] ?? ""), value > 0 else { return nil }
                    return ExpenseSplit(actorId: member.actorId, amount: value)
                }
                input = RecordExpenseInput(
                    contextId: context.id,
                    amount: amount,
                    currency: currency,
                    description: description.trimmingCharacters(in: .whitespaces),
                    splitMethod: "custom",
                    splits: splits,
                    paidByActorId: paidByActorId,
                    clientId: UUID().uuidString
                )
            } else {
                input = RecordExpenseInput(
                    contextId: context.id,
                    amount: amount,
                    currency: currency,
                    description: description.trimmingCharacters(in: .whitespaces),
                    splitWith: participants.map(\.actorId),
                    excludedActorIds: excludedActorIds.isEmpty ? nil : Array(excludedActorIds),
                    splitMethod: "equal",
                    paidByActorId: paidByActorId,
                    clientId: UUID().uuidString
                )
            }
            let result = try await store.recordExpense(input, context: context)
            if let share = result.sharePerPerson {
                resultNotice = "Cada quien debe \(share.currencyLabel(currency)) a \(payerName)."
            } else {
                resultNotice = "Se crearon \(result.obligations.count) deudas hacia \(payerName)."
            }
        }
        if !success {
            resultNotice = nil
        }
    }

    private var payerName: String {
        if let paidByActorId {
            return store.displayName(for: paidByActorId)
        }
        return "ti"
    }
}

#Preview("Registrar gasto") {
    RecordExpenseView(
        context: AppContext(
            id: MockRuulRPCClient.DemoIds.cenaSemanal,
            kind: .collective,
            subtype: "friend_group",
            displayName: "Cena Semanal"
        ),
        store: MoneyStore(rpc: MockRuulRPCClient.demo()),
        container: .demo()
    )
}
