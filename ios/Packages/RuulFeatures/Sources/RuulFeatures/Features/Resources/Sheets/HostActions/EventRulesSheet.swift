import SwiftUI
import RuulUI
import RuulCore

/// Rules surface for a single resource. Per founder framing 2026-05-10
/// rules cascade across 5 scope levels and the viewer must see what
/// applies, not just what was authored at the resource level. This
/// surface renders three sections in specificity order:
///
///   1. "De este recurso"  — rules.resource_id = resource.id
///   2. "De la serie"      — rules.series_id   = resource's series
///   3. "Del grupo"        — group-scoped rules (includes platform defaults)
///
/// Only "De este recurso" rules are editable from here; the inherited
/// sections render with a "Heredada" chip and a softer visual treatment
/// so the viewer understands they need to navigate to the source scope to
/// change them. Tap → navigation to source = future R4 work.
///
/// File name kept for git continuity; the types are the generic
/// `ResourceRulesBody` (inline content) + `ResourceRulesSheet`
/// (modal-chrome wrapper) that handle any Resource — event, asset,
/// fund, etc.

// MARK: - Inline body

/// Inline content for the Rules surface — the actual list + add CTA +
/// sub-sheet wiring. Rendered both as the body of `ResourceRulesSheet`
/// (when the viewer opens it from the ⋯ menu) and inline inside the
/// resource detail's Reglas tab (`RulesSectionView`). Owns no
/// presentation chrome; the caller is responsible for any wrapping
/// container.
@MainActor
struct ResourceRulesBody: View {
    @Bindable var coordinator: ResourceRulesCoordinator
    @Environment(AppState.self) private var app

    /// Rule Composer presentation handle. Non-nil when admin opens the "+"
    /// button to create a resource-scoped rule via free composition.
    /// Replaces the previous template-gallery wizard (mig 00245 sibling):
    /// templates can now be loaded inside the composer as starting points
    /// rather than being the only path.
    @State private var composerCoord: RuleComposerCoordinator?

