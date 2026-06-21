import SwiftUI
import RuulCore

/// F.11 — registrar el resultado de un juego: el perdedor le debe al ganador
/// (obligation tipo game_debt).
public struct RecordGameResultView: View {
    let context: AppContext
    let store: MoneyStore
    let container: DependencyContainer

    @Environment(\.dismiss) private var dismiss
    /// 2026-06-21 — P0 #5 friend-group launch: presets de juego visibles para
    /// que el usuario no tenga que escribir "Quiniela del Mundial" a mano cada
    /// vez. El gameName sigue siendo texto libre (backend pass-through), pero
    /// el picker arriba sugiere los tipos comunes.
    @State private var preset: GamePreset = .poker
    @State private var gameName = GamePreset.poker.defaultName
    @State private var winnerActorId: UUID?
    @State private var loserActorId: UUID?
    @State private var amountText = "100"
    @State private var currency = "MXN"
    @State private var runner = ActionRunner()

    public init(context: AppContext, store: MoneyStore, container: DependencyContainer) {
        self.context = context
        self.store = store
        self.container = container
    }

    private var amount: Double? { Double(amountText) }

    public var body: some View {
        NavigationStack {
            Form {
                Section("Juego") {
                    Picker("Tipo", selection: $preset) {
                        ForEach(GamePreset.allCases) { p in
                            Label(p.label, systemImage: p.symbolName).tag(p)
                        }
                    }
                    .onChange(of: preset) { _, newValue in
                        // El usuario puede editar el nombre libremente; sólo
                        // pre-llenamos al cambiar el preset (no machacamos lo
                        // que ya escribió si vuelve al mismo preset).
                        gameName = newValue.defaultName
                    }
                    TextField("Nombre del juego", text: $gameName)
                    HStack {
                        Text("Apuesta $")
                        TextField("0.00", text: $amountText)
                            .keyboardType(.decimalPad)
                        TextField("MXN", text: $currency)
                            .textInputAutocapitalization(.characters)
                            .frame(width: 64)
                            .multilineTextAlignment(.trailing)
                    }
                }

                Section("Ganador") {
                    memberPicker(selection: $winnerActorId, exclude: loserActorId)
                }

                Section("Perdedor") {
                    memberPicker(selection: $loserActorId, exclude: winnerActorId)
                }

                Section {
                    Button {
                        Task { await record() }
                    } label: {
                        if runner.isRunning {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Text("Registrar resultado").frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(!isValid || runner.isRunning)
                } footer: {
                    if let winnerActorId, let loserActorId, let amount {
                        Text("\(store.displayName(for: loserActorId)) le deberá \(amount.currencyLabel(currency)) a \(store.displayName(for: winnerActorId)).")
                    }
                }
            }
            .navigationTitle("Resultado de juego")
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
        }
        .ruulSheet()
    }

    @ViewBuilder
    private func memberPicker(selection: Binding<UUID?>, exclude: UUID?) -> some View {
        ForEach(store.members.filter { $0.actorId != exclude }) { member in
            Button {
                selection.wrappedValue = member.actorId
            } label: {
                HStack {
                    ActorInitialsView(name: member.displayName, size: 30)
                    Text(member.displayName)
                        .foregroundStyle(.primary)
                    Spacer()
                    if selection.wrappedValue == member.actorId {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.tint)
                    }
                }
            }
        }
    }

    private var isValid: Bool {
        winnerActorId != nil && loserActorId != nil && winnerActorId != loserActorId
            && (amount ?? 0) > 0 && !gameName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func record() async {
        guard let winnerActorId, let loserActorId, let amount else { return }
        let success = await runner.run {
            _ = try await store.recordGameResult(
                RecordGameResultInput(
                    contextId: context.id,
                    gameName: gameName.trimmingCharacters(in: .whitespaces),
                    winnerActorId: winnerActorId,
                    loserActorId: loserActorId,
                    amount: amount,
                    currency: currency,
                    clientId: UUID().uuidString
                ),
                context: context
            )
        }
        if success { dismiss() }
    }
}

/// F.11 — registrar una multa manual a un miembro.
public struct RecordFineView: View {
    let context: AppContext
    let store: MoneyStore
    let container: DependencyContainer

    @Environment(\.dismiss) private var dismiss
    @State private var debtorActorId: UUID?
    @State private var amountText = "100"
    @State private var currency = "MXN"
    @State private var reason = ""
    @State private var runner = ActionRunner()

    public init(context: AppContext, store: MoneyStore, container: DependencyContainer) {
        self.context = context
        self.store = store
        self.container = container
    }

    private var amount: Double? { Double(amountText) }

    public var body: some View {
        NavigationStack {
            Form {
                Section("A quién") {
                    ForEach(store.members) { member in
                        Button {
                            debtorActorId = member.actorId
                        } label: {
                            HStack {
                                ActorInitialsView(name: member.displayName, size: 30)
                                Text(member.displayName)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if debtorActorId == member.actorId {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                }

                Section("Multa") {
                    HStack {
                        Text("$")
                        TextField("0.00", text: $amountText)
                            .keyboardType(.decimalPad)
                        TextField("MXN", text: $currency)
                            .textInputAutocapitalization(.characters)
                            .frame(width: 64)
                            .multilineTextAlignment(.trailing)
                    }
                    TextField("Razón (opcional)", text: $reason)
                }

                Section {
                    Button {
                        Task { await record() }
                    } label: {
                        if runner.isRunning {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Text("Aplicar multa").frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(debtorActorId == nil || (amount ?? 0) <= 0 || runner.isRunning)
                } footer: {
                    Text("La multa queda como deuda del miembro hacia \(context.displayName).")
                }
            }
            .navigationTitle("Multa manual")
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
        }
        .ruulSheet()
    }

    private func record() async {
        guard let debtorActorId, let amount else { return }
        let success = await runner.run {
            try await store.recordFine(
                context: context,
                debtorActorId: debtorActorId,
                amount: amount,
                currency: currency,
                reason: reason.isEmpty ? nil : reason
            )
        }
        if success { dismiss() }
    }
}

// MARK: - Game presets (P0 #5)

/// Presets de juegos comunes en grupos de amigos. UI sugar: el preset cambia
/// el nombre por defecto. El backend sigue guardando `game_name` como texto
/// libre (sin schema change). Cuando el founder valide, podemos persistir el
/// tipo en `obligations.metadata.game_type` para analytics/leaderboards.
private enum GamePreset: String, CaseIterable, Identifiable {
    case poker
    case quiniela
    case mundial
    case fantasy
    case domino
    case billar
    case boardGame
    case otro

    var id: String { rawValue }

    var label: String {
        switch self {
        case .poker:      return "Poker"
        case .quiniela:   return "Quiniela"
        case .mundial:    return "Mundial"
        case .fantasy:    return "Fantasy"
        case .domino:     return "Dominó"
        case .billar:     return "Billar"
        case .boardGame:  return "Juego de mesa"
        case .otro:       return "Otro"
        }
    }

    var defaultName: String {
        switch self {
        case .poker:      return "Poker"
        case .quiniela:   return "Quiniela"
        case .mundial:    return "Quiniela del Mundial"
        case .fantasy:    return "Fantasy"
        case .domino:     return "Dominó"
        case .billar:     return "Billar"
        case .boardGame:  return "Catan"
        case .otro:       return ""
        }
    }

    var symbolName: String {
        switch self {
        case .poker:      return "suit.spade.fill"
        case .quiniela:   return "list.number"
        case .mundial:    return "soccerball"
        case .fantasy:    return "sportscourt.fill"
        case .domino:     return "rectangle.split.3x1.fill"
        case .billar:     return "circle.fill"
        case .boardGame:  return "dice.fill"
        case .otro:       return "gamecontroller.fill"
        }
    }
}

#Preview("Resultado de juego") {
    RecordGameResultView(
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

#Preview("Multa manual") {
    RecordFineView(
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
