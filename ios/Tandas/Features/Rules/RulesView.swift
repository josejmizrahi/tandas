import SwiftUI

/// Read-only list of the active group's rules. Replaces RulesTabStub. Each
/// rule shows its name, description, and fine amount badge. Inactive /
/// disabled rules render dimmed. The trailing toolbar pencil is visible
/// iff `coordinator.canEditRules` (governance check passes for
/// `.modifyRules`); tapping it pushes `EditRulesView` with a fresh
/// `EditRulesCoordinator` built from the same dependencies.
struct RulesView: View {
    @Bindable var coordinator: RulesCoordinator
    /// `VoteRepository` is needed by `EditRulesCoordinator.openRepealVote`.
    /// `RulesCoordinator` itself doesn't use it, so the view holds it
    /// directly to avoid leaking the dependency into the read-side coord.
    let voteRepo: any VoteRepository

    var body: some View {
        ZStack {
            Color.ruulBackgroundCanvas.ignoresSafeArea()
            if coordinator.isLoading && coordinator.rules.isEmpty {
                ProgressView().tint(Color.ruulAccentPrimary)
            } else if coordinator.rules.isEmpty {
                EmptyStateView(
                    systemImage: "list.bullet.clipboard",
                    title: "Sin reglas",
                    message: "Este grupo aún no tiene reglas configuradas."
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: RuulSpacing.s4) {
                        header
                        VStack(spacing: RuulSpacing.s3) {
                            ForEach(coordinator.rules) { rule in
                                ruleCard(rule)
                            }
                        }
                        footnote
                    }
                    .padding(.horizontal, RuulSpacing.s5)
                    .padding(.top, RuulSpacing.s4)
                    .padding(.bottom, RuulSpacing.s12)
                }
                .scrollIndicators(.hidden)
                .refreshable { await coordinator.refresh() }
            }
        }
        .task { await coordinator.refresh() }
        .navigationTitle("Reglas")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if coordinator.canEditRules {
                    NavigationLink {
                        EditRulesView(coordinator: makeEditCoordinator())
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .accessibilityLabel("Editar reglas")
                }
            }
        }
    }

    /// Builds a fresh `EditRulesCoordinator` reusing the read-side coord's
    /// dependencies plus the locally-held `voteRepo`. Constructed lazily so
    /// the navigation destination only spins one up when the user taps the
    /// pencil.
    private func makeEditCoordinator() -> EditRulesCoordinator {
        EditRulesCoordinator(
            group: coordinator.group,
            currentMember: coordinator.currentMember,
            governance: coordinator.governance,
            ruleRepo: coordinator.ruleRepo,
            voteRepo: voteRepo
        )
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.s2) {
            Text(coordinator.group.name)
                .ruulTextStyle(RuulTypography.sectionLabelLg)
                .foregroundStyle(Color.ruulTextSecondary)
            Text("\(activeCount) reglas activas")
                .ruulTextStyle(RuulTypography.title)
                .foregroundStyle(Color.ruulTextPrimary)
        }
        .padding(.top, RuulSpacing.s2)
    }

    private var activeCount: Int {
        coordinator.rules.filter(\.isLive).count
    }

    private func ruleCard(_ rule: GroupRule) -> some View {
        HStack(alignment: .top, spacing: RuulSpacing.s3) {
            VStack(alignment: .leading, spacing: RuulSpacing.s1) {
                Text(rule.title)
                    .ruulTextStyle(RuulTypography.headline)
                    .foregroundStyle(rule.isLive ? Color.ruulTextPrimary : Color.ruulTextTertiary)
                    .lineLimit(2)
                if let desc = rule.description, !desc.isEmpty {
                    Text(desc)
                        .ruulTextStyle(RuulTypography.caption)
                        .foregroundStyle(Color.ruulTextSecondary)
                        .lineLimit(3)
                }
                if !rule.isLive {
                    Text("INACTIVA")
                        .ruulTextStyle(RuulTypography.footnote)
                        .foregroundStyle(Color.ruulTextTertiary)
                }
            }
            Spacer()
            amountBadge(rule)
        }
        .padding(RuulSpacing.s4)
        .background(
            RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous)
                .fill(Color.ruulBackgroundElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous)
                .stroke(Color.ruulBorderSubtle, lineWidth: 1)
        )
        .opacity(rule.isLive ? 1.0 : 0.55)
    }

    @ViewBuilder
    private func amountBadge(_ rule: GroupRule) -> some View {
        if let amount = rule.amountMXN {
            VStack(alignment: .trailing, spacing: 2) {
                Text(format(amount: amount))
                    .ruulTextStyle(RuulTypography.title)
                    .foregroundStyle(Color.ruulTextAccent)
                Text("MULTA")
                    .ruulTextStyle(RuulTypography.footnote)
                    .foregroundStyle(Color.ruulTextTertiary)
            }
        }
    }

    private func format(amount: Int) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = "MXN"
        nf.maximumFractionDigits = 0
        return nf.string(from: NSNumber(value: amount)) ?? "$\(amount)"
    }

    private var footnote: some View {
        Text("Las reglas se aplican automáticamente cuando ocurre el evento que las dispara. Pronto vas a poder editarlas y agregar más.")
            .ruulTextStyle(RuulTypography.caption)
            .foregroundStyle(Color.ruulTextTertiary)
            .padding(.top, RuulSpacing.s3)
    }
}
