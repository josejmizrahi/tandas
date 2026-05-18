import SwiftUI
import RuulUI
import RuulCore

/// "Mis movimientos" — cross-group personal money summary. Lives as a
/// navigation destination pushed from the Profile tab's ACTIVIDAD section.
///
/// Layout (Apple Wallet × Apple Sports):
///   ┌─────────────────────────────────────┐
///   │  HE PAGADO          HE RECIBIDO     │ hero pair
///   │  $1,200             $500             │
///   ├─────────────────────────────────────┤
///   │  POR GRUPO                          │
///   │  ┌───────────────────────────────┐   │
///   │  │ Cenas Quincenales    $300 ↓  │   │
///   │  │ Casa Tulum           $200 ↑  │   │
///   │  └───────────────────────────────┘   │
///   ├─────────────────────────────────────┤
///   │  MOVIMIENTOS RECIENTES              │
///   │  + $200 Aportación   · Cena jueves  │
///   │  − $500 Pago         · Cena pasada  │
///   └─────────────────────────────────────┘
public struct MyLedgerView: View {
    @Bindable var coordinator: MyLedgerCoordinator
    @Environment(AppState.self) private var app

    public init(coordinator: MyLedgerCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        AsyncContentView(
            phase: coordinator.phase,
            onRetry: { await coordinator.refresh() },
            empty: { emptyState },
            loaded: { _ in
                // Branch interno: si los ledgers cargaron pero nadie
                // movió plata, mostramos el mismo emptyState (mirror del
                // patrón `hasAnyActivity` original). Si hay totales,
                // renderizamos el contenido real con su scroll +
                // refreshable.
                if !coordinator.hasAnyActivity {
                    emptyState
                } else {
                    loadedScroll
                }
            }
        )
        .ruulAmbientScreen(palette: nil)
        .task { await coordinator.refresh() }
        .navigationTitle("Mis movimientos")
        .navigationBarTitleDisplayMode(.large)
    }

