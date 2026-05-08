import Foundation

/// Event-layer-specific analytics. Wraps `AnalyticsService.track(_:)` with
/// strongly-typed convenience methods so call sites don't construct the
/// AnalyticsEvent enum directly. Designed to be a thin extension layer on
/// top of the existing service from onboarding.
@MainActor
public struct EventAnalytics: Sendable {
    public let analytics: any AnalyticsService

    public init(analytics: any AnalyticsService) {
        self.analytics = analytics
    }

    public func eventCreated(
        groupId: UUID, hasLocation: Bool, hasDescription: Bool,
        applyRules: Bool, hostAssigned: Bool, recurrence: RecurrenceOption
    ) async {
        await analytics.track(.eventCreated(
            groupId: groupId,
            hasLocation: hasLocation,
            hasDescription: hasDescription,
            applyRules: applyRules,
            hostAssigned: hostAssigned,
            recurrenceOption: recurrence.rawValue
        ))
    }

    public func eventCreateStarted() async {
        await analytics.track(.eventCreateStarted)
    }

    public func eventCreateAbandoned(timeMs: Int) async {
        await analytics.track(.eventCreateAbandoned(timeOnFormMs: timeMs))
    }

    public func rsvpChanged(eventId: UUID, from: RSVPStatus, to: RSVPStatus, hoursToEvent: Int) async {
        await analytics.track(.rsvpChanged(
            eventId: eventId, fromStatus: from.rawValue, toStatus: to.rawValue,
            timeToEventHours: hoursToEvent
        ))
    }

    public func checkIn(eventId: UUID, method: CheckInMethod, locationVerified: Bool) async {
        await analytics.track(.checkIn(
            eventId: eventId, method: method.rawValue, locationVerified: locationVerified
        ))
    }

    public func walletPassAdded(eventId: UUID) async {
        await analytics.track(.walletPassAdded(eventId: eventId))
    }

    public func eventCancelled(eventId: UUID, by: CancelledBy, hasReason: Bool) async {
        await analytics.track(.eventCancelled(eventId: eventId, by: by.rawValue, reasonProvided: hasReason))
    }

    public enum CancelledBy: String { case host, system }

    public func hostReminderSent(eventId: UUID, recipientCount: Int) async {
        await analytics.track(.hostReminderSent(eventId: eventId, recipientCount: recipientCount))
    }

    public func eventView(eventId: UUID, viewerRole: ViewerRole) async {
        await analytics.track(.eventView(eventId: eventId, viewerRole: viewerRole.rawValue))
    }

    public enum ViewerRole: String { case host, guestRole = "guest" }

    public func qrScannerOpened() async {
        await analytics.track(.qrScannerOpened)
    }

    public func qrScanSuccess() async {
        await analytics.track(.qrScanSuccess)
    }

    public func qrScanFailure(reason: QRFailureReason) async {
        await analytics.track(.qrScanFailure(reason: reason.rawValue))
    }

    public enum QRFailureReason: String { case invalidSignature = "invalid_signature", alreadyCheckedIn = "already_checked_in", unknown }

    public func autoGenerationToggled(enabled: Bool) async {
        await analytics.track(enabled ? .autoGenerationEnabled : .autoGenerationDisabled)
    }
}

// Extend the AnalyticsEvent enum with event-layer cases.
public extension AnalyticsEvent {
    public static func eventCreated(groupId: UUID, hasLocation: Bool, hasDescription: Bool, applyRules: Bool, hostAssigned: Bool, recurrenceOption: String) -> AnalyticsEvent {
        .untyped(name: "event_created", properties: [
            "group_id": .string(groupId.uuidString.lowercased()),
            "has_location": .bool(hasLocation),
            "has_description": .bool(hasDescription),
            "apply_rules": .bool(applyRules),
            "host_assigned": .bool(hostAssigned),
            "recurrence_option": .string(recurrenceOption)
        ])
    }

    public static var eventCreateStarted: AnalyticsEvent {
        .untyped(name: "event_create_started", properties: [:])
    }

    public static func eventCreateAbandoned(timeOnFormMs: Int) -> AnalyticsEvent {
        .untyped(name: "event_create_abandoned", properties: ["time_on_form_ms": .int(timeOnFormMs)])
    }

    public static func rsvpChanged(eventId: UUID, fromStatus: String, toStatus: String, timeToEventHours: Int) -> AnalyticsEvent {
        .untyped(name: "rsvp_changed", properties: [
            "event_id": .string(eventId.uuidString.lowercased()),
            "from_status": .string(fromStatus),
            "to_status": .string(toStatus),
            "time_to_event_hours": .int(timeToEventHours)
        ])
    }

    public static func checkIn(eventId: UUID, method: String, locationVerified: Bool) -> AnalyticsEvent {
        .untyped(name: "check_in", properties: [
            "event_id": .string(eventId.uuidString.lowercased()),
            "method": .string(method),
            "location_verified": .bool(locationVerified)
        ])
    }

    public static func walletPassAdded(eventId: UUID) -> AnalyticsEvent {
        .untyped(name: "wallet_pass_added", properties: ["event_id": .string(eventId.uuidString.lowercased())])
    }

    public static func eventCancelled(eventId: UUID, by: String, reasonProvided: Bool) -> AnalyticsEvent {
        .untyped(name: "event_cancelled", properties: [
            "event_id": .string(eventId.uuidString.lowercased()),
            "by": .string(by),
            "reason_provided": .bool(reasonProvided)
        ])
    }

    public static func hostReminderSent(eventId: UUID, recipientCount: Int) -> AnalyticsEvent {
        .untyped(name: "host_reminder_sent", properties: [
            "event_id": .string(eventId.uuidString.lowercased()),
            "recipient_count": .int(recipientCount)
        ])
    }

    public static func eventView(eventId: UUID, viewerRole: String) -> AnalyticsEvent {
        .untyped(name: "event_view", properties: [
            "event_id": .string(eventId.uuidString.lowercased()),
            "viewer_role": .string(viewerRole)
        ])
    }

    public static var qrScannerOpened: AnalyticsEvent { .untyped(name: "qr_scanner_opened", properties: [:]) }
    public static var qrScanSuccess: AnalyticsEvent { .untyped(name: "qr_scan_success", properties: [:]) }
    public static func qrScanFailure(reason: String) -> AnalyticsEvent {
        .untyped(name: "qr_scan_failure", properties: ["reason": .string(reason)])
    }
    public static var autoGenerationEnabled: AnalyticsEvent { .untyped(name: "auto_generation_enabled", properties: [:]) }
    public static var autoGenerationDisabled: AnalyticsEvent { .untyped(name: "auto_generation_disabled", properties: [:]) }
}
