import SwiftUI
import RuulCore

// MARK: - Money tab

/// R.10.E.3 (founder firmado 2026-06-14) — Money consolidation:
/// antes el body renderizaba 4 Sections separadas ("Mi saldo" /
/// "Obligaciones recientes" / "Liquidaciones" / "Ver historial") — cada una
/// pintada como su propia card iOS, 4 cards visuales para un mismo dominio.
/// Apple HIG: una Section agrupa contenido relacionado. Ahora **UNA Section
/// "Dinero"** con sub-rows semánticas:
///   - Saldo por currency (LabeledContent)
///   - Obligaciones pendientes (NavigationLink con count badge) → MoneyHomeView
///   - Liquidar saldos (NavigationLink warning tint, sólo si openSettlements > 0) → SettlementView
///   - Ver historial completo (NavigationLink) → MoneyHomeView
///
/// Empty state hero compacto preservado.
///
/// Doctrina: el detalle muestra info + drill-downs; las acciones rápidas
/// viven en el toolbar `+` Menu via descriptor.actions (R.10.E.2 D1).
struct ContextDetailV2MoneyTab: View {
    let descriptor: ContextDetailDescriptor
    let context: AppContext
    let container: DependencyContainer

    var body: some View {
        let d = descriptor
        let isEmpty = d.moneyPreview.myBalanceByCurrency.isEmpty
            && d.moneyPreview.openSettlements == 0
            && d.obligationsPreview.isEmpty

        if isEmpty {
            moneyEmptyHero
        } else {
            moneyConsolidatedSection(d)
        }

        // Fase 9.7 — "Dinero en subespacios" eliminada (redundante con
        // ChildrenSection global en `unifiedSections`).
    }

    @ViewBuilder
    private var moneyEmptyHero: some View {
        Section {
            VStack(spacing: 12) {
                Image(systemName: "dollarsign.circle")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(Theme.Tint.primary)
                Text("Aún no hay actividad de dinero")
                    .font(.headline)
                    .foregroundStyle(Theme.Text.primary)
                Text("Empezá registrando un gasto o asignando un compromiso. Las obligaciones, saldos y liquidaciones aparecerán acá.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.Text.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    /// R.10.E.3 — UNA sola Section con sub-rows semánticas.
    @ViewBuilder
    private func moneyConsolidatedSection(_ d: ContextDetailDescriptor) -> some View {
        let balances = d.moneyPreview.myBalanceByCurrency
        let pendingObligations = d.obligationsPreview.count
        let openSettlements = d.moneyPreview.openSettlements

        Section {
            // 1 row por currency.
            ForEach(balances.sorted(by: { $0.key < $1.key }), id: \.key) { (currency, net) in
                LabeledContent {
                    Text(net.compactCurrencyLabel(currency))
                        .font(.callout.bold().monospacedDigit())
                        .foregroundStyle(net >= 0 ? Theme.Tint.success : Theme.Tint.critical)
                } label: {
                    Label("Saldo en \(currency)", systemImage: net >= 0 ? "arrow.up.right.circle.fill" : "arrow.down.right.circle.fill")
                }
            }

            // Obligaciones pendientes (founder copy: "pendientes", no "recientes").
            if pendingObligations > 0 {
                NavigationLink {
                    MoneyHomeView(context: context, container: container)
                } label: {
                    HStack {
                        Label("Obligaciones pendientes", systemImage: "doc.text.fill")
                            .foregroundStyle(Theme.Text.primary)
                        Spacer()
                        Text("\(pendingObligations)")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(Theme.Text.secondary)
                    }
                }
            }

            // Liquidar saldos — CTA accionable (verbo + objeto) sólo cuando hay
            // settlements abiertos. Warning tint para destacar la acción.
            if openSettlements > 0 {
                NavigationLink {
                    SettlementView(context: context, container: container)
                } label: {
                    HStack {
                        Label("Liquidar saldos", systemImage: "creditcard.fill")
                            .foregroundStyle(Theme.Tint.warning)
                        Spacer()
                        Text("\(openSettlements) \(openSettlements == 1 ? "abierta" : "abiertas")")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Theme.Tint.warning)
                    }
                }
            }

            // R.10.E.6 (founder firmado 2026-06-15) — "Ver historial completo"
            // movido del body al header trailing como "Ver historial" (Apple
            // Music pattern, mismo que Eventos / Decisiones / Actividad /
            // Recursos). Section body sólo muestra data.
        } header: {
            HStack {
                Text("Dinero")
                Spacer()
                NavigationLink {
                    MoneyHomeView(context: context, container: container)
                } label: {
                    HStack(spacing: 2) {
                        Text("Ver historial")
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                    }
                    .foregroundStyle(Theme.Tint.primary)
                }
                .font(.subheadline.weight(.regular))
            }
            .textCase(nil)
        } footer: {
            if !balances.isEmpty {
                Text("Saldo positivo = te deben. Saldo negativo = debes.")
            }
        }
    }
}
