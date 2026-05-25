import SwiftUI
import RuulUI
import RuulCore

/// Stream situacional del GroupSpace en orden canónico
/// (doctrine_group_space_situational, 2026-05-24). Cada cluster
/// auto-oculta cuando su data está vacía — si TODOS están vacíos,
/// el parent debe montar `EmptyGroupHero` en su lugar.
///
/// Orden fijo:
///   1. Necesita atención
///   2. Próximo (PR-1: event-only)
///   3. Dinero reciente (con compose `+` contextual)
///   4. En uso (asset custody + space occupancy; slot deferred)
///   5. Acabó de pasar
@MainActor
struct GroupClusterStream: View {
    let attention: [UserAction]
    let upcoming: [Event]
    let recentMoney: [LedgerEntry]
    let inUse: [InUseProjection]
    let recentActivity: [SystemEvent]

    let locale: String
    let members: [MemberWithProfile]
    let currency: String

    let onSelectPending: (UserAction) -> Void
    let onOpenEvent: (Event) -> Void
    let onOpenInUseResource: (UUID) -> Void
    var onSeeAllActivity: (() -> Void)?
    var onSeeAllMoney: (() -> Void)?
    var onSeeAllUpcoming: (() -> Void)?
    let onRegisterExpense: () -> Void
    let onContribute: () -> Void
    let onSettle: () -> Void

    var body: some View {
        LazyVStack(alignment: .leading, spacing: RuulSpacing.xl) {
            if !attention.isEmpty {
                AttentionCluster(items: attention, onSelect: onSelectPending)
            }
            if !upcoming.isEmpty {
                UpcomingCluster(
                    events: upcoming,
                    onOpenEvent: onOpenEvent,
                    onSeeAll: onSeeAllUpcoming
                )
            }
            if !recentMoney.isEmpty {
                RecentMoneyCluster(
                    entries: recentMoney,
                    members: members,
                    currency: currency,
                    locale: locale,
                    onRegisterExpense: onRegisterExpense,
                    onContribute: onContribute,
                    onSettle: onSettle,
                    onSeeAll: onSeeAllMoney
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
