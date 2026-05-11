import SwiftUI
import RuulUI
import RuulCore

/// Edit-mode counterpart to RulesView. Reachable via the conditional
/// pencil button in RulesView nav (visible iff governance.canPerform(
/// .modifyRules) == .allowed for the current actor).
public struct EditRulesView: View {
    @Bindable var coordinator: EditRulesCoordinator
    @State private var sheetRule: GroupRule?

    public var body: some View {
        ZStack {
            Color.ruulBackground.ignoresSafeArea()
            content
        }
        .task { await coordinator.refresh() }
        .navigationTitle("Editar reglas")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $sheetRule) { rule in
            NavigationStack {
                EditRuleSheet(
                    rule: rule,
                    pending: coordinator.pendingVotes[rule.id],
                    coordinator: coordinator,
                    onDismiss: { sheetRule = nil }
                )
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if coordinator.isLoading && coordinator.rules.isEmpty {
            ProgressView().tint(Color.ruulAccent)
        } else if coordinator.rules.isEmpty {
            emptyState
        } else {
            list
        }
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RuulSpacing.md) {
                header
                modeBanner
                VStack(spacing: RuulSpacing.sm) {
                    // Repo lists rules ordered by created_at ASC; toggle
                    // mutates in place via withIsActive, so order is stable.
                    ForEach(coordinator.rules) { rule in
                        ruleCard(rule)
                    }
                }
                footer
            }
            .padding(.horizontal, RuulSpacing.lg)
            .padding(.top, RuulSpacing.md)
            .padding(.bottom, RuulSpacing.s12)
        }
        .scrollIndicators(.hidden)
        .refreshable { await coordinator.refresh() }
    }

    /// Renders the governance state for this group:
    /// - `.voteGated` → "los cambios abren votación" card; toggle still works
    ///   but each tap opens a vote_change vote (the coordinator handles the
    ///   server-side flow).
    /// - `.readOnly`  → "no podés editar" card; controls are disabled.
    /// - `.directWrite` → no banner (default editor experience).
    @ViewBuilder
    private var modeBanner: some View {
        switch coordinator.editMode {
        case .voteGated(let threshold):
            HStack(alignment: .top, spacing: RuulSpacing.sm) {
                Image(systemName: "checkmark.seal")
                    .foregroundStyle(Color.ruulAccent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Los cambios abren votación")
                        .ruulTextStyle(RuulTypography.body)
                        .foregroundStyle(Color.ruulTextPrimary)
                    Text("Necesitan \(threshold)% de votos a favor para aplicarse.")
                        .ruulTextStyle(RuulTypography.caption)
                        .foregroundStyle(Color.ruulTextSecondary)
                }
                Spacer()
            }
            .padding(RuulSpacing.md)
            .background(
                RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                    .fill(Color.ruulSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                    .stroke(Color.ruulAccent.opacity(0.3), lineWidth: 1)
            )
        case .readOnly:
            HStack(spacing: RuulSpacing.sm) {
                Image(systemName: "lock")
                    .foregroundStyle(Color.ruulTextTertiary)
                    .accessibilityHidden(true)
                Text("Tu rol no puede editar reglas en este grupo.")
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextSecondary)
                Spacer()
            }
            .padding(RuulSpacing.md)
            .background(
                RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                    .fill(Color.ruulSurface)
            )
        case .directWrite:
            EmptyView()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text(coordinator.group.name)
                .ruulTextStyle(RuulTypography.sectionLabelLg)
                .foregroundStyle(Color.ruulTextSecondary)
            Text("Reglas pre-armadas")
                .ruulTextStyle(RuulTypography.title)
                .foregroundStyle(Color.ruulTextPrimary)
        }
        .padding(.top, RuulSpacing.xs)
    }

    private var footer: some View {
        Text("Las reglas personalizadas estarán disponibles en una próxima versión.")
            .ruulTextStyle(RuulTypography.caption)
            .foregroundStyle(Color.ruulTextTertiary)
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
            .padding(.top, RuulSpacing.md)
    }

    private var emptyState: some View {
        EmptyStateView(
            systemImage: "list.bullet.clipboard",
            title: "Sin reglas",
            message: "Este grupo no tiene reglas configuradas."
        )
    }

    private func ruleCard(_ rule: GroupRule) -> some View {
        let pending = coordinator.pendingVotes[rule.id]
        let inFlight = coordinator.inFlightToggleIDs.contains(rule.id)

        return Button {
            sheetRule = rule
        } label: {
            HStack(alignment: .top, spacing: RuulSpacing.sm) {
                VStack(alignment: .leading, spacing: RuulSpacing.xxs) {
                    Text(rule.name)
                        .ruulTextStyle(RuulTypography.headline)
                        .foregroundStyle(Color.ruulTextPrimary)
                        .lineLimit(2)
                    fineDisplay(rule)
                    if let pending {
                        pendingBadge(pending)
                    }
                }
                Spacer()
                toggleColumn(rule, inFlight: inFlight, pending: pending)
            }
            .padding(RuulSpacing.md)
            .background(
                RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                    .fill(Color.ruulSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                    .stroke(Color.ruulSeparator, lineWidth: 1)
            )
            .opacity(rule.isActive ? 1.0 : 0.55)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func fineDisplay(_ rule: GroupRule) -> some View {
        switch rule.fineShape {
        case .flat(let amount):
            Text("Multa: \(formatMXN(amount))")
                .ruulTextStyle(RuulTypography.caption)
                .foregroundStyle(Color.ruulTextAccent)
        case .escalating:
            Text("Multa escalonada")
                .ruulTextStyle(RuulTypography.caption)
                .foregroundStyle(Color.ruulTextAccent)
        case .none, .unknown:
            EmptyView()
        }
    }

    private func toggleColumn(_ rule: GroupRule, inFlight: Bool, pending: PendingVote?) -> some View {
        VStack(spacing: RuulSpacing.xxs) {
            Toggle("", isOn: Binding(
                get: { rule.isActive },
                set: { newValue in
                    Task { await coordinator.setIsActive(rule: rule, isActive: newValue) }
                }
            ))
            .labelsHidden()
            .disabled(pending != nil)
            if inFlight {
                ProgressView().scaleEffect(0.6)
            }
        }
    }

    private func pendingBadge(_ vote: PendingVote) -> some View {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.locale = Locale(identifier: "es_MX")
        let relative = formatter.localizedString(for: vote.closesAt, relativeTo: .now)
        return HStack(spacing: RuulSpacing.xxs) {
            Image(systemName: "hand.raised.fill")
                .accessibilityHidden(true)
            Text("Votación pendiente · cierra \(relative)")
        }
        .ruulTextStyle(RuulTypography.footnote)
        .foregroundStyle(Color.ruulWarning)
        .padding(.top, RuulSpacing.xxs)
    }

    private func formatMXN(_ amount: Int) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = "MXN"
        nf.maximumFractionDigits = 0
        return nf.string(from: NSNumber(value: amount)) ?? "$\(amount)"
    }
}
