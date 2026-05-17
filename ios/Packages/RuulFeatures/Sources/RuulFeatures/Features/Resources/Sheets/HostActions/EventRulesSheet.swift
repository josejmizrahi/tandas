import SwiftUI
import RuulUI
import RuulCore

/// Rules surface for a single event. Per founder framing 2026-05-10
/// rules cascade across 5 scope levels and the user looking at an event
/// must see what applies, not just what was authored at the event level.
/// This sheet renders three sections in specificity order:
///
///   1. "De este evento"  — rules.resource_id = event.id
///   2. "De la serie"     — rules.series_id   = event's series
///   3. "Del grupo"       — group-scoped rules (includes platform defaults)
///
/// Only "De este evento" rules are editable from here; the inherited
/// sections render with a "Heredada" chip and a softer visual treatment
/// so the user understands they need to navigate to the source scope to
/// change them. Tap → navigation to source = future R4 work.
// File name kept for git continuity; the type is the generic
// `ResourceRulesSheet` that handles any Resource — event, asset, fund,
// etc.
struct ResourceRulesSheet: View {
    @Binding var isPresented: Bool
    @Bindable var coordinator: ResourceRulesCoordinator
    @Environment(AppState.self) private var app

    /// Rule Composer presentation handle. Non-nil when admin opens the "+"
    /// button to create a resource-scoped rule via free composition.
    /// Replaces the previous template-gallery wizard (mig 00245 sibling):
    /// templates can now be loaded inside the composer as starting points
    /// rather than being the only path.
    @State private var composerCoord: RuleComposerCoordinator?

    public init(
        isPresented: Binding<Bool>,
        coordinator: ResourceRulesCoordinator
    ) {
        self._isPresented = isPresented
        self.coordinator = coordinator
    }

    var body: some View {
        ModalSheetTemplate(
            title: "Reglas del evento",
            dismissAction: { isPresented = false }
        ) {
            if coordinator.isLoading && coordinator.rules.isEmpty {
                RuulLoadingState()
                    .frame(maxWidth: .infinity, minHeight: 200)
            } else if coordinator.rules.isEmpty {
                EmptyStateView(
                    systemImage: "list.bullet.clipboard",
                    title: "Sin reglas aplicables",
                    message: coordinator.canCreate
                        ? "Agrega reglas que sólo apliquen a este evento. Las del grupo seguirán aplicando."
                        // W2-C4: "host" → "anfitrión".
                        : "Sólo el anfitrión o un admin pueden crear reglas específicas para este evento."
                )
                .padding(.vertical, RuulSpacing.md)
            } else {
                scopeSection(
                    title: "DE ESTE EVENTO",
                    hint: "Específicas a esta cena. Sobrescriben las heredadas.",
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
                        .ruulTextStyle(RuulTypography.sectionLabel)
                        .foregroundStyle(Color.ruulTextTertiary)
                    Spacer()
                    Text("\(rules.count)")
                        .ruulTextStyle(RuulTypography.footnote)
                        .foregroundStyle(Color.ruulTextTertiary)
                        .monospacedDigit()
                }
                Text(hint)
                    .ruulTextStyle(RuulTypography.footnote)
                    .foregroundStyle(Color.ruulTextTertiary)
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
        let fineAmount = rule.amountMXN
        return VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            HStack(spacing: RuulSpacing.sm) {
                ZStack {
                    Circle()
                        .fill(Color.ruulAccent.opacity(isInherited ? 0.06 : 0.12))
                        .frame(width: 32, height: 32)
                    Image(systemName: "list.bullet.clipboard.fill")
                        .ruulTextStyle(RuulTypography.calloutRegular)
                        .foregroundStyle(isInherited ? Color.ruulTextSecondary : Color.ruulAccent)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: RuulSpacing.xs) {
                        Text(rule.name)
                            .ruulTextStyle(RuulTypography.body)
                            .foregroundStyle(isInherited ? Color.ruulTextSecondary : Color.ruulTextPrimary)
                            .lineLimit(2)
                        if isInherited {
                            Text(badgeText(for: rule.scope))
                                .ruulTextStyle(RuulTypography.footnote)
                                .foregroundStyle(Color.ruulTextTertiary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule().fill(Color.ruulAccentMuted)
                                )
                        }
                    }
                    Text(triggerLabel)
                        .ruulTextStyle(RuulTypography.caption)
                        .foregroundStyle(Color.ruulTextSecondary)
                        .lineLimit(2)
                }
                Spacer()
                if let amount = fineAmount {
                    Text("$\(amount)")
                        .ruulTextStyle(RuulTypography.body)
                        .foregroundStyle(isInherited ? Color.ruulTextSecondary : Color.ruulTextPrimary)
                        .monospacedDigit()
                }
            }
        }
        .padding(.horizontal, RuulSpacing.md)
        .padding(.vertical, RuulSpacing.sm)
        .background(Color.ruulBackgroundCanvas, in: RoundedRectangle(cornerRadius: RuulRadius.medium))
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.medium)
                .stroke(Color.ruulSeparator, lineWidth: 0.5)
        )
        .opacity(isInherited ? 0.85 : 1.0)
    }

    private var addRuleCTA: some View {
        RuulButton(
            "Agregar regla para este evento",
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
        case .resource:   return "Evento"
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
