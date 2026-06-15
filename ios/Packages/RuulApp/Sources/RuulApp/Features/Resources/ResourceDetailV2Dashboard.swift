import SwiftUI
import RuulCore

/// R.10.A — Dashboard widgets section (code move, zero behavior change).
///
/// Doctrina: R.5V native-first · "Section is the card".
/// Movido del monolito previo (677–831).

struct ResourceDetailV2DashboardSection: View {
    let widgets: [ResourceWidget]
    let descriptor: ResourceDetailDescriptor
    let context: AppContext
    let container: DependencyContainer

    var body: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                // R.5V.Glass.C2 founder feedback — mismo glass que childrenSection.
                GlassEffectContainer(spacing: 12) {
                    HStack(spacing: 12) {
                        ForEach(widgets) { widget in
                            widgetCard(widget)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        } header: {
            Text("Dashboard")
        }
    }

    @ViewBuilder
    private func widgetCard(_ widget: ResourceWidget) -> some View {
        if ResourceDetailV2DashboardRouter.destinationKey(widget.widgetKey) != nil {
            NavigationLink {
                ResourceDetailV2DashboardRouter.destination(
                    widgetKey: widget.widgetKey,
                    descriptor: descriptor,
                    context: context,
                    container: container
                )
            } label: {
                widgetCardBody(widget, tappable: true)
            }
            .buttonStyle(.plain)
        } else {
            widgetCardBody(widget, tappable: false)
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
    private func widgetCardBody(_ widget: ResourceWidget, tappable: Bool) -> some View {
        let headline = widgetHeadline(widget)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Image(systemName: widget.icon ?? "rectangle.stack")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(headline?.tint ?? Theme.Tint.primary)
                Spacer()
                if tappable {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.Text.tertiary)
                }
            }
            Spacer(minLength: 0)
            if let headline {
                Text(headline.value)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(headline.tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(widget.displayName)
                    .font(.caption)
                    .foregroundStyle(Theme.Text.secondary)
                    .lineLimit(2)
            } else {
                Text(widget.displayName)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Theme.Text.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
        }
        .frame(width: 150, height: 130, alignment: .topLeading)
        .padding(14)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 14))
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
