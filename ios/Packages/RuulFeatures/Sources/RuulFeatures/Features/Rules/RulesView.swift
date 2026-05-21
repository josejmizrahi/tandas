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
    @Environment(AppState.self) private var app
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
    /// Tap callback for a rule card. Wired by the presenting surface
    /// (currently sheet- or push-based since the standalone Decisions
    /// tab dissolved in Pass 2) to navigate to `RuleDetailView`.
    /// Default no-op for callsites that don't push.
    public var onSelectRule: (GroupRule) -> Void = { _ in }
    /// Beta 1 Rule Builder catalog. Loaded once at boot by AppState
    /// (`loadRuleTemplates()`). Empty list disables the "+" entry point.
    /// Per Plans/Active/Governance.md §0.5 + §10.
    public let ruleTemplates: [RuleBuilderTemplate]
    /// Server-backed publisher for the Rule Builder. nil in mock/preview
    /// where the builder is hidden behind the same gating as the pencil.
    public let ruleTemplateRepo: (any RuleTemplateRepository)?

    /// Free-composition composer presentation handle. Replaces the
    /// previous template-wizard (RuleBuilderCoordinator) — templates
    /// are now offered inside the composer as starter examples, not as
    /// the only entry point.
    @State private var composerCoord: RuleComposerCoordinator?

    /// Gallery-first sheet, presented from the empty-state CTA. Per
    /// UniversalRuleTemplates.md §8.2 — when the group has no rules,
    /// "Elige un patrón" is the canonical entry, not the per-piece
    /// composer (which stays behind the header "+" for admin/dev).
    @State private var showGallery: Bool = false

    public init(
        coordinator: RulesCoordinator,
        voteRepo: any VoteRepository,
        policyRepo: any GroupPolicyRepository,
        actorUserId: UUID,
        userActionRepo: (any UserActionRepository)? = nil,
        ruleTemplates: [RuleBuilderTemplate] = [],
        ruleTemplateRepo: (any RuleTemplateRepository)? = nil,
        onSeeOpenVotes: @escaping () -> Void = {},
        onSelectRule: @escaping (GroupRule) -> Void = { _ in }
    ) {
        self.coordinator = coordinator
        self.voteRepo = voteRepo
        self.policyRepo = policyRepo
        self.actorUserId = actorUserId
        self.userActionRepo = userActionRepo
        self.ruleTemplates = ruleTemplates
        self.ruleTemplateRepo = ruleTemplateRepo
        self.onSeeOpenVotes = onSeeOpenVotes
        self.onSelectRule = onSelectRule
    }

    /// Becomes true when the user is admin AND the builder dependencies
    /// are wired (live mode). Hidden in preview/mock where repo is nil.
    private var canShowBuilder: Bool {
        coordinator.canEditRules && ruleTemplateRepo != nil
    }

    /// Canonical Beta-1 template subset for the Gallery + starter picker.
    /// Filtered per UniversalRuleTemplates.md §14.2 — no aliases, no
    /// post_beta, only active rows.
    private var galleryTemplates: [RuleBuilderTemplate] {
        ruleTemplates.filter {
            $0.aliasOf == nil && $0.status == "active" && $0.betaStatus == "beta1"
        }
    }

    private func openBuilder() {
        guard let repo = ruleTemplateRepo else { return }
        // Group-level composer: no resource_type filter; all curated
        // templates surface as starter examples (the user can ignore
        // them and compose from scratch).
        composerCoord = RuleComposerCoordinator(
            group: coordinator.group,
            shapeRegistry: app.ruleShapeRegistry,
            repo: repo,
            scope: .group,
            resourceType: nil,
            starterTemplates: galleryTemplates
        )
    }

    /// Opens the composer pre-seeded from a Gallery-picked template.
    /// Used by the empty-state Gallery-first flow: user picks a
    /// universal pattern → composer opens with the draft already
    /// populated → user just fills the params + publishes.
    private func openSeededComposer(template: RuleBuilderTemplate) {
        guard let repo = ruleTemplateRepo else { return }
        let draft = RuleDraft.from(template: template, scope: .group)
        composerCoord = RuleComposerCoordinator(
            group: coordinator.group,
            shapeRegistry: app.ruleShapeRegistry,
            repo: repo,
            draft: draft,
            resourceType: nil,
            starterTemplates: galleryTemplates
        )
    }

    public var body: some View {
        AsyncContentView(
            phase: coordinator.phase,
            onRetry: { await coordinator.refresh() },
            empty: { emptyScrollContainer },
            loaded: { rules in loadedScrollContainer(rules) }
        )
        .task { await coordinator.refresh() }
        .fullScreenCover(item: $composerCoord) { coord in
            RuleComposerView(
                coord: coord,
                onPublished: { _ in
                    composerCoord = nil
                    Task { await coordinator.refresh() }
                },
                onCancel: { composerCoord = nil }
            )
        }
        // Gallery-first sheet — opens from the empty-state CTA.
        // On pick: dismisses + opens composer pre-seeded.
        // On cancel: dismisses, user stays on empty state.
        .fullScreenCover(isPresented: $showGallery) {
            UniversalTemplateGallerySheet(
                templates: galleryTemplates,
                onSelect: { template in
                    showGallery = false
                    openSeededComposer(template: template)
                },
                onCancel: { showGallery = false }
            )
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
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.secondary)
                Text("\(activeCount) reglas activas")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Color.primary)
            }
            Spacer(minLength: 0)
            if canShowBuilder {
                Button(action: openBuilder) {
                    Image(systemName: "plus")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.primary)
                        .frame(width: 36, height: 36)
                        .background(Color.ruulSurface, in: Circle())
                        .overlay(Circle().stroke(Color(.separator), lineWidth: 0.5))
                        .accessibilityHidden(true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Nueva regla")
            }
            if coordinator.canEditRules {
                NavigationLink {
                    EditRulesView(coordinator: makeEditCoordinator())
                } label: {
                    Image(systemName: "pencil")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.primary)
                        .frame(width: 36, height: 36)
                        .background(Color.ruulSurface, in: Circle())
                        .overlay(Circle().stroke(Color(.separator), lineWidth: 0.5))
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

    /// Empty/loaded shells reusan el mismo scroll + header para que la
    /// transición entre estados sea continua (sin que el header
    /// desaparezca/reaparezca).
    private var emptyScrollContainer: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RuulSpacing.lg) {
                header
                emptyStateBody
            }
            .padding(.horizontal, RuulSpacing.lg)
            .padding(.top, RuulSpacing.md)
            .padding(.bottom, RuulSpacing.s12)
        }
        .scrollIndicators(.hidden)
        .refreshable { await coordinator.refresh() }
    }

    private func loadedScrollContainer(_ rules: [GroupRule]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RuulSpacing.md) {
                header
                RuulSeparatedRows(items: rules) { rule in
                    ruleCard(rule)
                }
                footnote
            }
            .padding(.horizontal, RuulSpacing.lg)
            .padding(.top, RuulSpacing.md)
            .padding(.bottom, RuulSpacing.s12)
        }
        .scrollIndicators(.hidden)
        .refreshable { await coordinator.refresh() }
    }

    /// Empty-state body rendered below the header when the group has zero
    /// rules. Admins see the Rule Builder CTA ("Crear primera regla") —
    /// header's "+" button is also visible above for symmetry with the
    /// non-empty list state. Non-admins see only the explanatory copy.
    @ViewBuilder
    private var emptyStateBody: some View {
        VStack(spacing: RuulSpacing.md) {
            Image(systemName: "list.bullet.clipboard")
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(Color(.tertiaryLabel))
                .padding(.top, RuulSpacing.xl)
            Text("Sin reglas")
                .font(.title2.weight(.semibold))
                .foregroundStyle(Color.primary)
            Text("Este grupo aún no tiene reglas configuradas. Elige un patrón y se activa con dos taps.")
                .font(.subheadline)
                .foregroundStyle(Color.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, RuulSpacing.lg)
            if canShowBuilder {
                // Gallery-first per UniversalRuleTemplates.md §8.2 —
                // empty state is the canonical moment for "elige un
                // patrón", not the per-piece composer (which stays on
                // the header "+" for free composition).
                Button(action: { showGallery = true }) {
                    Label("Elegir un patrón", systemImage: "square.grid.2x2.fill")
                        .font(.headline)
                        .foregroundStyle(Color.ruulAccent)
                        .padding(.vertical, RuulSpacing.sm)
                        .padding(.horizontal, RuulSpacing.lg)
                        .background(
                            Capsule().fill(Color.ruulAccent.opacity(0.12))
                        )
                }
                .buttonStyle(.plain)
                .padding(.top, RuulSpacing.sm)
                Button("o componer desde cero", action: openBuilder)
                    .font(.caption)
                    .foregroundStyle(Color(.tertiaryLabel))
            }
        }
        .frame(maxWidth: .infinity)
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
                        .font(.headline)
                        .foregroundStyle(Color.primary)
                    Text(
                        coordinator.openVotesCount == 1
                        ? "1 votación pendiente"
                        : "\(coordinator.openVotesCount) votaciones pendientes"
                    )
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color(.tertiaryLabel))
                    .accessibilityHidden(true)
            }
            .padding(RuulSpacing.md)
            .background(
                RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                    .stroke(Color(.separator), lineWidth: 0.5)
            )
        }
        .buttonStyle(.ruulPress)
    }

    private func ruleCard(_ rule: GroupRule) -> some View {
        Button(action: { onSelectRule(rule) }) {
            HStack(alignment: .top, spacing: RuulSpacing.sm) {
                VStack(alignment: .leading, spacing: RuulSpacing.xxs) {
                    Text(rule.name)
                        .font(.headline)
                        .foregroundStyle(rule.isLive ? Color.primary : Color(.tertiaryLabel))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let chip = scopeChip(for: rule) {
                        chip
                    }
                    if !rule.isLive {
                        Text("Inactiva")
                            .font(.footnote)
                            .foregroundStyle(Color(.tertiaryLabel))
                    }
                }
                Spacer()
                amountBadge(rule)
            }
            .padding(RuulSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous)
                    .stroke(Color(.separator), lineWidth: 1)
            )
            .opacity(rule.isLive ? 1.0 : 0.55)
            .contentShape(RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous))
        }
        .buttonStyle(.ruulPress)
        .accessibilityHint("Abre el detalle de la regla")
    }

    /// Renders a small pill describing where the rule applies. Group-scoped
    /// rules return nil — they're the default for this list, so a chip
    /// would just add noise. Non-group scopes get a labelled badge so the
    /// reader can tell at a glance whether the rule covers one resource,
    /// one series, one module, or one member.
    private func scopeChip(for rule: GroupRule) -> ScopeBadge? {
        switch rule.scope {
        case .group:
            return nil
        case .module:
            let label = rule.moduleKey.map { "Función · \($0)" } ?? "Función"
            return ScopeBadge(label: label, icon: "puzzlepiece", tint: .secondary)
        case .series:
            return ScopeBadge(label: "Toda la recurrencia", icon: "repeat", tint: .blue)
        case .resource:
            return ScopeBadge(label: "Esta instancia", icon: "scope", tint: .blue)
        case .membership:
            return ScopeBadge(label: "Por miembro", icon: "person", tint: .orange)
        }
    }

    @ViewBuilder
    private func amountBadge(_ rule: GroupRule) -> some View {
        if let amount = FineConsequenceParser.firstAmountMXN(in: rule.consequences) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(format(amount: amount))
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Color.ruulTextAccent)
                Text("Multa")
                    .font(.footnote)
                    .foregroundStyle(Color(.tertiaryLabel))
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
            .font(.caption)
            .foregroundStyle(Color(.tertiaryLabel))
            .padding(.top, RuulSpacing.sm)
    }
}

/// Inline pill rendered by `RulesView.scopeChip(for:)`. Tinted capsule
/// with icon + caption-weight label. Lives next to its only caller.
private struct ScopeBadge: View {
    let label: String
    let icon: String
    let tint: Color

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
            Text(label)
                .font(.caption2.weight(.semibold))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .foregroundStyle(tint)
        .background(tint.opacity(0.15), in: .capsule)
    }
}
