import SwiftUI
import RuulCore

/// R.10.A — Dashboard widgets section (movido del monolito previo 677–831).
///
/// Doctrina: R.5V native-first · "Section is the card".
/// R.17 — tiles glass → filas planas nativas (LabeledContent) en la Section.

struct ResourceDetailV2DashboardSection: View {
    let widgets: [ResourceWidget]
    let descriptor: ResourceDetailDescriptor
    let context: AppContext
    let container: DependencyContainer

    var body: some View {
        // R.17 — filas planas nativas dentro de la Section ("Section is the
        // card"). Antes: carousel horizontal de tiles con Liquid Glass.
        Section {
            ForEach(widgets) { widget in
                widgetRow(widget)
            }
        } header: {
            Text("Dashboard")
        }
    }

    @ViewBuilder
    private func widgetRow(_ widget: ResourceWidget) -> some View {
        if ResourceDetailV2DashboardRouter.destinationKey(widget.widgetKey) != nil {
            NavigationLink {
                ResourceDetailV2DashboardRouter.destination(
                    widgetKey: widget.widgetKey,
                    descriptor: descriptor,
                    context: context,
                    container: container
                )
            } label: {
                widgetRowLabel(widget)
            }
        } else {
            widgetRowLabel(widget)
        }
    }

    /// Headline computado por widget key. Consume metrics + linked collections
    /// que ya vienen en el descriptor — sin RPC adicional.
    private func widgetHeadline(_ widget: ResourceWidget) -> (value: String, tint: Color)? {
        let d = descriptor
        switch widget.widgetKey {
        case "balance_summary", "member_balance_summary":
            if let balance = d.metrics.balance, let currency = d.metrics.currency {
                return (balance.compactCurrencyLabel(currency), Theme.Tint.success)
            }
        case "open_obligations":
            let count = d.linkedObligations.count
            if count > 0 {
                return ("\(count)", Theme.Tint.warning)
            }
        case "recent_activity":
            let count = d.activityPreview.count
            if count > 0 {
                return ("\(count)", Theme.Tint.info)
            }
        case "next_event":
            if let first = d.linkedEvents.first,
               case .object(let obj) = first,
               case .string(let s)? = obj["starts_at"],
               let date = ISO8601DateFormatter().date(from: s) {
                let isToday = Calendar.current.isDateInToday(date)
                let isTomorrow = Calendar.current.isDateInTomorrow(date)
                if isToday { return ("Hoy", Theme.Tint.warning) }
                if isTomorrow { return ("Mañana", Theme.Tint.warning) }
                return (date.formatted(.dateTime.day().month(.abbreviated)), Theme.Tint.primary)
            }
        case "income_summary":
            if let value = d.metrics.estimatedValue, let currency = d.metrics.currency {
                return (value.compactCurrencyLabel(currency), Theme.Tint.success)
            }
        default:
            break
        }
        return nil
    }

    @ViewBuilder
    private func widgetRowLabel(_ widget: ResourceWidget) -> some View {
        let headline = widgetHeadline(widget)
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
}

/// Router de widget key → destino navegable.
enum ResourceDetailV2DashboardRouter {
    static func destinationKey(_ key: String) -> String? {
        switch key {
        case "balance_summary", "member_balance_summary", "income_summary",
             "lease_status", "open_obligations":
            return "money"
        case "next_event":                                  return "events"
        case "recent_activity":                             return "activity"
        case "reservation_status", "upcoming_reservations": return "reservations"
        case "settlement_status":                           return "settlement"
        default:                                            return nil
        }
    }

    @MainActor
    @ViewBuilder
    static func destination(
        widgetKey: String,
        descriptor: ResourceDetailDescriptor,
        context: AppContext,
        container: DependencyContainer
    ) -> some View {
        switch destinationKey(widgetKey) {
        case "money":
            MoneyHomeView(context: context, container: container)
        case "events":
            EventsListView(context: context, container: container)
        case "activity":
            ActivityFeedView(context: context, container: container)
        case "reservations":
            ReservationsListView(
                resource: descriptor.resource,
                context: context,
                reservationContextId: nil,
                container: container
            )
        case "settlement":
            SettlementView(context: context, container: container)
        default:
            EmptyView()
        }
    }
}
