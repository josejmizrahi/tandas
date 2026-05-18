import Foundation
import RuulCore

/// Real `PostCreateIntentDispatcher` impl. Runs capability activation
/// through `LazyCapabilityActivator` and forwards the intent to the
/// caller's presentation closure when caps land cleanly.
///
/// Sprint 4 Phase B contract:
///   1. Call `activator.ensure(intent.requiredCapabilities, …)`.
///   2. If `outcome.failed` non-empty → throw
///      `IntentDispatchError.activationFailed(outcome.failed)`.
///   3. If outcome has skipped-unavailable caps that are also NOT
///      already-attached → throw `.capabilitiesUnavailable(…)`. (The
///      visibility resolver normally hides these intents; this is a
///      defense against the module being turned off between visibility
///      check and tap.)
///   4. Invoke `onActivated(intent, outcome)` on the main actor. The
///      screen takes the intent and presents the matching destination
///      via `.sheet(item:)`.
///
/// The dispatcher does NOT present the sheet itself — SwiftUI
/// presentation is the screen's responsibility (it owns the @State).
/// Doing both here would tangle the protocol with view-layer concerns.
public actor LivePostCreateIntentDispatcher: PostCreateIntentDispatcher {
    private let activator: LazyCapabilityActivator
    private let onActivated: @Sendable @MainActor (ResourceIntent, ActivationOutcome) -> Void

    public init(
        activator: LazyCapabilityActivator,
        onActivated: @escaping @Sendable @MainActor (ResourceIntent, ActivationOutcome) -> Void
    ) {
        self.activator = activator
        self.onActivated = onActivated
    }

    public func dispatch(
        _ intent: ResourceIntent,
        on resourceId: UUID,
        resourceType: ResourceType,
        in group: Group
    ) async throws {
        // Empty `requiredCapabilities` short-circuits to a clean outcome
        // so intents like `link_resource` / `add_rules` / `view_history`
        // dispatch immediately without a no-op activator call.
        let outcome: ActivationOutcome
        if intent.requiredCapabilities.isEmpty {
            outcome = ActivationOutcome()
        } else {
            outcome = await activator.ensure(
                intent.requiredCapabilities,
                on: resourceId,
                resourceType: resourceType,
                in: group
            )
        }

        // Hard fail: write errors. The user sees the inline banner.
        if !outcome.failed.isEmpty {
            throw IntentDispatchError.activationFailed(outcome.failed)
        }

        // Soft fail: caps that should've been activatable per the
        // visibility check are now unavailable. Race with module
        // toggle. Stay honest — surface and refuse to present.
        let stillMissing = intent.requiredCapabilities
            .subtracting(outcome.allEffective)
        if !stillMissing.isEmpty {
            throw IntentDispatchError.capabilitiesUnavailable(stillMissing)
        }

        // Hand off to the screen. MainActor hop lets the closure mutate
        // SwiftUI @State without an extra dispatch.
        await onActivated(intent, outcome)
    }
}
