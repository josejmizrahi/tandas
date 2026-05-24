import SwiftUI
import RuulUI
import RuulCore

/// SharedMoney P3: "Balances" subscreen — full list of every member's
/// net position in the group, pushed from `GroupObligationsCard`'s tap.
///
/// Each row shows the member's display name + their `netCents`. Sorted
/// by absolute net descending so the largest debtors/creditors lead.
/// Current viewer's row is labeled "Tú" (consistent with the Money
/// Block's per-member breakdown convention).
///
/// V1 simple — no pairwise "X le debe a Y" breakdown. The view's net
/// per member is the canonical answer; Splitwise-style settlement
/// routing is a future brick.
@MainActor
public struct GroupBalancesView: View {
    public let group: RuulCore.Group

    @Environment(AppState.self) private var app

    @State private var members: [MemberWithProfile] = []
    @State private var balances: [MemberGroupBalance] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var hasLoaded = false

    public init(group: RuulCore.Group) {
        self.group = group
    }

    private var phase: LoadPhase<[MemberGroupBalance]> {
        let coordError: CoordinatorError? = errorMessage.map {
            CoordinatorError(title: "No pudimos cargar los balances", message: $0, isRetryable: true)
        }
        return LoadPhase.fromCollection(
            value: visibleRows,
            hasLoaded: hasLoaded,
            isLoading: isLoading,
            error: coordError
        )
    }

    /// Hide settled rows (netCents == 0) — no noise on the steady state.
    /// Sort by abs(netCents) desc: largest debts / credits lead.
    private var visibleRows: [MemberGroupBalance] {
        balances
            .filter { $0.currency == group.currency && !$0.isSettled }
            .sorted { abs($0.netCents) > abs($1.netCents) }
    }

    public var body: some View {
        AsyncContentView(
            phase: phase,
            onRetry: { await load() },
            empty: {
                ContentUnavailableView {
                    Label("Todos están al día", systemImage: "checkmark.circle")
                } description: {
                    Text("Nadie tiene una posición pendiente con el grupo en \(group.currency).")
                }
            },
            loaded: { rows in
                ScrollView {
                    LazyVStack(spacing: RuulSpacing.sm) {
                        ForEach(rows) { row in
                            balanceRow(row)
                        }
                    }
                    .padding(RuulSpacing.lg)
                }
                .refreshable { await load() }
            }
        )
        .background(Color.ruulBackgroundRecessed.ignoresSafeArea())
        .navigationTitle("Balances del grupo")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func balanceRow(_ row: MemberGroupBalance) -> some View {
        let isMe = (row.memberId == myMemberId)
        let name = isMe ? "Tú" : (memberName(for: row.memberId) ?? "Miembro")
        let amount = Decimal(abs(row.netCents)) / 100
        return HStack(spacing: RuulSpacing.md) {
            Image(systemName: row.isOwed ? "arrow.down.left.circle.fill" : "arrow.up.right.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(row.isOwed ? Color.ruulPositive : Color.ruulNegative)
                .frame(width: 36, height: 36)
                .background(
                    (row.isOwed ? Color.ruulPositive : Color.ruulNegative).opacity(0.12),
                    in: Circle()
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                Text(row.isOwed ? "Le deben" : "Debe al grupo")
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
            }

            Spacer(minLength: 0)

            RuulMoneyView(
                amount: amount,
                currency: row.currency,
                size: .medium,
                color: row.isOwed ? .positive : .negative
            )
        }
        .padding(RuulSpacing.md)
        .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.lg)
                .stroke(Color(.separator), lineWidth: 0.5)
        )
    }

    private var myMemberId: UUID? {
        guard let userId = app.session?.user.id else { return nil }
        return members.first(where: { $0.member.userId == userId })?.member.id
    }

    private func memberName(for memberId: UUID) -> String? {
        members.first(where: { $0.member.id == memberId })?.displayName
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer {
            isLoading = false
            hasLoaded = true
        }
        // Load members + balances in parallel. Members are
        // best-effort: if it fails, the rows still render with the
        // "Miembro" fallback label.
        async let membersTask = (try? await app.groupsRepo.membersWithProfiles(of: group.id)) ?? []
        async let balancesTask = app.ledgerRepo.balancesForGroup(group.id)
        do {
            members = await membersTask
            balances = try await balancesTask
        } catch {
            errorMessage = "No pudimos cargar los balances."
        }
    }
}
