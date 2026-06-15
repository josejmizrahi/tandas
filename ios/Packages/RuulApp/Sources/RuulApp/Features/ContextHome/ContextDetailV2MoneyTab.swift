import SwiftUI
import RuulCore

// MARK: - Money tab

struct ContextDetailV2MoneyTab: View {
    let descriptor: ContextDetailDescriptor
    let context: AppContext
    let container: DependencyContainer

    var body: some View {
        let d = descriptor
        // R.10.E.2 D1 (founder firmado 2026-06-14) — eliminada la Section
        // "Acciones rápidas" del body (estaba renderizada DOS VECES y
        // duplicaba lo que el toolbar `+` ya expone via descriptor.actions
        // del section `money`). Doctrina ResourceDetail option B: el detalle
        // muestra info, el toolbar expone acciones.
        let isEmpty = d.moneyPreview.myBalanceByCurrency.isEmpty
            && d.moneyPreview.openSettlements == 0
            && d.obligationsPreview.isEmpty

        if isEmpty {
            moneyEmptyHero
        } else {
            if !d.moneyPreview.myBalanceByCurrency.isEmpty {
                moneyBalanceSection(d.moneyPreview.myBalanceByCurrency)
            }
            if !d.obligationsPreview.isEmpty {
                moneyObligationsSection(d.obligationsPreview)
            }
            if d.moneyPreview.openSettlements > 0 {
                moneySettlementsSection(openCount: d.moneyPreview.openSettlements)
            }
            moneyHistoryLinkSection
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

    @ViewBuilder
    private func moneyBalanceSection(_ balances: [String: Double]) -> some View {
        Section {
            ForEach(balances.sorted(by: { $0.key < $1.key }), id: \.key) { (currency, net) in
                LabeledContent {
                    Text(net.compactCurrencyLabel(currency))
                        .font(.callout.bold().monospacedDigit())
                        .foregroundStyle(net >= 0 ? Theme.Tint.success : Theme.Tint.critical)
                } label: {
                    Label(currency, systemImage: net >= 0 ? "arrow.up.right.circle.fill" : "arrow.down.right.circle.fill")
                }
            }
        } header: {
            Text("Mi saldo")
        } footer: {
            Text("Saldo positivo = te deben. Saldo negativo = debes.")
        }
    }

    @ViewBuilder
    private func moneyObligationsSection(_ obligations: [ContextObligationPreview]) -> some View {
        Section {
            ForEach(obligations) { o in
                NavigationLink {
                    ObligationDetailView(obligationId: o.obligationId, context: context, container: container)
                } label: {
                    Label {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(obligationKindLabel(o.kind))
                                    .font(.callout.weight(.medium))
                                    .foregroundStyle(Theme.Text.primary)
                                if let s = o.status {
                                    Text(obligationStatusLabel(s))
                                        .font(.caption)
                                        .foregroundStyle(Theme.Text.tertiary)
                                }
                            }
                            Spacer()
                            if let amount = o.amount, let cur = o.currency {
                                Text("\(Int(amount)) \(cur)")
                                    .font(.callout.bold().monospacedDigit())
                                    .foregroundStyle(Theme.Text.primary)
                            }
                        }
                    } icon: {
                        Image(systemName: obligationKindIcon(o.kind))
                            .foregroundStyle(Theme.Tint.primary)
                    }
                }
            }
        } header: {
            Text("Obligaciones recientes")
        }
    }

    @ViewBuilder
    private func moneySettlementsSection(openCount: Int) -> some View {
        Section {
            NavigationLink {
                SettlementView(context: context, container: container)
            } label: {
                Label {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Liquidar saldos")
                                .font(.callout.weight(.medium))
                                .foregroundStyle(Theme.Text.primary)
                            Text("\(openCount) \(openCount == 1 ? "liquidación abierta" : "liquidaciones abiertas")")
                                .font(.caption)
                                .foregroundStyle(Theme.Tint.warning)
                        }
                        Spacer()
                    }
                } icon: {
                    Image(systemName: "creditcard.fill")
                        .foregroundStyle(Theme.Tint.warning)
                }
            }
        } header: {
            Text("Liquidaciones")
        }
    }

    @ViewBuilder
    private var moneyHistoryLinkSection: some View {
        Section {
            NavigationLink {
                MoneyHomeView(context: context, container: container)
            } label: {
                Label("Ver historial completo", systemImage: "list.bullet.rectangle")
            }
        }
    }

    private func obligationKindIcon(_ kind: String?) -> String {
        switch kind {
        case "money":       return "dollarsign.circle.fill"
        case "action":      return "checklist"
        case "approval":    return "checkmark.seal.fill"
        case "delivery":    return "shippingbox.fill"
        case "attendance":  return "person.crop.circle.badge.checkmark.fill"
        case "document":    return "doc.text.fill"
        case "reservation": return "calendar.badge.clock"
        default:            return "doc.text.below.ecg.fill"
        }
    }

    private func obligationKindLabel(_ kind: String?) -> String {
        switch kind {
        case "money":       return "Dinero"
        case "action":      return "Acción"
        case "approval":    return "Aprobación"
        case "delivery":    return "Entrega"
        case "attendance":  return "Asistencia"
        case "document":    return "Documento"
        case "reservation": return "Reservación"
        default:            return "Compromiso"
        }
    }

    private func obligationStatusLabel(_ status: String) -> String {
        switch status {
        case "open":        return "Abierta"
        case "accepted":    return "Aceptada"
        case "in_progress": return "En progreso"
        case "completed":   return "Cumplida"
        case "settled":     return "Liquidada"
        case "cancelled":   return "Cancelada"
        case "expired":     return "Vencida"
        default:            return status.capitalized
        }
    }
}
