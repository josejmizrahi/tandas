import Foundation
import Observation
import SwiftUI
import RuulCore

/// Observable surface that capability sections gated for events read via
/// SwiftUI environment. Decouples the universal detail page from the
/// concrete `EventDetailCoordinator` so additional resource-shaped
/// interactors (slot, booking, fund, …) can be injected the same way
/// without leaking event-specific fields into `ResourceDetailContext`.
///
/// State exposed here is read-only from the section's perspective; the
/// mutation methods cover everything events surface in the polymorphic
/// detail (RSVP intent, check-in, host actions). UI-side presentation
/// hooks (open scanner, open share sheet, etc.) ride on the outer
/// `ResourceDetailContext` callbacks — keeps the interactor focused on
/// state + domain mutations.
///
/// Conforms via `Observable` (the marker protocol from `Observation`).
/// Conforming types adopt `@Observable` so property reads through the
/// existential continue to register with the observation tracker.
@MainActor
public protocol EventInteractor: AnyObject, Observable {
    // MARK: Observable state

    var event: Event { get }
    var rsvps: [RSVP] { get }
    var myRSVP: RSVP? { get }
    var viewerIsHost: Bool { get }
    var isMutating: Bool { get }
    var walletAvailable: Bool { get }

    // MARK: RSVP intent

    func setRSVP(_ status: RSVPStatus, plusOnes: Int, reason: String?) async

    // MARK: Check-in

    func selfCheckIn(locationVerified: Bool) async
    func hostMarkCheckIn(memberId: UUID) async

    // MARK: Host actions

    func sendHostReminders() async -> Int
    func cancelEvent(reason: String?) async
    func closeEvent(autoGenerateEnabled: Bool) async
    /// Reverses close/cancel. UI exposes this only when status is
    /// `.closed` or `.cancelled`. Server enforces host-or-manageEvents
    /// permission via mig 00295's `reopen_event` RPC.
    func reopenEvent() async
    func toggleAutoGenerate(_ enabled: Bool) async
    func promoteFromWaitlist() async
    func generateWalletPass() async -> URL?
}

public extension EnvironmentValues {
    /// Optional event interactor scoped to the current detail page.
    /// `nil` means the surrounding view hasn't injected one — sections
    /// must degrade gracefully (read-only state, hide mutating CTAs).
    @Entry var eventInteractor: (any EventInteractor)? = nil
}
