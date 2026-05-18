import Foundation

/// Routes a tapped `ResourceIntent` to its concrete destination
/// (sheet, form, navigation push). Activation of any missing
/// `requiredCapabilities` happens BEFORE the destination is shown,
/// via the injected `LazyCapabilityActivator`.
///
/// Sprint 4 Phase A ships the protocol + a no-op default. Phase B
/// adds the real implementation that maps each `Destination` to its
/// existing screen (ledger composer, link picker, rule template
/// picker, etc.) and is owned by RuulFeatures.
///
/// Why split: Phase A keeps the dispatcher behind a protocol so the
/// post-create screen can ship + be tested without wiring every
/// destination first. Each destination wire-up has its own surface
/// (some need RuulFeatures-only types like RuulCoordinator
/// presenters), so binding them all at once would balloon Sprint 4.
public protocol PostCreateIntentDispatcher: Sendable {
    /// Handle a tapped intent. Implementations should:
    ///   1. If intent.activation == .primerSheet, present the primer
    ///      and wait for user confirm/cancel.
    ///   2. Call LazyCapabilityActivator.ensure for
    ///      intent.requiredCapabilities. Surface the activation
    ///      outcome (skipped/failed) inline if it blocks the
    ///      destination from being honest.
    ///   3. Route to the matching `Destination`.
    ///
    /// Async + throwing: activation can fail; the screen catches and
    /// stays mounted so the user can pick a different intent.
    func dispatch(
        _ intent: ResourceIntent,
        on resourceId: UUID,
        resourceType: ResourceType,
        in group: Group
    ) async throws
}

/// No-op default. Used by previews + Sprint 4 Phase A tests +
/// callers that just want the screen to render without acting on
/// taps yet. Phase B replaces this with the RuulFeatures-side
/// dispatcher that drives the navigation stack + presents sheets.
public struct NoOpPostCreateIntentDispatcher: PostCreateIntentDispatcher {
    public init() {}
    public func dispatch(
        _ intent: ResourceIntent,
        on resourceId: UUID,
        resourceType: ResourceType,
        in group: Group
    ) async throws {
        // Intentionally empty.
    }
}