    var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.lg) {
            if coordinator.isLoading && coordinator.rules.isEmpty {
                RuulLoadingState()
                    .frame(maxWidth: .infinity, minHeight: 200)
            } else if coordinator.rules.isEmpty {
                EmptyStateView(
                    systemImage: "list.bullet.clipboard",
                    title: "Sin reglas aplicables",
                    message: coordinator.canCreate
                        ? "Agrega reglas que sólo apliquen a este recurso. Las del grupo seguirán aplicando."
                        : "Sólo el anfitrión o un fundador pueden crear reglas específicas para este recurso."
                )
                .padding(.vertical, RuulSpacing.md)
            } else {
                scopeSection(
                    title: "DE ESTE RECURSO",
                    hint: "Específicos a este recurso. Sobrescriben las heredadas.",
                    rules: coordinator.resourceRules,
                    scope: .resource
                )
                scopeSection(
                    title: "DE LA SERIE",
                    hint: "Aplican a todas las ocurrencias de esta recurrencia.",
                    rules: coordinator.seriesRules,
                    scope: .series
                )
                scopeSection(
                    title: "DEL GRUPO",
                    hint: "Defaults del grupo. Aplican salvo override más específico.",
                    rules: coordinator.groupRules,
                    scope: .group
                )
            }
            if coordinator.canCreate {
                addRuleCTA
                    .padding(.top, RuulSpacing.sm)
            }
        }
        .task { await coordinator.load() }
        .ruulSheet(isPresented: $coordinator.addSheetPresented) {
            AddResourceRuleSheet(
                isPresented: $coordinator.addSheetPresented,
                coordinator: coordinator
            )
        }
        .fullScreenCover(item: $composerCoord) { coord in
            RuleComposerView(
                coord: coord,
                onPublished: { _ in
                    composerCoord = nil
                    Task { await coordinator.load() }
                },
                onCancel: { composerCoord = nil }
            )
            .environment(app)
        }
    }

    // MARK: - Section per scope

    @ViewBuilder
    private func scopeSection(
        title: String,
        hint: String,
        rules: [GroupRule],
        scope: GroupRule.Scope
    ) -> some View {
        if !rules.isEmpty {
            VStack(alignment: .leading, spacing: RuulSpacing.xs) {
                HStack(alignment: .firstTextBaseline, spacing: RuulSpacing.xs) {
                    Text(title)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color(.tertiaryLabel))
                    Spacer()
                    Text("\(rules.count)")
                        .font(.footnote)
                        .foregroundStyle(Color(.tertiaryLabel))
                        .monospacedDigit()
                }
                Text(hint)
                    .font(.footnote)
                    .foregroundStyle(Color(.tertiaryLabel))
                VStack(spacing: RuulSpacing.xs) {
                    ForEach(rules) { rule in
                        ruleRow(rule, isInherited: scope != .resource)
                    }
                }
            }
        }
    }

    // MARK: - Rule row

    private func ruleRow(_ rule: GroupRule, isInherited: Bool) -> some View {
        let triggerLabel = sentencePreview(for: rule)
        let fineAmount = FineConsequenceParser.firstAmountMXN(in: rule.consequences)
        return VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            HStack(spacing: RuulSpacing.sm) {
                ZStack {
                    Circle()
                        .fill(Color.ruulAccent.opacity(isInherited ? 0.06 : 0.12))
                        .frame(width: 32, height: 32)
                    Image(systemName: "list.bullet.clipboard.fill")
                        .font(.footnote)
                        .foregroundStyle(isInherited ? Color.secondary : Color.ruulAccent)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: RuulSpacing.xs) {
                        Text(rule.name)
                            .font(.subheadline)
                            .foregroundStyle(isInherited ? Color.secondary : Color.primary)
                            .lineLimit(2)
                        if isInherited {
                            Text(badgeText(for: rule.scope))
                                .font(.footnote)
                                .foregroundStyle(Color(.tertiaryLabel))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule().fill(Color.ruulAccentMuted)
                                )
                        }
                    }
                    Text(triggerLabel)
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                        .lineLimit(2)
                }
                Spacer()
                if let amount = fineAmount {
                    Text("$\(amount)")
                        .font(.subheadline)
                        .foregroundStyle(isInherited ? Color.secondary : Color.primary)
                        .monospacedDigit()
                }
            }
        }
        .padding(.horizontal, RuulSpacing.md)
        .padding(.vertical, RuulSpacing.sm)
        .background(Color.ruulBackgroundCanvas, in: RoundedRectangle(cornerRadius: RuulRadius.medium))
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.medium)
                .stroke(Color(.separator), lineWidth: 0.5)
        )
        .opacity(isInherited ? 0.85 : 1.0)
    }

    private var addRuleCTA: some View {
        RuulButton(
            "Agregar regla para este recurso",
            systemImage: "plus",
            style: .primary,
            size: .large,
            fillsWidth: true
        ) {
            openRuleBuilder()
        }
    }

    /// Opens the Rule Composer for free composition (no template wizard).
    /// The composer's draft is pre-scoped to `.resource(<this resource>)`
    /// and the resourceType context is passed so the trigger picker only
    /// offers shapes compatible with this resource.
    ///
    /// Falls back to the legacy catalog-free form when the live template
    /// repo isn't wired (preview/mock with no AppState repo).
    private func openRuleBuilder() {
        guard coordinator.canCreate else { return }
        guard let repo = app.ruleTemplateRepo,
              let group = app.groups.first(where: { $0.id == coordinator.groupId }) else {
            // Legacy fallback — shape-based raw form on ResourceRulesCoordinator.
            coordinator.resetForm()
            coordinator.addSheetPresented = true
            return
        }
        // Templates surface as "starter examples" inside the composer,
        // pre-filtered to the templates whose trigger shape supports
        // this resource_type (so an asset never sees event templates).
        // The filter mirrors mig 00244 server-side; we keep it client-
        // side here for instant gallery render without a round-trip.
        let resourceType = coordinator.context.resourceType
        let registry = coordinator.shapeRegistry
        let compatible = app.ruleTemplates.filter { template in
            // Universal-templates filter (UniversalRuleTemplates.md §14.2):
            // only Beta-1 canonical templates surface in the Gallery; aliases
            // and post_beta rows are hidden but stay resolvable by the engine.
            guard template.aliasOf == nil,
                  template.status == "active",
                  template.betaStatus == "beta1"
            else { return false }
            guard let shape = registry.shape(id: template.composition.triggerShapeId) else { return true }
            if shape.validResourceTypes.isEmpty { return true }
            return shape.validResourceTypes.contains(resourceType)
        }
        composerCoord = RuleComposerCoordinator(
            group: group,
            shapeRegistry: coordinator.shapeRegistry,
            repo: repo,
            scope: .resource(coordinator.resourceId),
            resourceType: resourceType,
            starterTemplates: compatible
        )
    }

    // MARK: - Helpers

    private func badgeText(for scope: GroupRule.Scope) -> String {
        switch scope {
        case .membership: return "Para ti"
        case .resource:   return "Recurso"
        case .series:     return "Heredada · serie"
        case .module:     return "Heredada · módulo"
        case .group:      return "Heredada · grupo"
        }
    }

    /// Delegates to the canonical `RuleSentenceFormatter` so every rule
    /// surface renders sentences the same way. Live preview in the
    /// builder + persisted rule rows + future inbox notifications all
    /// share this one path.
    private func sentencePreview(for rule: GroupRule) -> String {
        RuleSentenceFormatter.sentence(for: rule, registry: coordinator.shapeRegistry)
    }
}

// MARK: - Modal sheet wrapper

/// Modal-chrome wrapper around `ResourceRulesBody`. Today only the
/// resource detail's ⋯ menu's "Reglas" path uses this — the Reglas tab
/// renders the body inline via `RulesSectionView` so the user gets the
/// list directly, no sub-sheet bounce.
struct ResourceRulesSheet: View {
    @Binding var isPresented: Bool
    @Bindable var coordinator: ResourceRulesCoordinator

    public init(
        isPresented: Binding<Bool>,
        coordinator: ResourceRulesCoordinator
    ) {
        self._isPresented = isPresented
        self.coordinator = coordinator
    }

    var body: some View {
        ModalSheetTemplate(
            title: "Reglas",
            dismissAction: { isPresented = false }
        ) {
            ResourceRulesBody(coordinator: coordinator)
        }
    }
}
