import SwiftUI
import RuulUI
import RuulCore

/// Stream situacional del GroupSpace en orden canónico
/// (doctrine_group_space_situational, 2026-05-24 → 2026-05-25 reframe).
/// Cada cluster auto-oculta cuando su data está vacía — si TODOS están
/// vacíos, el parent debe montar `EmptyGroupHero` en su lugar.
///
/// Orden fijo:
///   1. Necesita atención
///   2. Próximo (events + votes + slots)
///   3. Deudas (founder reframe 2026-05-25: dyadic pendientes, no
///      historial; recent money queda en GroupBalancesView +
///      JustHappenedCluster + MyMovementsView)
///   4. En uso (asset custody + space occupancy; slot deferred)
///   5. Acabó de pasar (incluye money happenings via system_events)
@MainActor
struct GroupClusterStream: View {
    let attention: [UserAction]
    /// 2026-05-25: polimorphic Próximo. Items can be events, closing
    /// votes, or slot rotations. Adding new cases doesn't touch this
    /// component — only `UpcomingCluster` row rendering.
    let upcoming: [UpcomingItem]
    /// 2026-05-25 reframe: greedy settlement pairs involving the viewer.
    /// Empty → cluster #3 hides entirely. Historical money entries live
    /// elsewhere (GroupBalancesView, JustHappenedCluster, MyMovements).
    let pendingDebts: [PendingSettlementHint]
    let inUse: [InUseProjection]
    let recentActivity: [SystemEvent]

    let locale: String
    let members: [MemberWithProfile]
    let currency: String

    let onSelectPending: (UserAction) -> Void
    let onOpenEvent: (Event) -> Void
    let onOpenVote: (Vote) -> Void
    let onOpenSlot: (Slot) -> Void
    let onOpenInUseResource: (UUID) -> Void
    var onSeeAllActivity: (() -> Void)?
    var onSeeAllMoney: (() -> Void)?
    var onSeeAllUpcoming: (() -> Void)?
    let onRegisterExpense: () -> Void
    let onContribute: () -> Void
    let onSettle: () -> Void
    /// FASE 4 Wave 4 Phase 3 Tier 2: pool→member payout (dividendos /
    /// retornos / stipends). Nil → option hidden in compose menus.
    var onPayout: (() -> Void)?
    /// Phase 4.4 (2026-05-26): open the "cobrar cuota al grupo" sheet
    /// — poker buy-in, tanda, cuota mensual. Nil → option hidden.
    var onPoolCharge: (() -> Void)?
    /// Open the SettlementSheet pre-filled with this dyadic pair.
    var onTapDebt: ((PendingSettlementHint) -> Void)?

    var body: some View {
        LazyVStack(alignment: .leading, spacing: RuulSpacing.xl) {
            if !attention.isEmpty {
                AttentionCluster(items: attention, onSelect: onSelectPending)
            }
            if !upcoming.isEmpty {
                UpcomingCluster(
                    items: upcoming,
                    onOpenEvent: onOpenEvent,
                    onOpenVote: onOpenVote,
                    onOpenSlot: onOpenSlot,
                    onSeeAll: onSeeAllUpcoming
                )
            }
            if !pendingDebts.isEmpty {
                DebtsCluster(
                    debts: pendingDebts,
                    locale: locale,
                    onRegisterExpense: onRegisterExpense,
                    onContribute: onContribute,
                    onSettle: onSettle,
                    onPoolCharge: onPoolCharge,
                    onSeeAll: onSeeAllMoney,
                    onTapDebt: onTapDebt,
                    onPayout: onPayout
                )
            }
            if !inUse.isEmpty {
                InUseCluster(
                    items: inUse,
                    members: members,
                    locale: locale,
                    onOpenResource: onOpenInUseResource
                )
            }
            if !recentActivity.isEmpty {
                JustHappenedCluster(
                    events: recentActivity,
                    members: members,
                    onSeeAll: onSeeAllActivity
                )
            }
        }
    }
}
