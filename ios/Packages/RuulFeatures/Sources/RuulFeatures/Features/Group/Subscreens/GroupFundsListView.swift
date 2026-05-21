import SwiftUI
import RuulUI
import RuulCore

/// "Otros fondos" — group-scoped funds list, pushed from the GroupSpace
/// "Otros fondos" tile. Reads `fund_balance_view` via
/// `FundRepository.listForGroup`. No reusable `FundCard` exists yet,
/// so the row is composed inline using the canonical section card
/// chrome (`Color.ruulSurface` + separator stroke).
///
/// SharedMoney Phase 3: the canonical shared pool is EXCLUDED here — it
/// has its own `SharedMoneyCard` surface on the group home. We detect
/// it by cross-referencing each fund's id against the shared pool
/// summary's `sharedPoolId` (founder decision 9.1 option (c), zero
/// schema change). Only protected/legacy funds remain in this list.
@MainActor
public struct GroupFundsListView: View {
    public let group: RuulCore.Group
    public let onOpenFund: (Fund) -> Void

    @Environment(AppState.self) private var app

    @State private var funds: [Fund] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var hasLoaded = false

    public init(group: RuulCore.Group, onOpenFund: @escaping (Fund) -> Void) {
        self.group = group
        self.onOpenFund = onOpenFund
    }

    private var phase: LoadPhase<[Fund]> {
        let coordError: CoordinatorError? = errorMessage.map {
            CoordinatorError(title: "No pudimos cargar los fondos", message: $0, isRetryable: true)
        }
        return LoadPhase.fromCollection(
            value: funds,
            hasLoaded: hasLoaded,
            isLoading: isLoading,
            error: coordError
        )
    }

    public var body: some View {
        AsyncContentView(
            phase: phase,
            onRetry: { await load() },
            empty: {
                ContentUnavailableView {
                    Label("No hay fondos separados", systemImage: "banknote")
                } description: {
                    Text("Todo el dinero del grupo está en Dinero compartido.")
                }
            },
            loaded: { rows in
                ScrollView {
                    LazyVStack(spacing: RuulSpacing.sm) {
                        ForEach(rows, id: \.id) { fund in
                            row(fund)
                        }
                    }
                    .padding(RuulSpacing.lg)
                }
                .refreshable { await load() }
            }
        )
        .background(Color.ruulBackgroundRecessed.ignoresSafeArea())
        .navigationTitle("Otros fondos")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func row(_ fund: Fund) -> some View {
        Button {
            onOpenFund(fund)
        } label: {
            HStack(spacing: RuulSpacing.md) {
                Image(systemName: "banknote")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.ruulPositive)
                    .frame(width: 36, height: 36)
                    .background(Color.ruulPositive.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(fund.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                    Text(activitySummary(fund))
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Text(formatCurrency(fund.balanceCents, currency: fund.currency))
                    .font(.body.monospacedDigit().weight(.semibold))
                    .foregroundStyle(fund.balanceCents >= 0 ? Color.primary : Color.ruulNegative)
            }
            .padding(RuulSpacing.md)
            .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.lg))
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.lg)
                    .stroke(Color(.separator), lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func activitySummary(_ fund: Fund) -> String {
        let contribs = fund.contributionCount
        let expenses = fund.expenseCount
        switch (contribs, expenses) {
        case (0, 0): return "Sin movimientos"
        default:     return "\(contribs) aportes · \(expenses) gastos"
        }
    }

    private func formatCurrency(_ cents: Int64, currency: String) -> String {
        let units = Double(cents) / 100.0
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = currency
        nf.maximumFractionDigits = 0
        return nf.string(from: NSNumber(value: units)) ?? "\(currency) \(Int(units))"
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer {
            isLoading = false
            hasLoaded = true
        }
        do {
            async let allFundsTask = app.fundRepo.listForGroup(group.id)
            async let summaryTask = app.fundRepo.summaryForGroup(
                group.id, preferredCurrency: group.currency
            )
            let allFunds = try await allFundsTask
            let sharedPoolId = (try? await summaryTask)?.sharedPoolId
            funds = allFunds.filter { $0.fundId != sharedPoolId }
        } catch {
            errorMessage = "No pudimos cargar los fondos."
        }
    }
}