    private var loadedScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RuulSpacing.xxl) {
                heroPair
                netRow
                perGroupSection
                recentSection
            }
            .padding(.horizontal, RuulSpacing.lg)
            .padding(.top, RuulSpacing.xs)
            .padding(.bottom, RuulSpacing.s12)
        }
        .scrollIndicators(.hidden)
        .refreshable { await coordinator.refresh() }
    }

    // MARK: - Hero pair

    private var heroPair: some View {
        HStack(alignment: .top, spacing: RuulSpacing.sm) {
            heroTile(
                label: "HE PAGADO",
                amount: decimal(coordinator.totalPaidCents),
                color: coordinator.totalPaidCents > 0 ? .negative : .neutral
            )
            heroTile(
                label: "HE RECIBIDO",
                amount: decimal(coordinator.totalReceivedCents),
                color: coordinator.totalReceivedCents > 0 ? .positive : .neutral
            )
        }
        .padding(.top, RuulSpacing.md)
    }

    private func heroTile(label: String, amount: Decimal, color: RuulMoneyView.SemanticColor) -> some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text(label)
                .ruulTextStyle(RuulTypography.sectionLabel)
                .foregroundStyle(Color.ruulTextTertiary)
            RuulMoneyView(
                amount: amount,
                currency: "MXN",
                size: .medium,
                color: color
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(RuulSpacing.md)
        .background(Color.ruulBackgroundCanvas, in: RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous)
                .stroke(Color.ruulSeparator, lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private var netRow: some View {
        let net = coordinator.netCents
        if net != 0 {
            HStack(spacing: RuulSpacing.xs) {
                Text(net > 0 ? "El grupo te debe" : "Tú le debes al grupo")
                    .ruulTextStyle(RuulTypography.headline)
                    .foregroundStyle(Color.ruulTextPrimary)
                Spacer(minLength: RuulSpacing.sm)
                RuulMoneyView(
                    amount: decimal(abs(net)),
                    currency: "MXN",
                    size: .medium,
                    color: net > 0 ? .positive : .negative
                )
            }
            .padding(RuulSpacing.md)
            .background(Color.ruulBackgroundCanvas, in: RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                    .stroke(Color.ruulSeparator, lineWidth: 0.5)
            )
        }
    }

    // MARK: - Per-group

    @ViewBuilder
    private var perGroupSection: some View {
        let active = coordinator.ledgers.filter { $0.paidCents > 0 || $0.receivedCents > 0 }
        if !active.isEmpty {
            sectionContainer(title: "POR GRUPO", count: active.count) {
                ForEach(Array(active.enumerated()), id: \.element.id) { idx, ledger in
                    perGroupRow(ledger)
                    if idx < active.count - 1 { rowDivider }
                }
            }
        }
    }

    private func perGroupRow(_ ledger: MyLedgerCoordinator.GroupLedger) -> some View {
        HStack(spacing: RuulSpacing.sm) {
            RuulGroupAvatar(
                groupName: ledger.group.name,
                initials: ledger.group.initials,
                category: ledger.group.category,
                size: .lg
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(ledger.group.name)
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextPrimary)
                    .lineLimit(1)
                Text(perGroupSubtitle(ledger))
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextSecondary)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                RuulMoneyView(
                    amount: decimal(abs(ledger.netCents)),
                    currency: "MXN",
                    size: .small,
                    showSign: false,
                    color: ledger.netCents >= 0 ? .positive : .negative
                )
                Text(ledger.netCents >= 0 ? "neto a favor" : "neto a deber")
                    .ruulTextStyle(RuulTypography.footnote)
                    .foregroundStyle(Color.ruulTextTertiary)
            }
        }
        .padding(.horizontal, RuulSpacing.md)
        .padding(.vertical, RuulSpacing.sm)
    }

    private func perGroupSubtitle(_ ledger: MyLedgerCoordinator.GroupLedger) -> String {
        let paid = formatCents(ledger.paidCents)
        let recv = formatCents(ledger.receivedCents)
        return "Pagaste \(paid) · Recibiste \(recv)"
    }

    // MARK: - Recent

    @ViewBuilder
    private var recentSection: some View {
        let recent = Array(coordinator.allEntriesNewestFirst.prefix(20))
        if !recent.isEmpty {
            sectionContainer(title: "MOVIMIENTOS RECIENTES", count: recent.count) {
                ForEach(Array(recent.enumerated()), id: \.element.id) { idx, entry in
                    entryRow(entry)
                    if idx < recent.count - 1 { rowDivider }
                }
            }
        }
    }

    private func entryRow(_ entry: LedgerEntry) -> some View {
        let direction = coordinator.direction(of: entry)
        let signColor: RuulMoneyView.SemanticColor = {
            switch direction {
            case .in_:     return .positive
            case .out:     return .negative
            case .neutral: return .neutral
            }
        }()
        let groupName = coordinator.group(for: entry)?.name ?? "Grupo"
        return HStack(spacing: RuulSpacing.sm) {
            ZStack {
                Circle()
                    .fill(Color.ruulBackgroundRecessed)
                    .frame(width: 36, height: 36)
                Image(systemName: icon(for: entry.type))
                    .ruulTextStyle(RuulTypography.labelSemibold)
                    .foregroundStyle(Color.ruulTextSecondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(humanTypeLabel(entry.type))
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextPrimary)
                    .lineLimit(1)
                Text("\(groupName) · \(entry.occurredAt.ruulRelativeDescription)")
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextSecondary)
                    .lineLimit(1)
            }
            Spacer()
            RuulMoneyView(
                amount: decimal(entry.amountCents),
                currency: entry.currency,
                size: .small,
                showSign: false,
                color: signColor
            )
        }
        .padding(.horizontal, RuulSpacing.md)
        .padding(.vertical, RuulSpacing.sm)
    }

    private func icon(for type: String) -> String {
        switch type {
        case LedgerEntry.Kind.expense:       return "cart.fill"
        case LedgerEntry.Kind.contribution:  return "arrow.up.bin.fill"
        case LedgerEntry.Kind.payout:        return "tray.and.arrow.down.fill"
        case LedgerEntry.Kind.settlement:    return "arrow.left.arrow.right"
        case LedgerEntry.Kind.reimbursement: return "arrow.uturn.left"
        case LedgerEntry.Kind.fineIssued:    return "exclamationmark.triangle.fill"
        case LedgerEntry.Kind.finePaid:      return "checkmark.seal.fill"
        default:                             return "circle.dotted"
        }
    }

    private func humanTypeLabel(_ type: String) -> String {
        switch type {
        case LedgerEntry.Kind.expense:       return "Gasto"
        case LedgerEntry.Kind.contribution:  return "Aportación"
        case LedgerEntry.Kind.payout:        return "Recibí del grupo"
        case LedgerEntry.Kind.settlement:    return "Pago entre miembros"
        case LedgerEntry.Kind.reimbursement: return "Reembolso"
        case LedgerEntry.Kind.fineIssued:    return "Multa emitida"
        case LedgerEntry.Kind.finePaid:      return "Multa pagada"
        default:                             return type.capitalized
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: RuulSpacing.lg) {
            Spacer(minLength: RuulSpacing.xxl)
            ZStack {
                Circle()
                    .fill(Color.ruulSurface)
                    .frame(width: 80, height: 80)
                Image(systemName: "tray")
                    .ruulTextStyle(RuulTypography.displayMedium)
                    .foregroundStyle(Color.ruulTextSecondary)
            }
            VStack(spacing: RuulSpacing.xs) {
                Text("Aún sin movimientos")
                    .ruulTextStyle(RuulTypography.titleLarge)
                    .foregroundStyle(Color.ruulTextPrimary)
                Text("Cuando registres una aportación, gasto o pago, aparecerá aquí con su grupo.")
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, RuulSpacing.lg)
            }
            Spacer()
        }
    }

    // MARK: - Container helpers (mirrors ProfileView's section pattern)

    @ViewBuilder
    private func sectionContainer<Content: View>(
        title: String,
        count: Int? = nil,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .ruulTextStyle(RuulTypography.sectionLabel)
                    .foregroundStyle(Color.ruulTextTertiary)
                Spacer()
                if let count {
                    Text("\(count)")
                        .ruulTextStyle(RuulTypography.statSmall)
                        .foregroundStyle(Color.ruulTextTertiary)
                }
            }
            .padding(.horizontal, RuulSpacing.xxs)
            VStack(spacing: 0) { content() }
                .background(Color.ruulBackgroundCanvas, in: RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous)
                        .stroke(Color.ruulSeparator, lineWidth: 0.5)
                )
        }
    }

    private var rowDivider: some View {
        Divider()
            .background(Color.ruulSeparator)
            .padding(.leading, 56)
    }

    // MARK: - Formatting

    private func decimal(_ cents: Int64) -> Decimal {
        Decimal(cents) / 100
    }

    private func formatCents(_ cents: Int64) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = "MXN"
        nf.maximumFractionDigits = 0
        return nf.string(from: NSDecimalNumber(value: cents / 100)) ?? "$\(cents/100)"
    }
}
