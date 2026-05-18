import SwiftUI
import RuulUI
import RuulCore

/// Step 4 of the new resource creation flow: "¿Qué quieres hacer ahora?"
///
/// Presents `variant.postCreateHeadline` and an ordered intent grid.
/// The order comes from `variant.suggestedIntents`; the filter comes
/// from `IntentVisibilityResolver`. Tapping an intent forwards to the
/// injected `PostCreateIntentDispatcher`.
///
/// Doctrine 2026-05-18: intents are the ONLY surface where caps come
/// online post-create. The screen never shows a capability toggle;
/// intents whose caps aren't available (or whose permission is
/// missing) are hidden, not greyed.
///
/// Phase A presentation: this screen ships as a standalone view that
/// any caller can present manually (after dismissing
/// `ResourceCreationSheet` on `.postCreate`). Auto-wire from inside
/// the sheet is a follow-up so the merged Sprint 1-3 PR keeps its
/// commit history clean.
public struct PostCreateIntentScreen: View {
    @Environment(\.dismiss) private var dismiss

    public let resourceId: UUID
    public let resourceType: ResourceType
    public let variant: ResourceVariant
    public let group: RuulCore.Group
    public let attachedCapabilities: Set<String>
    public let viewerPermissions: Set<Permission>
    public let dispatcher: any PostCreateIntentDispatcher

    /// Registry the screen reads intent definitions from. Defaults to
    /// the V1 catalog; tests inject mocks.
    public let intents: any ResourceIntentRegistry
    /// Visibility resolver. Defaults to the V1 catalog + resolver;
    /// tests inject mocks to assert the filter behavior.
    public let visibility: IntentVisibilityResolver

    /// Called when the user dismisses the screen via "Listo". Optional —
    /// defaults to `dismiss()` from the environment.
    public var onClose: (() -> Void)?

    public init(
        resourceId: UUID,
        resourceType: ResourceType,
        variant: ResourceVariant,
        group: RuulCore.Group,
        attachedCapabilities: Set<String>,
        viewerPermissions: Set<Permission>,
        dispatcher: any PostCreateIntentDispatcher = NoOpPostCreateIntentDispatcher(),
        intents: any ResourceIntentRegistry = DefaultResourceIntentRegistry.v1,
        visibility: IntentVisibilityResolver = IntentVisibilityResolver(),
        onClose: (() -> Void)? = nil
    ) {
        self.resourceId = resourceId
        self.resourceType = resourceType
        self.variant = variant
        self.group = group
        self.attachedCapabilities = attachedCapabilities
        self.viewerPermissions = viewerPermissions
        self.dispatcher = dispatcher
        self.intents = intents
        self.visibility = visibility
        self.onClose = onClose
    }

    @State private var inflightIntentId: String?
    @State private var dispatchError: String?

    private var ctx: IntentVisibilityContext {
        IntentVisibilityContext(
            resourceType: resourceType,
            group: group,
            attachedCapabilities: attachedCapabilities,
            viewerPermissions: viewerPermissions
        )
    }

