import SwiftUI
import RuulUI
import RuulCore

/// Read-only list of the active group's rules. Replaces RulesTabStub. Each
/// rule shows its name, description, and fine amount badge. Inactive /
/// disabled rules render dimmed. The trailing toolbar pencil is visible
/// iff `coordinator.canEditRules` (governance check passes for
/// `.modifyRules`); tapping it pushes `EditRulesView` with a fresh
/// `EditRulesCoordinator` built from the same dependencies.
public struct RulesView: View {
    @Bindable var coordinator: RulesCoordinator
    /// `VoteRepository` is needed by `EditRulesCoordinator.openRepealVote`.
    /// `RulesCoordinator` itself doesn't use it, so the view holds it
    /// directly to avoid leaking the dependency into the read-side coord.
    public let voteRepo: any VoteRepository
    /// `GroupPolicyRepository` is forwarded into `EditRulesCoordinator` so it
    /// can resolve the active policy decision and gate edits via vote when
    /// the group config requires it (mig 00087 / 00088).
    public let policyRepo: any GroupPolicyRepository
    /// Auth user id of the current actor — composed with `policyRepo` +
    /// `voteRepo` to drive the governance-aware mutations in
    /// `EditRulesCoordinator`. Source: `app.session?.user.id` at the seam.
    public let actorUserId: UUID
    /// Phase G3: forwarded into `EditRulesCoordinator` so saves of an
    /// inbox-reached rule can resolve the originating `UserAction`. nil
    /// for previews / call sites that don't need inbox integration.
    public let userActionRepo: (any UserActionRepository)?
    /// Tap callback for the "Votos abiertos" section. Wired by the parent
    /// (MainTabView) in G3 to push `OpenVotesListView`. For G2 it can be
    /// a no-op closure.
    public var onSeeOpenVotes: () -> Void = {}
    /// Tap callback for a rule card. Wired by the parent
    /// (GroupTabView → MainTabView) para pushear `RuleDetailView` en el
    /// groupTab `NavigationStack`. Default no-op para callsites legacy.
    public var onSelectRule: (GroupRule) -> Void = { _ in }

    public init(
        coordinator: RulesCoordinator,
        voteRepo: any VoteRepository,
        policyRepo: any GroupPolicyRepository,
        actorUserId: UUID,
        userActionRepo: (any UserActionRepository)? = nil,
        onSeeOpenVotes: @escaping () -> Void = {},
        onSelectRule: @escaping (GroupRule) -> Void = { _ in }
    ) {
        self.coordinator = coordinator
        self.voteRepo = voteRepo
        self.policyRepo = policyRepo
        self.actorUserId = actorUserId
        self.userActionRepo = userActionRepo
        self.onSeeOpenVotes = onSeeOpenVotes
        self.onSelectRule = onSelectRule
    }

