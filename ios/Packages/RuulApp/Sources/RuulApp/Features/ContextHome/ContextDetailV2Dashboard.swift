import SwiftUI
import RuulCore

// MARK: - Dashboard (widgets)

struct ContextDetailV2DashboardSection: View {
    let widgets: [ContextWidget]
    let descriptor: ContextDetailDescriptor
    let context: AppContext
    let container: DependencyContainer

    var body: some View {
        // R.17 — filas planas nativas dentro de la Section ("Section is the
        // card"). Antes: carousel horizontal de tiles con Liquid Glass.
        Section {
            ForEach(widgets) { widget in
                contextWidgetRow(widget)
            }
        } header: {
            Text("Dashboard")
        }
    }

    @ViewBuilder
    private func contextWidgetRow(_ widget: ContextWidget) -> some View {
        if contextWidgetDestinationKey(widget.widgetKey) != nil {
            NavigationLink {
                contextWidgetDestination(widgetKey: widget.widgetKey)
            } label: {
                contextWidgetRowLabel(widget)
            }
        } else {
            contextWidgetRowLabel(widget)
        }
    }

    /// 2026-06-09 — headline computado por widget key consumiendo metrics +
    /// previews del descriptor. Antes el card era plástico (icon + título
    /// solamente). Si no hay data para ese widget, retorna nil y cae al
    /// layout plástico anterior.
    private func contextWidgetHeadline(_ widget: ContextWidget) -> (value: String, tint: Color)? {
        let d = descriptor
        switch widget.widgetKey {
        case "cash_balance":
            // Prefer my net balance del caller; sumando currencies (ya con signo).
            let sum = d.moneyPreview.myBalanceByCurrency.values.reduce(0, +)
            if sum != 0, let currency = d.moneyPreview.myBalanceByCurrency.keys.first {
                let tint: Color = sum >= 0 ? Theme.Tint.success : Theme.Tint.critical
                return (sum.compactCurrencyLabel(currency), tint)
            }
        case "open_obligations":
            if d.metrics.openObligations > 0 {
                return ("\(d.metrics.openObligations)", Theme.Tint.warning)
            }
        case "open_decisions":
            if d.metrics.pendingDecisions > 0 {
                return ("\(d.metrics.pendingDecisions)", .purple)
            }
        case "member_count_summary":
            if d.metrics.memberCount > 0 {
                return ("\(d.metrics.memberCount)", Theme.Tint.info)
            }
        case "critical_resources":
            let total = d.metrics.resourceCountByClass.values.reduce(0, +)
            if total > 0 {
                return ("\(total)", Theme.Tint.warning)
            }
        case "recent_activity":
            if d.activityPreview.count > 0 {
                return ("\(d.activityPreview.count)", Theme.Tint.info)
            }
        case "next_event":
            if let first = d.eventsPreview.first, let date = first.startsAt {
                if Calendar.current.isDateInToday(date) { return ("Hoy", Theme.Tint.warning) }
                if Calendar.current.isDateInTomorrow(date) { return ("Mañana", Theme.Tint.warning) }
                return (date.formatted(.dateTime.day().month(.abbreviated)), Theme.Tint.primary)
            }
        case "settlement_status":
            if d.moneyPreview.openSettlements > 0 {
                return ("\(d.moneyPreview.openSettlements)", Theme.Tint.warning)
            }
        default:
            break
        }
        return nil
    }

    @ViewBuilder
    private func contextWidgetRowLabel(_ widget: ContextWidget) -> some View {
        let headline = contextWidgetHeadline(widget)
        LabeledContent {
            if let headline {
                Text(headline.value)
                    .font(.callout.weight(.semibold).monospacedDigit())
                    .foregroundStyle(headline.tint)
                    .lineLimit(1)
            }
        } label: {
            Label {
                Text(widget.displayName)
                    .foregroundStyle(Theme.Text.primary)
                    .lineLimit(2)
            } icon: {
                Image(systemName: widget.icon ?? "rectangle.stack")
                    .foregroundStyle(headline?.tint ?? Theme.Tint.primary)
            }
        }
    }

    private func contextWidgetDestinationKey(_ key: String) -> String? {
        switch key {
        case "cash_balance", "budget_progress", "open_obligations":
            return "money"
        case "critical_resources":   return "resources"
        case "member_count_summary": return "members"
        case "next_event":           return "events"
        case "open_decisions":       return "decisions"
        case "recent_activity":      return "activity"
        case "settlement_status":    return "settlement"
        case "upcoming_reservations": return "reservations"
        default:                     return nil
        }
    }

    @ViewBuilder
    private func contextWidgetDestination(widgetKey: String) -> some View {
        switch contextWidgetDestinationKey(widgetKey) {
        case "money":        MoneyHomeView(context: context, container: container)
        case "resources":    ResourcesListView(context: context, container: container)
        case "members":      MembersListView(context: context, container: container)
        case "events":       EventsListView(context: context, container: container)
        case "decisions":    DecisionsListView(context: context, container: container)
        case "activity":     ActivityFeedView(context: context, container: container)
        case "settlement":   SettlementView(context: context, container: container)
        case "reservations": ContextReservationsView(context: context, container: container)
        default:             EmptyView()
        }
    }
}
