import SwiftUI
import RuulCore

// MARK: - Hoy (R.11.A — top zone widgets, founder firmado 2026-06-16)
//
// Section "Hoy" muestra los 2 widgets más urgentes del contexto lado a lado:
//
//   ┌──────────────┐  ┌──────────────┐
//   │ Próximo evt  │  │ Mi saldo     │
//   │ Hoy 8:00 pm  │  │ +$1,250 MXN  │
//   │ Cena familia │  │ 2 liquid.    │
//   └──────────────┘  └──────────────┘
//
// Reemplaza el filtrado de `next_event` + `cash_balance` del Dashboard
// (que post-Fase 9.6 los ocultaba sin reemplazo). Doctrina R.11.A: el
// top zone tiene densidad visual mientras el resto sigue siendo lista
// scrollable Apple Music style.
//
// Reglas:
//  - Si NO hay próximo evento Y `myBalanceByCurrency` está vacío → Section oculta.
//  - Si sólo hay uno → card full-width.
//  - Si ambos → side-by-side con GlassEffectContainer (mismo morphing que carrusel children).
//
// Tap en cada card pushea a su list view (Events / Money).

struct ContextDetailV2TodaySection: View {
    let descriptor: ContextDetailDescriptor
    let context: AppContext
    let container: DependencyContainer

    var body: some View {
        let event = descriptor.eventsPreview.first
        let balance = primaryBalance(descriptor.moneyPreview)
        let hasContent = event != nil || balance != nil
        if hasContent {
            Section {
                GlassEffectContainer(spacing: 12) {
                    HStack(spacing: 12) {
                        if let event {
                            NavigationLink {
                                EventDetailView(eventId: event.eventId, context: context, container: container)
                            } label: {
                                nextEventCard(event)
                            }
                            .buttonStyle(.plain)
                        }
                        if let balance {
                            NavigationLink {
                                MoneyHomeView(context: context, container: container)
                            } label: {
                                balanceCard(
                                    amount: balance.amount,
                                    currency: balance.currency,
                                    openSettlements: descriptor.moneyPreview.openSettlements
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } header: {
                Text("Hoy")
            }
        }
    }

    // MARK: - Cards

    @ViewBuilder
    private func nextEventCard(_ event: ContextEventPreview) -> some View {
        let when = eventDateLabel(event.startsAt)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(when.tint)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.Text.tertiary)
            }
            Spacer(minLength: 0)
            Text(when.label)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(when.tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(event.title)
                .font(.caption)
                .foregroundStyle(Theme.Text.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
        .padding(14)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 14))
    }

    @ViewBuilder
    private func balanceCard(amount: Double, currency: String, openSettlements: Int) -> some View {
        let tint: Color = amount >= 0 ? Theme.Tint.success : Theme.Tint.critical
        let symbol = amount >= 0 ? "arrow.up.right.circle.fill" : "arrow.down.right.circle.fill"
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(tint)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.Text.tertiary)
            }
            Spacer(minLength: 0)
            Text(amount.compactCurrencyLabel(currency))
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if openSettlements > 0 {
                Text("\(openSettlements) \(openSettlements == 1 ? "liquidación" : "liquidaciones")")
                    .font(.caption)
                    .foregroundStyle(Theme.Tint.warning)
            } else {
                Text("Mi saldo en \(currency)")
                    .font(.caption)
                    .foregroundStyle(Theme.Text.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
        .padding(14)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 14))
    }

    // MARK: - Helpers

    /// Returns the dominant currency entry (first non-zero, or fallback to first).
    /// `myBalanceByCurrency` is a dict so we pick the most actionable entry.
    private func primaryBalance(_ preview: ContextMoneyPreview) -> (amount: Double, currency: String)? {
        guard !preview.myBalanceByCurrency.isEmpty else { return nil }
        if let nonZero = preview.myBalanceByCurrency.first(where: { $0.value != 0 }) {
            return (nonZero.value, nonZero.key)
        }
        if let any = preview.myBalanceByCurrency.first {
            return (any.value, any.key)
        }
        return nil
    }

    private func eventDateLabel(_ date: Date?) -> (label: String, tint: Color) {
        guard let date else { return ("Próximo", Theme.Tint.primary) }
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            return (date.formatted(.dateTime.hour().minute()), Theme.Tint.warning)
        }
        if cal.isDateInTomorrow(date) {
            return ("Mañana", Theme.Tint.warning)
        }
        let days = cal.dateComponents([.day], from: Date(), to: date).day ?? 0
        if days < 7 && days > 0 {
            return (date.formatted(.dateTime.weekday(.wide)).capitalized, Theme.Tint.primary)
        }
        return (date.formatted(.dateTime.day().month(.abbreviated)), Theme.Tint.primary)
    }
}