    public var body: some View {
        ZStack {
            Color.ruulBackground.ignoresSafeArea()
            SwiftUI.Group {
                if let error = coordinator.error, coordinator.rules.isEmpty {
                    ErrorStateView(error: error, retry: { Task { await coordinator.refresh() } })
                        .padding(.horizontal, RuulSpacing.lg)
                        .padding(.top, RuulSpacing.lg)
                        .transition(.opacity)
                } else if coordinator.isLoading && coordinator.rules.isEmpty {
                    RuulLoadingState()
                        .transition(.opacity)
                } else if coordinator.rules.isEmpty {
                    EmptyStateView(
                        systemImage: "list.bullet.clipboard",
                        title: "Sin reglas",
                        message: "Este grupo aún no tiene reglas configuradas."
                    )
                    .transition(.opacity)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: RuulSpacing.md) {
                            header
                            // "Votos abiertos" link removed — votes have their
                                // own sub-tab post-Plan1 cleanup. RulesView stays
                                // focused on rule list + governance.
                            VStack(spacing: RuulSpacing.sm) {
                                ForEach(coordinator.rules) { rule in
                                    ruleCard(rule)
                                }
                            }
                            footnote
                        }
                        .padding(.horizontal, RuulSpacing.lg)
                        .padding(.top, RuulSpacing.md)
                        .padding(.bottom, RuulSpacing.s12)
                    }
                    .scrollIndicators(.hidden)
                    .refreshable { await coordinator.refresh() }
                    .transition(.opacity)
                }
            }
            .animation(.linear(duration: RuulDuration.fast), value: coordinator.error)
            .animation(.linear(duration: RuulDuration.fast), value: coordinator.isLoading)
            .animation(.linear(duration: RuulDuration.fast), value: coordinator.rules.isEmpty)
        }
        .task { await coordinator.refresh() }
    }

    /// Builds a fresh `EditRulesCoordinator` reusing the read-side coord's
    /// dependencies plus the locally-held `voteRepo`. Constructed lazily so
    /// the navigation destination only spins one up when the user taps the
    /// pencil.
    private func makeEditCoordinator() -> EditRulesCoordinator {
        EditRulesCoordinator(
            group: coordinator.group,
            currentMember: coordinator.currentMember,
            actorUserId: actorUserId,
            governance: coordinator.governance,
            policyRepo: policyRepo,
            ruleRepo: coordinator.ruleRepo,
            voteRepo: voteRepo,
            userActionRepo: userActionRepo
        )
    }

    private var header: some View {
        HStack(alignment: .top, spacing: RuulSpacing.sm) {
            VStack(alignment: .leading, spacing: RuulSpacing.xs) {
                Text(coordinator.group.name)
                    .ruulTextStyle(RuulTypography.sectionLabelLg)
                    .foregroundStyle(Color.ruulTextSecondary)
                Text("\(activeCount) reglas activas")
                    .ruulTextStyle(RuulTypography.title)
                    .foregroundStyle(Color.ruulTextPrimary)
            }
            Spacer(minLength: 0)
            if coordinator.canEditRules {
                NavigationLink {
                    EditRulesView(coordinator: makeEditCoordinator())
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Color.ruulTextPrimary)
                        .frame(width: 36, height: 36)
                        .background(Color.ruulSurface, in: Circle())
                        .overlay(Circle().stroke(Color.ruulSeparator, lineWidth: 0.5))
                        .accessibilityHidden(true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Editar reglas")
            }
        }
        .padding(.top, RuulSpacing.xs)
    }

    private var activeCount: Int {
        coordinator.rules.filter(\.isLive).count
    }

    /// Surface proactivo: muestra count de votes abiertos del grupo y linkea
    /// a `OpenVotesListView`. Solo se renderiza si hay 1+ votes abiertos —
    /// el caller ya verifica `openVotesCount > 0` antes de incluir esta
    /// vista en el body.
    private var openVotesSection: some View {
        Button(action: onSeeOpenVotes) {
            HStack(spacing: RuulSpacing.sm) {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(Color.ruulAccent)
                    .frame(width: 32, height: 32)
                    .background(Color.ruulSurface, in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Votos abiertos")
                        .ruulTextStyle(RuulTypography.headline)
                        .foregroundStyle(Color.ruulTextPrimary)
                    Text(
                        coordinator.openVotesCount == 1
                        ? "1 votación pendiente"
                        : "\(coordinator.openVotesCount) votaciones pendientes"
                    )
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.ruulTextTertiary)
                    .accessibilityHidden(true)
            }
            .padding(RuulSpacing.md)
            .background(
                RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                    .fill(Color.ruulSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                    .stroke(Color.ruulSeparator, lineWidth: 0.5)
            )
        }
        .buttonStyle(.ruulPress)
    }

    private func ruleCard(_ rule: GroupRule) -> some View {
        Button(action: { onSelectRule(rule) }) {
            HStack(alignment: .top, spacing: RuulSpacing.sm) {
                VStack(alignment: .leading, spacing: RuulSpacing.xxs) {
                    Text(rule.name)
                        .ruulTextStyle(RuulTypography.headline)
                        .foregroundStyle(rule.isLive ? Color.ruulTextPrimary : Color.ruulTextTertiary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if !rule.isLive {
                        Text("INACTIVA")
                            .ruulTextStyle(RuulTypography.footnote)
                            .foregroundStyle(Color.ruulTextTertiary)
                    }
                }
                Spacer()
                amountBadge(rule)
            }
            .padding(RuulSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous)
                    .fill(Color.ruulSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous)
                    .stroke(Color.ruulSeparator, lineWidth: 1)
            )
            .opacity(rule.isLive ? 1.0 : 0.55)
            .contentShape(RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous))
        }
        .buttonStyle(.ruulPress)
        .accessibilityHint("Abre el detalle de la regla")
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
            .padding(.top, RuulSpacing.sm)
    }
}
