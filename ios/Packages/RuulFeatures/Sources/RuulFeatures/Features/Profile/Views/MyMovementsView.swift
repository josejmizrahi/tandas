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
public struct MyMovementsView: View {
    @Bindable var coordinator: MyMovementsCoordinator
    @Environment(AppState.self) private var app

    /// FASE 4 Wave 3 (2026-05-25): netRow drill-down. Tap the cross-
    /// group "El grupo te debe / Tú le debes" aggregate to reveal the
    /// per-group breakdown that composes the net — only groups with a
    /// non-zero net show up, so the user sees where the position
    /// actually lives.
    @State private var netExpanded: Bool = false

    public init(coordinator: MyMovementsCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        AsyncContentView(
            phase: coordinator.phase,
            onRetry: { await coordinator.refresh() },
            empty: { emptyState },
            loaded: { _ in
                // Branch interno: si los groupMovements cargaron pero nadie
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
            .padding(.bottom, RuulSpacing.tabBarBottomSafeArea)
        }
        .scrollIndicators(.hidden)
        .refreshable { await coordinator.refresh() }
    }

    // MARK: - Hero pair

    private var heroPair: some View {
        HStack(alignment: .top, spacing: RuulSpacing.sm) {
            heroTile(
                label: "He pagado",
                amount: decimal(coordinator.totalPaidCents),
                color: coordinator.totalPaidCents > 0 ? .negative : .neutral
            )
            heroTile(
                label: "He recibido",
                amount: decimal(coordinator.totalReceivedCents),
                color: coordinator.totalReceivedCents > 0 ? .positive : .neutral
            )
        }
        .padding(.top, RuulSpacing.md)
    }

    private func heroTile(label: String, amount: Decimal, color: RuulMoneyView.SemanticColor) -> some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text(label)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color(.tertiaryLabel))
            RuulMoneyView(
                amount: amount,
                currency: "MXN",
                size: .medium,
                color: color
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(RuulSpacing.md)
        .background(Color.ruulBackgroundCanvas, in: RoundedRectangle(cornerRadius: RuulRadius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.lg, style: .continuous)
                .stroke(Color(.separator), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private var netRow: some View {
        // FASE 4 Wave 4 Phase 3 Tier 1: prefer `peerNetCents` —
        // excludes stake (aportes) so the label reflects peer debt
        // honestly. `coordinator.netCents` is kept as backstop for
        // first-paint when obligations haven't loaded across groups.
        let peerNet = coordinator.peerNetCents
        let net = peerNet != 0 ? peerNet : coordinator.netCents
        if net != 0 {
            let contributors = coordinator.groupMovements.filter { mv in
                (net > 0 && mv.netCents > 0) || (net < 0 && mv.netCents < 0)
            }
            .sorted { abs($0.netCents) > abs($1.netCents) }

            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(.snappy) { netExpanded.toggle() }
                } label: {
                    HStack(spacing: RuulSpacing.xs) {
                        Text(net > 0 ? "El grupo te debe" : "Tú le debes al grupo")
                            .font(.headline)
                            .foregroundStyle(Color.primary)
                        Spacer(minLength: RuulSpacing.sm)
                        RuulMoneyView(
                            amount: decimal(abs(net)),
                            currency: "MXN",
                            size: .medium,
                            color: net > 0 ? .positive : .negative
                        )
                        if !contributors.isEmpty {
                            Image(systemName: "chevron.down")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(Color.secondary)
                                .rotationEffect(.degrees(netExpanded ? 180 : 0))
                        }
                    }
                    .padding(RuulSpacing.md)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(contributors.isEmpty)

                if netExpanded && !contributors.isEmpty {
                    Divider()
                        .background(Color(.separator))
                    VStack(spacing: 0) {
                        ForEach(Array(contributors.enumerated()), id: \.element.id) { idx, mv in
                            netBreakdownRow(mv, viewerIsCreditor: net > 0)
                            if idx < contributors.count - 1 {
                                Divider()
                                    .background(Color(.separator))
                                    .padding(.leading, RuulSpacing.md)
                            }
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .background(Color.ruulBackgroundCanvas, in: RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous)
                    .stroke(Color(.separator), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous))
        }
    }

    /// Inline drill-down row for the netRow expansion. Shows ONE group's
    /// contribution to the cross-group net with a one-line phrase like
    /// "Cenas Quincenales · $200" — colored by the viewer's direction.
    private func netBreakdownRow(
        _ movements: MyMovementsCoordinator.GroupMovements,
        viewerIsCreditor: Bool
    ) -> some View {
        HStack(spacing: RuulSpacing.sm) {
            Text(movements.group.name)
                .font(.subheadline)
                .foregroundStyle(Color.primary)
                .lineLimit(1)
            Spacer(minLength: RuulSpacing.xs)
            RuulMoneyView(
                amount: decimal(abs(movements.netCents)),
                currency: "MXN",
                size: .small,
                showSign: false,
                color: viewerIsCreditor ? .positive : .negative
            )
        }
        .padding(.horizontal, RuulSpacing.md)
        .padding(.vertical, RuulSpacing.sm)
    }

    // MARK: - Per-group

    @ViewBuilder
    private var perGroupSection: some View {
        let active = coordinator.groupMovements.filter { $0.paidCents > 0 || $0.receivedCents > 0 }
        if !active.isEmpty {
            sectionContainer(title: "Por grupo", count: active.count) {
                ForEach(Array(active.enumerated()), id: \.element.id) { idx, movements in
                    perGroupRow(movements)
                    if idx < active.count - 1 { rowDivider }
                }
            }
        }
    }

    private func perGroupRow(_ movements: MyMovementsCoordinator.GroupMovements) -> some View {
        HStack(spacing: RuulSpacing.sm) {
            RuulGroupAvatar(
                groupName: movements.group.name,
                initials: movements.group.initials,
                category: movements.group.category,
                size: .lg
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(movements.group.name)
                    .font(.subheadline)
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                Text(perGroupSubtitle(movements))
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                RuulMoneyView(
                    amount: decimal(abs(movements.netCents)),
                    currency: "MXN",
                    size: .small,
                    showSign: false,
                    color: movements.netCents >= 0 ? .positive : .negative
                )
                Text(movements.netCents >= 0 ? "neto a favor" : "neto a deber")
                    .font(.footnote)
                    .foregroundStyle(Color(.tertiaryLabel))
            }
        }
        .padding(.horizontal, RuulSpacing.md)
        .padding(.vertical, RuulSpacing.sm)
    }

    private func perGroupSubtitle(_ movements: MyMovementsCoordinator.GroupMovements) -> String {
        let paid = formatCents(movements.paidCents)
        let recv = formatCents(movements.receivedCents)
        return "Pagaste \(paid) · Recibiste \(recv)"
    }

    // MARK: - Recent

    @ViewBuilder
    private var recentSection: some View {
        let recent = Array(coordinator.allEntriesNewestFirst.prefix(20))
        if !recent.isEmpty {
            sectionContainer(title: "Movimientos recientes", count: recent.count) {
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
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(humanTypeLabel(entry.type))
                    .font(.subheadline)
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                Text("\(groupName) · \(entry.occurredAt.ruulRelativeDescription)")
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
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
                    .font(.largeTitle.weight(.semibold))
                    .foregroundStyle(Color.secondary)
            }
            VStack(spacing: RuulSpacing.xs) {
                Text("Aún sin movimientos")
                    .font(.title.weight(.semibold))
                    .foregroundStyle(Color.primary)
                Text("Cuando registres una aportación, gasto o pago, aparecerá aquí con su grupo.")
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
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
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color(.tertiaryLabel))
                Spacer()
                if let count {
                    Text("\(count)")
                        .font(.footnote.monospacedDigit().weight(.bold))
                        .foregroundStyle(Color(.tertiaryLabel))
                }
            }
            .padding(.horizontal, RuulSpacing.xxs)
            VStack(spacing: 0) { content() }
                .background(Color.ruulBackgroundCanvas, in: RoundedRectangle(cornerRadius: RuulRadius.lg, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: RuulRadius.lg, style: .continuous)
                        .stroke(Color(.separator), lineWidth: 0.5)
                )
        }
    }

    private var rowDivider: some View {
        Divider()
            .background(Color(.separator))
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
