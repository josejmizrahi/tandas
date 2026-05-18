import SwiftUI
import RuulUI
import RuulCore

/// Entry view for the new 3-step resource creation flow. Wraps the
/// `ResourceCreationCoordinator` state machine in a `NavigationStack`
/// + toolbar and swaps the active step view per `coordinator.phase`.
///
/// Doctrine 2026-05-18:
///   - 3 pre-create steps + 1 post-create intent screen.
///   - Capabilities never surface as toggles; the silent-attach set is
///     resolved by the coordinator from the variant + template
///     defaults at create time.
///   - The legacy `ResourceWizardSheet` remains the Advanced surface;
///     this view does not replace it — it's gated by the caller (Home
///     FAB / Group "+" entry, behind feature flag) until cutover in
///     Sprint 4.
///
/// On successful create, fires `onCreated(resourceId)` so the caller
/// can present the PostCreateIntentScreen (Sprint 4 work).
public struct ResourceCreationSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var coordinator: ResourceCreationCoordinator
    public var onCreated: ((UUID) -> Void)?

    /// Permissions the viewer holds in `group`. Used to filter the
    /// post-create intent grid. Caller is expected to resolve from
    /// `group.effectiveRoles` + `member.rawRoles` (same source
    /// `UniversalResourceDetailView.viewerPermissions()` reads).
    /// Empty set is safe — intents that need permissions stay hidden.
    public let viewerPermissions: Set<Permission>

    /// Dispatcher for tapped intents on the post-create screen.
    /// Defaults to `NoOpPostCreateIntentDispatcher` so the sheet
    /// renders + tests work without a full wiring; Phase B injects
    /// the real RuulFeatures-side dispatcher.
    public let intentDispatcher: any PostCreateIntentDispatcher

    public init(
        group: RuulCore.Group,
        builders: ResourceBuilderRegistry,
        templateDefaultsByType: [String: [String]] = [:],
        viewerPermissions: Set<Permission> = [],
        intentDispatcher: any PostCreateIntentDispatcher = NoOpPostCreateIntentDispatcher(),
        onCreated: ((UUID) -> Void)? = nil
    ) {
        _coordinator = State(initialValue: ResourceCreationCoordinator(
            group: group,
            builders: builders,
            templateDefaultsByType: templateDefaultsByType
        ))
        self.viewerPermissions = viewerPermissions
        self.intentDispatcher = intentDispatcher
        self.onCreated = onCreated
    }

    public var body: some View {
        NavigationStack {
            content
                .toolbar { toolbarContent }
                .animation(.ruulSnappy, value: phaseKey)
                .background(Color.ruulBackground.ignoresSafeArea())
        }
        .onChange(of: phaseKey) { _, _ in
            if case .postCreate(let resourceId, _) = coordinator.phase {
                onCreated?(resourceId)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch coordinator.phase {
        case .typePicker:
            ResourceTypePicker(coordinator: coordinator)
                .transition(stepTransition)
        case .variantPicker(let type):
            ResourceVariantPicker(coordinator: coordinator, type: type)
                .transition(stepTransition)
        case .identity(let type, let variant):
            MinimalIdentityForm(coordinator: coordinator, type: type, variant: variant)
                .transition(stepTransition)
        case .creating:
            creatingView
                .transition(stepTransition)
        case .postCreate(let resourceId, let variant):
            PostCreateIntentScreen(
                resourceId: resourceId,
                resourceType: variant.resourceType,
                variant: variant,
                group: coordinator.group,
                attachedCapabilities: coordinator.attachedCapabilities,
                viewerPermissions: viewerPermissions,
                dispatcher: intentDispatcher,
                onClose: { dismiss() }
            )
            .transition(stepTransition)
        case .failed:
            // Failure UI lives inline inside MinimalIdentityForm via
            // the .failed binding. The coordinator's backOneStep from
            // .failed returns to .identity preserving fields, so the
            // user keeps editing without losing input.
            MinimalIdentityForm(
                coordinator: coordinator,
                type: lastType ?? .event,
                variant: lastVariant ?? EventVariants.socialGathering
            )
            .transition(stepTransition)
        }
    }

    private var creatingView: some View {
        VStack(spacing: RuulSpacing.lg) {
            Spacer()
            ProgressView()
                .controlSize(.large)
            Text("Creando…")
                .ruulTextStyle(RuulTypography.body)
                .foregroundStyle(Color.ruulTextSecondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(RuulSpacing.xl)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            leadingButton
        }
        ToolbarItem(placement: .principal) {
            Text(toolbarTitle)
                .ruulTextStyle(RuulTypography.headline)
                .foregroundStyle(Color.ruulTextPrimary)
        }
    }

    @ViewBuilder
    private var leadingButton: some View {
        switch coordinator.phase {
        case .typePicker:
            Button("Cancelar") { dismiss() }
                .foregroundStyle(Color.ruulTextSecondary)
        case .creating, .postCreate:
            // Mid-flight + post-success: only "Cerrar" on the trailing
            // edge of the success screen itself. Leading slot stays empty
            // so users don't accidentally back out of an in-flight RPC.
            EmptyView()
        case .variantPicker, .identity, .failed:
            Button {
                coordinator.backOneStep()
            } label: {
                Image(systemName: "chevron.left")
                    .ruulTextStyle(RuulTypography.headline)
                    .foregroundStyle(Color.ruulTextSecondary)
            }
            .accessibilityLabel("Atrás")
        }
    }

    private var toolbarTitle: String {
        switch coordinator.phase {
        case .typePicker:                return "Nuevo recurso"
        case .variantPicker(let type):   return type.humanLabel
        case .identity(_, let variant):  return variant.humanName
        case .creating:                  return "Creando…"
        case .postCreate(_, let variant):return variant.humanName
        case .failed:                    return currentVariant?.humanName ?? "Nuevo recurso"
        }
    }

    // MARK: - State helpers

    /// Stable hash of the current phase used as the animation key.
    /// `Phase` itself is Equatable; we lift to an Int so SwiftUI's
    /// animation diff doesn't need to walk the variant payload.
    private var phaseKey: Int {
        switch coordinator.phase {
        case .typePicker:     return 0
        case .variantPicker:  return 1
        case .identity:       return 2
        case .creating:       return 3
        case .postCreate:     return 4
        case .failed:         return 5
        }
    }

    private var stepTransition: AnyTransition {
        .opacity.combined(with: .move(edge: .trailing))
    }

    private var currentVariant: ResourceVariant? {
        switch coordinator.phase {
        case .identity(_, let v), .postCreate(_, let v): return v
        default: return lastVariant
        }
    }

    private var lastType: ResourceType? {
        switch coordinator.phase {
        case .identity(let t, _), .variantPicker(let t): return t
        default: return nil
        }
    }

    private var lastVariant: ResourceVariant? {
        switch coordinator.phase {
        case .identity(_, let v), .postCreate(_, let v): return v
        default: return nil
        }
    }
}
