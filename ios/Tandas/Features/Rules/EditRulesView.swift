import SwiftUI

/// Edit-mode counterpart to RulesView. Reachable via the conditional
/// pencil button in RulesView nav (visible iff governance.canPerform(
/// .modifyRules) == .allowed for the current actor).
struct EditRulesView: View {
    @Bindable var coordinator: EditRulesCoordinator
    @State private var sheetRule: GroupRule?

    var body: some View {
        ZStack {
            Color.ruulBackgroundCanvas.ignoresSafeArea()
            content
        }
        .task { await coordinator.refresh() }
        .navigationTitle("Editar reglas")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $sheetRule) { rule in
            // EditRuleSheet is implemented in C3. For C2, we just need
            // a placeholder navigation that doesn't crash. C3 will
            // replace this with the real sheet.
            NavigationStack {
                Text("EditRuleSheet placeholder for: \(rule.title)")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancelar") { sheetRule = nil }
                        }
                    }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if coordinator.isLoading && coordinator.rules.isEmpty {
            ProgressView().tint(Color.ruulAccentPrimary)
        } else if coordinator.rules.isEmpty {
            emptyState
        } else {
            list
        }
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RuulSpacing.s4) {
                header
                VStack(spacing: RuulSpacing.s3) {
                    // Repo lists rules ordered by created_at ASC; toggle
                    // mutates in place via withEnabled, so order is stable.
                    ForEach(coordinator.rules) { rule in
                        ruleCard(rule)
                    }
                }
                footer
            }
            .padding(.horizontal, RuulSpacing.s5)
            .padding(.top, RuulSpacing.s4)
            .padding(.bottom, RuulSpacing.s12)
        }
        .scrollIndicators(.hidden)
        .refreshable { await coordinator.refresh() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.s2) {
            Text(coordinator.group.name)
                .ruulTextStyle(RuulTypography.sectionLabelLg)
                .foregroundStyle(Color.ruulTextSecondary)
            Text("Reglas pre-armadas")
                .ruulTextStyle(RuulTypography.title)
                .foregroundStyle(Color.ruulTextPrimary)
        }
        .padding(.top, RuulSpacing.s2)
    }

    private var footer: some View {
        Text("Las reglas personalizadas estarán disponibles en una próxima versión.")
            .ruulTextStyle(RuulTypography.caption)
            .foregroundStyle(Color.ruulTextTertiary)
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
            .padding(.top, RuulSpacing.s4)
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
            HStack(alignment: .top, spacing: RuulSpacing.s3) {
                VStack(alignment: .leading, spacing: RuulSpacing.s1) {
                    Text(rule.title)
                        .ruulTextStyle(RuulTypography.headline)
                        .foregroundStyle(Color.ruulTextPrimary)
                        .lineLimit(2)
                    if let desc = rule.description, !desc.isEmpty {
                        Text(desc)
                            .ruulTextStyle(RuulTypography.caption)
                            .foregroundStyle(Color.ruulTextSecondary)
                            .lineLimit(3)
                    }
                    fineDisplay(rule)
                    if let pending {
                        pendingBadge(pending)
                    }
                }
                Spacer()
                toggleColumn(rule, inFlight: inFlight, pending: pending)
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
            .opacity(rule.enabled ? 1.0 : 0.55)
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
        VStack(spacing: RuulSpacing.s1) {
            Toggle("", isOn: Binding(
                get: { rule.enabled },
                set: { newValue in
                    Task { await coordinator.setEnabled(rule: rule, enabled: newValue) }
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
        return HStack(spacing: RuulSpacing.s1) {
            Image(systemName: "hand.raised.fill")
            Text("Votación pendiente · cierra \(relative)")
        }
        .ruulTextStyle(RuulTypography.footnote)
        .foregroundStyle(Color.ruulSemanticWarning)
        .padding(.top, RuulSpacing.s1)
    }

    private func formatMXN(_ amount: Int) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = "MXN"
        nf.maximumFractionDigits = 0
        return nf.string(from: NSNumber(value: amount)) ?? "$\(amount)"
    }
}
