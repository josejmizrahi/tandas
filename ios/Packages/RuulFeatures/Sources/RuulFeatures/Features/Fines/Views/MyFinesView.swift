import SwiftUI
import RuulUI
import RuulCore

/// Member-facing fine list. Two sections — outstanding (proposed,
/// officialized, in-appeal) and resolved (paid, voided). Tapping a card
/// pushes FineDetailView. Pull-to-refresh re-runs the query (RLS gives us
/// only this user's fines automatically).
public struct MyFinesView: View {
    @Environment(AppState.self) private var app
    @Bindable var coordinator: MyFinesCoordinator
    public let onOpenFine: (Fine) -> Void

    /// Time scope filter. Default `.all` para no esconder data; "Este mes"
    /// resulta natural para tracking de gasto mensual recurrente.
    @State private var scope: FineScope = .all

    enum FineScope: String, CaseIterable, Identifiable {
        case all      = "Todo"
        case thisMonth = "Este mes"
        var id: String { rawValue }
        var label: String { rawValue }

        func includes(_ fine: Fine, now: Date = .now) -> Bool {
            switch self {
            case .all: return true
            case .thisMonth:
                let cal = Calendar.current
                let monthStart = cal.dateInterval(of: .month, for: now)?.start ?? now
                return fine.createdAt >= monthStart
            }
        }
    }

    public init(coordinator: MyFinesCoordinator, onOpenFine: @escaping (Fine) -> Void) {
        self.coordinator = coordinator
        self.onOpenFine = onOpenFine
    }

    public var body: some View {
        ZStack {
            Color.ruulBackgroundCanvas.ignoresSafeArea()
            SwiftUI.Group {
                if let error = coordinator.error, coordinator.fines.isEmpty {
                    ErrorStateView(error: error, retry: { Task { await coordinator.refresh() } })
                        .padding(.horizontal, RuulSpacing.lg)
                        .padding(.top, RuulSpacing.lg)
                        .transition(.opacity)
                } else if coordinator.fines.isEmpty && coordinator.isLoading {
                    RuulLoadingState()
                        .transition(.opacity)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: RuulSpacing.xxl) {
                            header
                            scopeChips
                            pendingSection
                            resolvedSection
                        }
                        .padding(.horizontal, RuulSpacing.lg)
                        .padding(.top, RuulSpacing.xs)
                        .padding(.bottom, RuulSpacing.s12)
                    }
                    .scrollIndicators(.hidden)
                    .refreshable { await coordinator.refresh() }
                    .transition(.opacity)
                }
            }
            .animation(.linear(duration: RuulDuration.fast), value: coordinator.error)
            .animation(.linear(duration: RuulDuration.fast), value: coordinator.isLoading)
            .animation(.linear(duration: RuulDuration.fast), value: coordinator.fines.isEmpty)
        }
        .task { await coordinator.refresh() }
        .navigationTitle("Mis multas")
        .navigationBarTitleDisplayMode(.large)
    }

    /// Hero del header. Cuando `totalOutstanding == 0` la vista bascula a
    /// un "todo al corriente" celebratorio (Luma-style) en vez de mostrar
    /// "$0 pendiente", que se leía como "no entendemos qué quieres ver".
    /// Diferenciamos visualmente "nunca tuviste multas" (sin historial) de
    /// "pagaste todas" (con historial) cambiando el copy del subtítulo.
    @ViewBuilder
    private var header: some View {
        if coordinator.totalOutstanding > 0 {
            VStack(alignment: .leading, spacing: RuulSpacing.xs) {
                Text("PENDIENTE DE PAGO")
                    .ruulTextStyle(RuulTypography.sectionLabel)
                    .foregroundStyle(Color.ruulTextTertiary)
                RuulMoneyView(
                    amount: coordinator.totalOutstanding,
                    currency: "MXN",
                    size: .large,
                    color: .negative
                )
            }
            .padding(.top, RuulSpacing.md)
        } else {
            allClearHero
        }
    }

    private var allClearHero: some View {
        HStack(alignment: .center, spacing: RuulSpacing.md) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(Color.ruulPositive)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Todo al corriente")
                    .ruulTextStyle(RuulTypography.title)
                    .foregroundStyle(Color.ruulTextPrimary)
                Text(coordinator.resolved.isEmpty
                    ? "No tienes multas pendientes."
                    : "Pagaste todas tus multas.")
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, RuulSpacing.md)
        .accessibilityElement(children: .combine)
    }

    /// Time scope filter chips. Solo renderiza si hay fines visibles —
    /// para empty state no agrega ruido. Layout: HStack horizontal de
    /// pills compactos (Apple Sports pattern).
    @ViewBuilder
    private var scopeChips: some View {
        if !coordinator.fines.isEmpty {
            HStack(spacing: RuulSpacing.xs) {
                ForEach(FineScope.allCases) { s in
                    scopeChip(s)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func scopeChip(_ s: FineScope) -> some View {
        Button {
            withAnimation(.ruulSnappy) { scope = s }
        } label: {
            Text(s.label)
                .ruulTextStyle(RuulTypography.callout)
                .padding(.horizontal, RuulSpacing.md)
                .padding(.vertical, RuulSpacing.xs)
                .background(
                    Capsule()
                        .fill(scope == s ? Color.ruulAccent : Color.ruulSurface)
                )
                .foregroundStyle(scope == s ? Color.ruulTextInverse : Color.ruulTextSecondary)
                .overlay(
                    Capsule()
                        .stroke(scope == s ? Color.clear : Color.ruulSeparator, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private var filteredPending: [Fine] {
        coordinator.pending.filter { scope.includes($0) }
    }

    private var filteredResolved: [Fine] {
        coordinator.resolved.filter { scope.includes($0) }
    }

    @ViewBuilder
    private var pendingSection: some View {
        if !filteredPending.isEmpty {
            section(title: "POR RESOLVER", count: filteredPending.count) {
                RuulSeparatedRows(items: filteredPending) { fine in
                    FineCard(
                        fine: fine,
                        ruleName: nil,
                        eventTitle: nil,
                        groupName: coordinator.groupsById.count > 1 ? coordinator.groupName(for: fine) : nil
                    ) {
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
            .padding(.top, RuulSpacing.lg)
        } else if !coordinator.isLoading && filteredPending.isEmpty && scope != .all {
            // Filtered to empty subset: distinct from "sin multas
            // totales". Mantiene scopeChips visible para volver.
            Text("Sin multas en este periodo.")
                .ruulTextStyle(RuulTypography.callout)
                .foregroundStyle(Color.ruulTextTertiary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, RuulSpacing.lg)
        }
    }

    @ViewBuilder
    private var resolvedSection: some View {
        if !filteredResolved.isEmpty {
            section(title: "HISTORIAL", count: filteredResolved.count) {
                // Compact rows: el historial no necesita el chrome del
                // pending card (status + divider + monto grande). Sólo
                // nombre + grupo (si cross-group) + monto pequeño.
                RuulSeparatedRows(items: filteredResolved) { fine in
                    FineCard(
                        fine: fine,
                        ruleName: nil,
                        eventTitle: nil,
                        groupName: coordinator.groupsById.count > 1 ? coordinator.groupName(for: fine) : nil,
                        compact: true
                    ) {
                        onOpenFine(fine)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func section<Content: View>(title: String, count: Int, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: RuulSpacing.md) {
            RuulListSectionHeader(title, count: count)
            VStack(spacing: RuulSpacing.sm) { content() }
        }
    }

}
