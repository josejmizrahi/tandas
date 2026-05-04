import SwiftUI

/// Member-facing fine list. Two sections — outstanding (proposed,
/// officialized, in-appeal) and resolved (paid, voided). Tapping a card
/// pushes FineDetailView. Pull-to-refresh re-runs the query (RLS gives us
/// only this user's fines automatically).
struct MyFinesView: View {
    @Bindable var coordinator: MyFinesCoordinator
    let onOpenFine: (Fine) -> Void

    var body: some View {
        ZStack {
            Color.ruulBackgroundCanvas.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: RuulSpacing.s7) {
                    header
                    pendingSection
                    resolvedSection
                }
                .padding(.horizontal, RuulSpacing.s5)
                .padding(.top, RuulSpacing.s2)
                .padding(.bottom, RuulSpacing.s12)
            }
            .scrollIndicators(.hidden)
            .refreshable { await coordinator.refresh() }
        }
        .task { await coordinator.refresh() }
        .navigationTitle("Mis multas")
        .navigationBarTitleDisplayMode(.large)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.s2) {
            Text("PENDIENTE DE PAGO")
                .ruulTextStyle(RuulTypography.sectionLabel)
                .foregroundStyle(Color.ruulTextTertiary)
            Text(amountFormatted(coordinator.totalOutstanding))
                .ruulTextStyle(RuulTypography.displayLarge)
                .foregroundStyle(Color.ruulTextPrimary)
        }
        .padding(.top, RuulSpacing.s4)
    }

    @ViewBuilder
    private var pendingSection: some View {
        if !coordinator.pending.isEmpty {
            section(title: "POR RESOLVER", count: coordinator.pending.count) {
                ForEach(coordinator.pending) { fine in
                    FineCard(fine: fine, ruleName: nil, eventTitle: nil) {
                        onOpenFine(fine)
                    }
                }
            }
        } else if !coordinator.isLoading && coordinator.fines.isEmpty {
            EmptyStateView(
                systemImage: "checkmark.circle.fill",
                title: "Sin multas",
                message: "No tienes multas en este momento. Sigue así."
            )
            .padding(.top, RuulSpacing.s5)
        }
    }

    @ViewBuilder
    private var resolvedSection: some View {
        if !coordinator.resolved.isEmpty {
            section(title: "HISTORIAL", count: coordinator.resolved.count) {
                ForEach(coordinator.resolved) { fine in
                    FineCard(fine: fine, ruleName: nil, eventTitle: nil) {
                        onOpenFine(fine)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func section<Content: View>(title: String, count: Int, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: RuulSpacing.s4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .ruulTextStyle(RuulTypography.sectionLabel)
                    .foregroundStyle(Color.ruulTextTertiary)
                Spacer()
                Text("\(count)")
                    .ruulTextStyle(RuulTypography.statSmall)
                    .foregroundStyle(Color.ruulTextTertiary)
            }
            VStack(spacing: RuulSpacing.s3) { content() }
        }
    }

    private func amountFormatted(_ amount: Decimal) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = "MXN"
        nf.maximumFractionDigits = 0
        return nf.string(from: amount as NSDecimalNumber) ?? "$\(amount)"
    }
}
