import SwiftUI
import RuulUI
import RuulCore

/// Group-wide Money surface. Lives as a sub-tab of GroupTabView post-G1.
///
/// Layout:
///   ┌───────────────────────────────────┐
///   │  [+ Gasto] [+ Aportación]         │ quick actions
///   ├───────────────────────────────────┤
///   │  CUENTAS PENDIENTES               │
///   │   José → Daniel  $450             │
///   │   Linda → Sara   $200             │
///   ├───────────────────────────────────┤
///   │  GASTOS RECIENTES                 │
///   │   Cena jueves     $850 · Ale      │
///   ├───────────────────────────────────┤
///   │  FONDOS                           │
///   │   Mantenimiento  $14,500          │
///   ├───────────────────────────────────┤
///   │  PAGOS ENTRE MIEMBROS             │
///   │   Beto → José    $50              │
///   └───────────────────────────────────┘
public struct GroupMoneyView: View {
    @Bindable var coordinator: GroupMoneyCoordinator
    /// Triggered by the "+ Gasto" / "+ Aportación" quick action buttons.
    /// Caller (GroupTabView → MainTabView) opens the ResourceWizard cover.
    public let onCreateMoneyEntry: () -> Void

    public init(coordinator: GroupMoneyCoordinator, onCreateMoneyEntry: @escaping () -> Void) {
        self.coordinator = coordinator
        self.onCreateMoneyEntry = onCreateMoneyEntry
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RuulSpacing.xxl) {
                quickActions
                if coordinator.isLoading && !coordinator.hasAnyActivity {
                    loadingState
                } else if !coordinator.hasAnyActivity {
                    emptyState
                } else {
                    iousSection
                    fundsSection
                    expensesSection
                    settlementsSection
                }
            }
            .padding(.horizontal, RuulSpacing.screenPadding)
            .padding(.top, RuulSpacing.xs)
            .padding(.bottom, RuulSpacing.tabBarBottomSafeArea)
        }
        .scrollIndicators(.hidden)
        .refreshable { await coordinator.refresh() }
        .task { await coordinator.refresh() }
    }

    // MARK: - Quick actions

    private var quickActions: some View {
        HStack(spacing: RuulSpacing.sm) {
            quickActionButton(label: "Gasto",     icon: "cart.fill")
            quickActionButton(label: "Aportación", icon: "arrow.up.bin.fill")
        }
    }

    private func quickActionButton(label: String, icon: String) -> some View {
        Button(action: onCreateMoneyEntry) {
            HStack(spacing: RuulSpacing.xxs) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .accessibilityHidden(true)
                Text(label)
                    .ruulTextStyle(RuulTypography.callout)
            }
            .foregroundStyle(Color.ruulTextPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, RuulSpacing.sm)
            .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                    .stroke(Color.ruulSeparator, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Pairwise IOUs

    @ViewBuilder
    private var iousSection: some View {
        let ious = coordinator.pairwiseIOUs
        if !ious.isEmpty {
            sectionContainer(title: "CUENTAS PENDIENTES", count: ious.count) {
                ForEach(Array(ious.enumerated()), id: \.element.id) { idx, iou in
                    iouRow(iou)
                    if idx < ious.count - 1 { divider }
                }
            }
        } else if !coordinator.memberBalances.isEmpty {
            // Balanced — everyone is square. Show a tiny celebratory tile.
            HStack(spacing: RuulSpacing.xs) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(Color.ruulPositive)
                Text("Todos a mano. Sin cuentas pendientes.")
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextSecondary)
                Spacer()
            }
            .padding(RuulSpacing.md)
            .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                    .stroke(Color.ruulSeparator, lineWidth: 0.5)
            )
        }
    }

    private func iouRow(_ iou: GroupMoneyCoordinator.IOU) -> some View {
        HStack(spacing: RuulSpacing.sm) {
            RuulAvatar(name: iou.fromDisplayName, imageURL: iou.fromAvatarURL, size: .small)
            Image(systemName: "arrow.right")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.ruulTextTertiary)
                .accessibilityHidden(true)
            RuulAvatar(name: iou.toDisplayName, imageURL: iou.toAvatarURL, size: .small)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(iou.fromDisplayName) → \(iou.toDisplayName)")
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextPrimary)
                    .lineLimit(1)
                Text(amountText(iou.amountCents))
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextSecondary)
            }
            Spacer()
            RuulMoneyView(
                amount: decimal(iou.amountCents),
                currency: "MXN",
                size: .small,
                color: .negative
            )
        }
        .padding(.horizontal, RuulSpacing.md)
        .padding(.vertical, RuulSpacing.sm)
    }

    // MARK: - Funds

    @ViewBuilder
    private var fundsSection: some View {
        if !coordinator.funds.isEmpty {
            sectionContainer(title: "FONDOS", count: coordinator.funds.count) {
                ForEach(Array(coordinator.funds.enumerated()), id: \.element.id) { idx, row in
                    fundRow(row)
                    if idx < coordinator.funds.count - 1 { divider }
                }
            }
        }
    }

    private func fundRow(_ row: ResourceRow) -> some View {
        HStack(spacing: RuulSpacing.sm) {
            ZStack {
                Circle().fill(Color.ruulSurface).frame(width: 36, height: 36)
                Image(systemName: "banknote")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.ruulTextPrimary)
            }
            Text(fundName(row))
                .ruulTextStyle(RuulTypography.body)
                .foregroundStyle(Color.ruulTextPrimary)
                .lineLimit(1)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.ruulTextTertiary)
        }
        .padding(.horizontal, RuulSpacing.md)
        .padding(.vertical, RuulSpacing.sm)
    }

    private func fundName(_ row: ResourceRow) -> String {
        if case let .string(s) = row.metadata["name"]  { return s }
        if case let .string(s) = row.metadata["title"] { return s }
        return "Fondo"
    }

    // MARK: - Recent expenses

    @ViewBuilder
    private var expensesSection: some View {
        if !coordinator.recentExpenses.isEmpty {
            sectionContainer(title: "GASTOS RECIENTES", count: coordinator.recentExpenses.count) {
                ForEach(Array(coordinator.recentExpenses.enumerated()), id: \.element.id) { idx, entry in
                    expenseRow(entry)
                    if idx < coordinator.recentExpenses.count - 1 { divider }
                }
            }
        }
    }

    private func expenseRow(_ entry: LedgerEntry) -> some View {
        let payerName = coordinator.displayName(for: entry.fromMemberId) ?? "Alguien"
        return HStack(spacing: RuulSpacing.sm) {
            ZStack {
                Circle().fill(Color.ruulBackgroundRecessed).frame(width: 36, height: 36)
                Image(systemName: entry.type == LedgerEntry.Kind.expense ? "cart.fill" : "arrow.up.bin.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.ruulTextSecondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(noteOrLabel(entry))
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextPrimary)
                    .lineLimit(1)
                Text("\(payerName) · \(entry.occurredAt.ruulRelativeDescription)")
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextSecondary)
                    .lineLimit(1)
            }
            Spacer()
            RuulMoneyView(
                amount: decimal(entry.amountCents),
                currency: entry.currency,
                size: .small,
                color: .neutral
            )
        }
        .padding(.horizontal, RuulSpacing.md)
        .padding(.vertical, RuulSpacing.sm)
    }

    private func noteOrLabel(_ entry: LedgerEntry) -> String {
        if case let .object(meta) = entry.metadata,
           case let .string(note) = meta["note"] ?? .null,
           !note.isEmpty {
            return note
        }
        return entry.type == LedgerEntry.Kind.expense ? "Gasto" : "Aportación"
    }

    // MARK: - Settlements

    @ViewBuilder
    private var settlementsSection: some View {
        if !coordinator.recentSettlements.isEmpty {
            sectionContainer(title: "PAGOS ENTRE MIEMBROS", count: coordinator.recentSettlements.count) {
                ForEach(Array(coordinator.recentSettlements.enumerated()), id: \.element.id) { idx, entry in
                    settlementRow(entry)
                    if idx < coordinator.recentSettlements.count - 1 { divider }
                }
            }
        }
    }

    private func settlementRow(_ entry: LedgerEntry) -> some View {
        let fromName = coordinator.displayName(for: entry.fromMemberId) ?? "Alguien"
        let toName   = coordinator.displayName(for: entry.toMemberId)   ?? "Alguien"
        return HStack(spacing: RuulSpacing.sm) {
            ZStack {
                Circle().fill(Color.ruulBackgroundRecessed).frame(width: 36, height: 36)
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.ruulTextSecondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("\(fromName) → \(toName)")
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextPrimary)
                    .lineLimit(1)
                Text(entry.occurredAt.ruulRelativeDescription)
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextSecondary)
            }
            Spacer()
            RuulMoneyView(
                amount: decimal(entry.amountCents),
                currency: entry.currency,
                size: .small,
                color: .positive
            )
        }
        .padding(.horizontal, RuulSpacing.md)
        .padding(.vertical, RuulSpacing.sm)
    }

    // MARK: - States

    private var loadingState: some View {
        RuulLoadingState()
            .frame(maxWidth: .infinity, minHeight: 200)
    }

    private var emptyState: some View {
        VStack(spacing: RuulSpacing.lg) {
            Spacer(minLength: RuulSpacing.xl)
            ZStack {
                Circle().fill(Color.ruulSurface).frame(width: 72, height: 72)
                Image(systemName: "tray")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Color.ruulTextSecondary)
            }
            VStack(spacing: RuulSpacing.xs) {
                Text("Aún no hay movimientos")
                    .ruulTextStyle(RuulTypography.titleLarge)
                    .foregroundStyle(Color.ruulTextPrimary)
                Text("Toca + Gasto o + Aportación para registrar el primero.")
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, RuulSpacing.lg)
            }
            Spacer()
        }
    }

    // MARK: - Container helpers

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
                .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous)
                        .stroke(Color.ruulSeparator, lineWidth: 0.5)
                )
        }
    }

    private var divider: some View {
        Divider()
            .background(Color.ruulSeparator)
            .padding(.leading, 56)
    }

    // MARK: - Formatting

    private func decimal(_ cents: Int64) -> Decimal {
        Decimal(cents) / 100
    }

    private func amountText(_ cents: Int64) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = "MXN"
        nf.maximumFractionDigits = 0
        return nf.string(from: NSDecimalNumber(value: cents / 100)) ?? "$\(cents/100)"
    }
}
