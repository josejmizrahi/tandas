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