    /// Variant.suggestedIntents mapped through the registry, then
    /// filtered by visibility. Order preserved — the variant author
    /// chose the priority of verbs ("link first for sports_match,
    /// invite_people second"), the screen honors it.
    private var visibleIntents: [ResourceIntent] {
        let resolved = variant.suggestedIntents.compactMap { intents.intent(id: $0) }
        return visibility.visible(resolved, in: ctx)
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RuulSpacing.lg) {
                successHeader
                if visibleIntents.isEmpty {
                    emptyState
                } else {
                    VStack(spacing: RuulSpacing.sm) {
                        ForEach(visibleIntents) { intent in
                            intentRow(intent)
                        }
                    }
                }
                if let dispatchError {
                    errorBanner(dispatchError)
                }
                closeButton
            }
            .padding(.horizontal, RuulSpacing.lg)
            .padding(.top, RuulSpacing.lg)
            .padding(.bottom, RuulSpacing.xxl)
        }
        // Sheet presentation lives in `PostCreateIntentScreenContainer`
        // (see `withActivator(…)` convenience init below). Callers that
        // need to drive presentation from a non-Live dispatcher should
        // wrap this view themselves and observe their dispatcher's
        // output → present whatever sheet they want.
    }

    private var successHeader: some View {
        VStack(spacing: RuulSpacing.sm) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(Color.ruulAccent)
            Text(variant.postCreateHeadline)
                .ruulTextStyle(RuulTypography.title)
                .foregroundStyle(Color.ruulTextPrimary)
                .multilineTextAlignment(.center)
            Text("Elige lo que quieras hacer. Después puedes volver al recurso.")
                .ruulTextStyle(RuulTypography.body)
                .foregroundStyle(Color.ruulTextSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, RuulSpacing.md)
    }

    private var emptyState: some View {
        VStack(spacing: RuulSpacing.sm) {
            Image(systemName: "sparkles")
                .font(RuulTypography.title.font)
                .foregroundStyle(Color.ruulTextTertiary)
            Text("Nada que configurar todavía.")
                .ruulTextStyle(RuulTypography.headline)
                .foregroundStyle(Color.ruulTextPrimary)
            Text("Lo que necesites lo activas desde el recurso.")
                .ruulTextStyle(RuulTypography.body)
                .foregroundStyle(Color.ruulTextSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(RuulSpacing.xl)
    }

    private func intentRow(_ intent: ResourceIntent) -> some View {
        Button {
            handleTap(intent)
        } label: {
            HStack(alignment: .top, spacing: RuulSpacing.md) {
                iconBadge(intent.icon)
                VStack(alignment: .leading, spacing: RuulSpacing.xxs) {
                    Text(intent.humanLabel)
                        .ruulTextStyle(RuulTypography.headline)
                        .foregroundStyle(Color.ruulTextPrimary)
                    Text(intent.summary)
                        .ruulTextStyle(RuulTypography.body)
                        .foregroundStyle(Color.ruulTextSecondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: RuulSpacing.xs)
                trailingIndicator(for: intent)
            }
            .padding(RuulSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .ruulElevation(.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.ruulPress)
        .disabled(inflightIntentId != nil)
    }

    @ViewBuilder
    private func trailingIndicator(for intent: ResourceIntent) -> some View {
        if inflightIntentId == intent.id {
            ProgressView()
                .controlSize(.small)
        } else {
            Image(systemName: "chevron.right")
                .ruulTextStyle(RuulTypography.captionBold)
                .foregroundStyle(Color.ruulTextTertiary)
        }
    }

    private func iconBadge(_ symbol: String) -> some View {
        ZStack {
            Circle()
                .fill(Color.ruulAccent.opacity(0.15))
                .frame(width: 40, height: 40)
            Image(systemName: symbol)
                .ruulTextStyle(RuulTypography.bodyLarge)
                .foregroundStyle(Color.ruulAccent)
        }
    }

    private var closeButton: some View {
        RuulButton(
            "Listo",
            style: .secondary,
            size: .large,
            fillsWidth: true,
            action: {
                if let onClose { onClose() } else { dismiss() }
            }
        )
        .padding(.top, RuulSpacing.md)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: RuulSpacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.ruulNegative)
            Text(message)
                .ruulTextStyle(RuulTypography.caption)
                .foregroundStyle(Color.ruulNegative)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(RuulSpacing.sm)
        .background(
            RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                .fill(Color.ruulNegative.opacity(0.08))
        )
    }

    // MARK: - Tap handling

    private func handleTap(_ intent: ResourceIntent) {
        guard inflightIntentId == nil else { return }
        inflightIntentId = intent.id
        dispatchError = nil
        Task {
            defer { inflightIntentId = nil }
            do {
                try await dispatcher.dispatch(
                    intent,
                    on: resourceId,
                    resourceType: resourceType,
                    in: group
                )
            } catch {
                dispatchError = error.ruulUserMessage
            }
        }
    }
}

// MARK: - Phase B convenience init

public extension PostCreateIntentScreen {
    /// Convenience init that wires up the canonical Phase B path:
    /// `LivePostCreateIntentDispatcher` running the supplied activator
    /// + this screen's internal `@State` for sheet presentation.
    /// Callers using their own dispatcher should keep using the
    /// designated init.
    ///
    /// Note: we can't write to `@State` from outside the view, so the
    /// convenience init is a static factory that returns a wrapper view
    /// holding the state. The wrapper rebuilds the dispatcher each
    /// render — cheap because it's a struct, and the activator actor
    /// is the only stateful piece.
    static func withActivator(
        resourceId: UUID,
        resourceType: ResourceType,
        variant: ResourceVariant,
        group: RuulCore.Group,
        attachedCapabilities: Set<String>,
        viewerPermissions: Set<Permission>,
        activator: LazyCapabilityActivator,
        resourceContext: PostCreateResourceContext? = nil,
        intents: any ResourceIntentRegistry = DefaultResourceIntentRegistry.v1,
        visibility: IntentVisibilityResolver = IntentVisibilityResolver(),
        onClose: (() -> Void)? = nil
    ) -> some View {
        PostCreateIntentScreenContainer(
            resourceId: resourceId,
            resourceType: resourceType,
            variant: variant,
            group: group,
            attachedCapabilities: attachedCapabilities,
            viewerPermissions: viewerPermissions,
            activator: activator,
            resourceContext: resourceContext,
            intents: intents,
            visibility: visibility,
            onClose: onClose
        )
    }
}

/// Optional context the post-create screen needs to render the wired
/// `Destination` cases (instead of the placeholder card). Callers that
/// don't pass this leave all destinations on placeholder — useful for
/// tests / previews / surfaces that just want the screen to display.
///
/// What each field unlocks:
///   - `metadata`: source of `name` + `currency` for fund-shaped
///     destinations (ContributeToFundSheet / RecordExpenseFromFundSheet)
///     and any future destination that needs resource attributes.
///   - `members`: required by RecordExpenseFromFundSheet's recipient
///     picker. Pulled from `AppState.memberDirectory` in production.
public struct PostCreateResourceContext: Sendable {
    public let metadata: [String: JSONConfig]
    public let members: [MemberWithProfile]
    /// Full ResourceRow for destinations whose sheets accept the row
    /// directly (RecordValuationSheet, CheckOutAssetSheet, …). Optional
    /// because some callers only have id + metadata at hand; those
    /// destinations fall back to placeholder when row is absent.
    public let resourceRow: ResourceRow?
    /// Caller-supplied callbacks the wired destinations invoke when
    /// they need to mutate state (assign custody, present a child
    /// wizard, …). Each closure is optional — when nil the matching
    /// destination falls back to the placeholder so the screen still
    /// renders coherently.
    ///
    /// Why callbacks instead of injecting AppState here: keeps the
    /// presenter free of repo deps and gives callers a single seam
    /// to substitute mock impls in tests/previews. Callers wire
    /// `app.assetLifecycleRepo.assignCustody(asset:to:notes:)` etc.
    public let actions: PostCreateResourceActions

    public init(
        metadata: [String: JSONConfig],
        members: [MemberWithProfile],
        resourceRow: ResourceRow? = nil,
        actions: PostCreateResourceActions = PostCreateResourceActions()
    ) {
        self.metadata = metadata
        self.members = members
        self.resourceRow = resourceRow
        self.actions = actions
    }
}

/// Async action callbacks the destinations may invoke. Caller wires
/// these from `AppState` repos (or mocks for tests). Each is optional;
/// missing closures collapse the matching destination to the
/// placeholder card.
public struct PostCreateResourceActions: Sendable {
    /// Called when `custodyAssignment` / `assignCustodyPicker`
    /// finalizes member selection. Caller forwards to
    /// `app.assetLifecycleRepo.assignCustody(asset: resourceId, to: memberId, notes: nil)`.
    public let onAssignCustody: (@Sendable (UUID) async throws -> Void)?

    /// Called when `childResourceWizard` is tapped. Caller's typical
    /// impl: dismiss the current post-create sheet and present a new
    /// ResourceCreationSheet (optionally pre-selecting `prefilledType`).
    /// Passing nil leaves the intent on the placeholder.
    public let onCreateChildResource: (@Sendable (ResourceType?) async -> Void)?

    /// Called for destinations whose target is navigation rather than a
    /// sheet (`rsvpManager` → event detail in RSVP mode, `historyTab` →
    /// switch to the History tab, etc.). Caller's typical impl: dismiss
    /// the post-create sheet, then route to the matching screen / tab.
    ///
    /// Passing nil leaves nav-shaped destinations on the placeholder.
    /// One closure handles all nav cases (vs N closures) so a single
    /// dismissal-+-routing helper covers every nav-target intent.
    public let onNavigate: (@Sendable (PostCreateNavigation) async -> Void)?

    public init(
        onAssignCustody: (@Sendable (UUID) async throws -> Void)? = nil,
        onCreateChildResource: (@Sendable (ResourceType?) async -> Void)? = nil,
        onNavigate: (@Sendable (PostCreateNavigation) async -> Void)? = nil
    ) {
        self.onAssignCustody = onAssignCustody
        self.onCreateChildResource = onCreateChildResource
        self.onNavigate = onNavigate
    }
}

/// Navigation targets for nav-shaped destinations. Each case carries
/// the data the caller needs to perform the navigation (resource id,
/// rule filter, etc.). Adding a new nav-shaped destination is one
/// case here + one DestinationPresenter branch that calls
/// `onNavigate(.matching_case)`.
public enum PostCreateNavigation: Sendable, Hashable {
    /// `rsvpManager` → resource detail, RSVP section in focus.
    case resourceDetailRSVP(resourceId: UUID)
    /// `checkInLauncher` → resource detail in check-in mode.
    case resourceDetailCheckIn(resourceId: UUID)
    /// `historyTab` → group's history surface.
    case historyTab(groupId: UUID, resourceId: UUID?)
    /// `moneyTab` → group's money surface (defaults to the just-created
    /// resource if relevant — e.g. fund created → money tab focused on
    /// that fund's balance).
    case moneyTab(groupId: UUID, resourceId: UUID?)
    /// `governanceRuleEditor` → group governance editor.
    case governanceRuleEditor(groupId: UUID)
    /// `ruleTemplatePicker` → universal templates picker filtered by
    /// category. Caller decides presentation (sheet vs push).
    case ruleTemplatePicker(category: Destination.RuleCategoryFilter?,
                            resourceId: UUID)
}

/// Owner of the `presentedIntent` @State that the live dispatcher's
/// callback writes into. Internal — callers use
/// `PostCreateIntentScreen.withActivator(…)` which returns this.
private struct PostCreateIntentScreenContainer: View {
    let resourceId: UUID
    let resourceType: ResourceType
    let variant: ResourceVariant
    let group: RuulCore.Group
    let attachedCapabilities: Set<String>
    let viewerPermissions: Set<Permission>
    let activator: LazyCapabilityActivator
    let resourceContext: PostCreateResourceContext?
    let intents: any ResourceIntentRegistry
    let visibility: IntentVisibilityResolver
    let onClose: (() -> Void)?

    @State private var presentedIntent: PresentedIntent?

    var body: some View {
        // Dispatcher is constructed per-render. Cheap (actor closure),
        // and pulls in the @State writer that owns the sheet binding.
        let dispatcher = LivePostCreateIntentDispatcher(
            activator: activator,
            onActivated: { intent, _ in
                presentedIntent = PresentedIntent(intent: intent)
            }
        )
        return PostCreateIntentScreen(
            resourceId: resourceId,
            resourceType: resourceType,
            variant: variant,
            group: group,
            attachedCapabilities: attachedCapabilities,
            viewerPermissions: viewerPermissions,
            dispatcher: dispatcher,
            intents: intents,
            visibility: visibility,
            onClose: onClose
        )
        .sheet(item: $presentedIntent) { wrapped in
            DestinationPresenter(
                intent: wrapped.intent,
                resourceId: resourceId,
                groupId: group.id,
                resourceContext: resourceContext,
                onClose: { presentedIntent = nil }
            )
        }
    }
}

// MARK: - Sheet payload + destination renderer

/// `.sheet(item:)` requires Identifiable. Wraps the tapped intent so
/// the same intent dispatched twice still re-presents (id changes via
/// UUID — SwiftUI keys the sheet's identity on this).
struct PresentedIntent: Identifiable {
    let id = UUID()
    let intent: ResourceIntent
}

/// Renders the matching view for an intent's `Destination`. Wires the
/// destinations that have an existing sheet impl + are commonly used
/// across the 5 founder validation cases. Unwired cases fall through
/// to a placeholder card with intent-specific copy.
///
/// Doctrine: every Destination case has a renderer — never a `default:
/// EmptyView()`. Taps must never dead-end silently.
///
/// Currently wired (B.2 in progress):
///   Sheet-presenting:
///   - `linkPicker` → `LinkResourcePickerSheet`
///   - `ledgerEntryForm(.credit)` → `ContributeToFundSheet`
///   - `ledgerEntryForm(.debit)` → `RecordExpenseFromFundSheet`
///   - `valuationForm` / `recordValuationSheet` → `RecordValuationSheet`
///   - `custodyAssignment` / `assignCustodyPicker` → `MemberPickerSheet`
///     (caller wires the assign callback via
///     `PostCreateResourceActions.onAssignCustody`)
///   - `childResourceWizard` → caller-driven (e.g. dismiss current
///     sheet + present a fresh `ResourceCreationSheet`) via
///     `PostCreateResourceActions.onCreateChildResource`
///
///   Navigation-targeting (call `onNavigate(.matching_case)` →
///   caller dismisses sheet + routes):
///   - `rsvpManager` → `.resourceDetailRSVP`
///   - `checkInLauncher` → `.resourceDetailCheckIn`
///   - `historyTab` → `.historyTab`
///   - `moneyTab` → `.moneyTab`
///   - `governanceRuleEditor` → `.governanceRuleEditor`
///   - `ruleTemplatePicker(category)` → `.ruleTemplatePicker(category)`
///
/// Wired destinations require `resourceContext`. When the context is
/// nil (tests, previews, callers that opted out), they fall back to
/// the placeholder so the screen still renders coherently.
private struct DestinationPresenter: View {
    let intent: ResourceIntent
    let resourceId: UUID
    let groupId: UUID
    let resourceContext: PostCreateResourceContext?
    let onClose: () -> Void

    var body: some View {
        switch intent.destination {
        case .linkPicker:
            LinkResourcePickerSheet(
                eventId: resourceId,
                groupId: groupId,
                alreadyLinkedIds: [],
                onLinked: { _ in onClose() }
            )

        case .ledgerEntryForm(let prefill):
            if let ctx = resourceContext {
                ledgerSheet(prefill: prefill, ctx: ctx)
            } else {
                placeholder
            }

        case .valuationForm, .recordValuationSheet:
            // Both cases route to the same sheet — `.valuationForm` is
            // the post-create navigation flavor, `.recordValuationSheet`
            // is the toolbar action flavor. Mirrors the toolbar's
            // dispatcher pattern in UniversalResourceDetailView.
            if let row = resourceContext?.resourceRow {
                RecordValuationSheet(
                    asset: row,
                    onSubmitted: onClose
                )
            } else {
                placeholder
            }

        case .custodyAssignment, .assignCustodyPicker:
            // Member picker → caller's onAssignCustody callback runs
            // the RPC. Same shape the UniversalResourceDetailView
            // toolbar uses. Members list comes from
            // resourceContext.members so the picker reflects the
            // group's directory state, not stale data.
            if let ctx = resourceContext,
               let onAssign = ctx.actions.onAssignCustody {
                NavigationStack {
                    MemberPickerSheet(
                        members: ctx.members,
                        title: "Asignar custodia"
                    ) { memberId in
                        Task {
                            do { try await onAssign(memberId) }
                            catch { /* caller surfaces via mutation hook */ }
                            onClose()
                        }
                    }
                }
            } else {
                placeholder
            }

        case .childResourceWizard(let prefilledType):
            // Caller decides what to do (typically: dismiss this sheet,
            // present a new ResourceCreationSheet starting at the
            // prefilled type). DestinationPresenter doesn't try to
            // construct a recursive sheet itself because the builders
            // + activator + template defaults aren't threaded through
            // this struct — keeping them out avoids dragging app-wide
            // deps into the presenter.
            if let onCreate = resourceContext?.actions.onCreateChildResource {
                childWizardLauncher(prefilledType: prefilledType, onCreate: onCreate)
            } else {
                placeholder
            }

        // Nav-shaped destinations — caller's `onNavigate` closure
        // dismisses this sheet and routes to the matching surface.
        // Each shows a brief loading flash so the tap registers
        // visually before the parent surface takes over.
        case .rsvpManager:
            navLauncher(.resourceDetailRSVP(resourceId: resourceId))
        case .checkInLauncher:
            navLauncher(.resourceDetailCheckIn(resourceId: resourceId))
        case .historyTab:
            navLauncher(.historyTab(groupId: groupId, resourceId: resourceId))
        case .moneyTab:
            navLauncher(.moneyTab(groupId: groupId, resourceId: resourceId))
        case .governanceRuleEditor:
            navLauncher(.governanceRuleEditor(groupId: groupId))
        case .ruleTemplatePicker(let category):
            navLauncher(.ruleTemplatePicker(category: category, resourceId: resourceId))

        default:
            placeholder
        }
    }

    /// Brief loading flash → caller's `onNavigate` resolves the route.
    /// Falls back to placeholder when `onNavigate` is nil so the user
    /// still sees a card instead of an instant dismissal that hides
    /// the tap.
    @ViewBuilder
    private func navLauncher(_ target: PostCreateNavigation) -> some View {
        if let onNavigate = resourceContext?.actions.onNavigate {
            VStack(spacing: RuulSpacing.lg) {
                ProgressView()
                    .controlSize(.large)
                Text("Abriendo…")
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(RuulSpacing.xl)
            .task {
                await onNavigate(target)
                onClose()
            }
        } else {
            placeholder
        }
    }

    /// One-shot launcher card for `childResourceWizard`. Shown briefly
    /// while we invoke the caller's `onCreateChildResource`; the caller
    /// typically dismisses this sheet immediately and presents the
    /// child wizard, so the user only ever sees a flash.
    @ViewBuilder
    private func childWizardLauncher(
        prefilledType: ResourceType?,
        onCreate: @escaping @Sendable (ResourceType?) async -> Void
    ) -> some View {
        VStack(spacing: RuulSpacing.lg) {
            ProgressView()
                .controlSize(.large)
            Text("Abriendo…")
                .ruulTextStyle(RuulTypography.body)
                .foregroundStyle(Color.ruulTextSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(RuulSpacing.xl)
        .task {
            await onCreate(prefilledType)
            onClose()
        }
    }

    @ViewBuilder
    private func ledgerSheet(
        prefill: Destination.LedgerPrefill?,
        ctx: PostCreateResourceContext
    ) -> some View {
        let name = ctx.metadata["name"]?.stringValue ?? "Fondo"
        let currency = ctx.metadata["currency"]?.stringValue ?? "MXN"
        switch prefill {
        case .credit, nil:
            // Credit = aportación. Nil treated as credit because the
            // standard "money in" verb is the more common entry point;
            // callers wanting a debit explicitly pass .debit.
            ContributeToFundSheet(
                fundId: resourceId,
                fundName: name,
                currency: currency,
                onDidContribute: onClose
            )
        case .debit:
            RecordExpenseFromFundSheet(
                fundId: resourceId,
                fundName: name,
                currency: currency,
                members: ctx.members,
                onDidRecord: onClose
            )
        }
    }

    /// Placeholder card for not-yet-wired destinations + cases where
    /// resourceContext is required but absent.
    private var placeholder: some View {
        VStack(spacing: RuulSpacing.lg) {
            Image(systemName: intent.icon)
                .font(.system(size: 48, weight: .semibold))
                .foregroundStyle(Color.ruulAccent)
            Text(intent.humanLabel)
                .ruulTextStyle(RuulTypography.title)
                .foregroundStyle(Color.ruulTextPrimary)
            Text(placeholderCopy)
                .ruulTextStyle(RuulTypography.body)
                .foregroundStyle(Color.ruulTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, RuulSpacing.lg)
            RuulButton(
                "Cerrar",
                style: .primary,
                size: .large,
                fillsWidth: true,
                action: onClose
            )
        }
        .padding(RuulSpacing.xl)
        .presentationDetents([.medium])
    }

    /// Copy shown for destinations that don't have a wired renderer
    /// yet. Pulls `firstRunCopy` when set (already founder-voiced);
    /// otherwise generic "próximamente".
    private var placeholderCopy: String {
        if !intent.firstRunCopy.isEmpty {
            return "\(intent.firstRunCopy)\n\n(Esta pantalla llega en la siguiente iteración.)"
        }
        return "Esta acción llega en la siguiente iteración."
    }
}
