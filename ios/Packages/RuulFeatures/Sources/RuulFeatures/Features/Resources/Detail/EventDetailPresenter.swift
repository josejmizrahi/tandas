import SwiftUI
import Foundation
import RuulCore

/// UI-side companion to `EventInteractor`. The interactor owns domain
/// state + mutations; the presenter owns the closures that route taps
/// to sheets / scanners / share / wallet flows whose ownership lives at
/// the outer shell (RootShell). Separating the two keeps capability
/// sections free of presentation plumbing while still giving them the
/// hooks they need.
///
/// Injected via `\.eventDetailPresenter` so optional fields collapse to
/// no-op closures and the sections can call them unconditionally. The
/// `Optional` env value (`nil` when no presenter is provided) drives the
/// section's "should I show this CTA?" gates.
///
/// MainActor-isolated because every closure runs in SwiftUI's UI context.
@MainActor
public struct EventDetailPresenter {
    /// Open the share sheet for the event.
    public var onPresentShareSheet: () -> Void
    /// Open the member-personal QR sheet (used by attendees to show
    /// their pass at the door).
    public var onPresentMemberQR: () -> Void
    /// Wallet pass generation + add-to-wallet flow.
    public var onAddToWallet: () -> Void
    /// Open the host-side check-in scanner.
    public var onPresentScanner: () -> Void
    /// Open the manual fine creation sheet.
    public var onPresentManualFineSheet: () -> Void
    /// Open the host "remind pending attendees" sheet.
    public var onPresentRemindAttendeesSheet: () -> Void
    /// Open the host "cancel event" sheet.
    public var onPresentCancelEventSheet: () -> Void
    /// Open the host "close event" sheet.
    public var onPresentCloseEventSheet: () -> Void
    /// Open the guest "cancel my attendance" sheet.
    public var onPresentCancelAttendanceSheet: () -> Void
    /// Push the event edit flow.
    public var onPresentEditEvent: () -> Void
    /// Open the full per-status attendee list (tally + rolls). Triggered
    /// by the "Ver todos" affordance on the home avatar strip.
    public var onPresentAttendeesList: () -> Void
    /// Async-resolved governance check. The outer shell sets this to true
    /// only when the viewer can issue a manual fine for this event; the
    /// HostActionsSection hides the CTA otherwise.
    public var canIssueManualFine: Bool

    public init(
        onPresentShareSheet: @escaping () -> Void = {},
        onPresentMemberQR: @escaping () -> Void = {},
        onAddToWallet: @escaping () -> Void = {},
        onPresentScanner: @escaping () -> Void = {},
        onPresentManualFineSheet: @escaping () -> Void = {},
        onPresentRemindAttendeesSheet: @escaping () -> Void = {},
        onPresentCancelEventSheet: @escaping () -> Void = {},
        onPresentCloseEventSheet: @escaping () -> Void = {},
        onPresentCancelAttendanceSheet: @escaping () -> Void = {},
        onPresentEditEvent: @escaping () -> Void = {},
        onPresentAttendeesList: @escaping () -> Void = {},
        canIssueManualFine: Bool = false
    ) {
        self.onPresentShareSheet = onPresentShareSheet
        self.onPresentMemberQR = onPresentMemberQR
        self.onAddToWallet = onAddToWallet
        self.onPresentScanner = onPresentScanner
        self.onPresentManualFineSheet = onPresentManualFineSheet
        self.onPresentRemindAttendeesSheet = onPresentRemindAttendeesSheet
        self.onPresentCancelEventSheet = onPresentCancelEventSheet
        self.onPresentCloseEventSheet = onPresentCloseEventSheet
        self.onPresentCancelAttendanceSheet = onPresentCancelAttendanceSheet
        self.onPresentEditEvent = onPresentEditEvent
        self.onPresentAttendeesList = onPresentAttendeesList
        self.canIssueManualFine = canIssueManualFine
    }
}

public extension EnvironmentValues {
    /// Optional event presenter scoped to the current detail page. When
    /// nil, capability sections gated on event affordances render in
    /// read-only mode (no Wallet/QR/Scanner/Manual fine CTAs).
    @Entry var eventDetailPresenter: EventDetailPresenter? = nil
}
