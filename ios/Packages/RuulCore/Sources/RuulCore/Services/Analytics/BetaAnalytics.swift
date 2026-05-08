import Foundation
import RuulCore

/// Beta 1 instrumentation — minimal events to answer the 6 questions in
/// `Plans/Active/Beta1.md` §4 without dragging in a heavy analytics
/// pipeline. Wraps `AnalyticsService.track(_:)` with strongly-typed
/// convenience methods that mirror the existing `EventAnalytics` pattern.
///
/// Persistence: defaults to `LogAnalyticsService` (OSLog category
/// "analytics"). During Beta you can pull the device log via Xcode →
/// Window → Devices and Simulators → View Device Logs, then filter
/// by `subsystem:com.josejmizrahi.ruul category:analytics`.
@MainActor
public struct BetaAnalytics: Sendable {
    public let analytics: any AnalyticsService

    public init(analytics: any AnalyticsService) {
        self.analytics = analytics
    }

    /// Fired each time the app moves to `.active` — the cheapest signal
    /// that "the user opened the app today". Use to compute DAU and
    /// retention curves during Beta.
    public func appOpened() async {
        await analytics.track(.appOpened)
    }

    /// Fired when a user submits a vote ballot (any vote_type).
    /// `voteType` matches `Vote.type.rawValue` so we can split fine
    /// appeals from rule changes / general proposals later.
    public func voteCast(voteId: UUID, voteType: String, choice: String) async {
        await analytics.track(.voteCast(voteId: voteId, voteType: voteType, choice: choice))
    }

    /// Fired when a user opens an appeal on one of their own fines.
    /// Pair this with `fineSeen` to estimate "of the fines a user saw,
    /// how many did they appeal?".
    public func fineAppealStarted(fineId: UUID, ruleSlug: String?) async {
        await analytics.track(.fineAppealStarted(fineId: fineId, ruleSlug: ruleSlug))
    }

    /// Fired the first time a fine detail screen renders for a given
    /// session. The `isMine` flag tells us whether the viewer is the
    /// fined party (drives appeal-rate denominator) or someone else.
    public func fineSeen(fineId: UUID, ruleSlug: String?, isMine: Bool, status: String) async {
        await analytics.track(.fineSeen(
            fineId: fineId, ruleSlug: ruleSlug, isMine: isMine, status: status
        ))
    }

    /// Fired when a user taps "pagar" on their own officialized fine.
    public func finePaid(fineId: UUID, amountMxn: Int) async {
        await analytics.track(.finePaid(fineId: fineId, amountMxn: amountMxn))
    }

    /// Fired when the user taps a push notification that opens the app.
    /// `kind` is the deep-link discriminator (event, rule, vote, fine,
    /// invite, appeal). Helps separate "useful notifs" from "noise".
    public func notificationTapped(kind: String) async {
        await analytics.track(.notificationTapped(kind: kind))
    }
}

public extension AnalyticsEvent {
    public static var appOpened: AnalyticsEvent {
        .untyped(name: "app_opened", properties: [:])
    }

    public static func voteCast(voteId: UUID, voteType: String, choice: String) -> AnalyticsEvent {
        .untyped(name: "vote_cast", properties: [
            "vote_id": .string(voteId.uuidString.lowercased()),
            "vote_type": .string(voteType),
            "choice": .string(choice)
        ])
    }

    public static func fineAppealStarted(fineId: UUID, ruleSlug: String?) -> AnalyticsEvent {
        .untyped(name: "fine_appeal_started", properties: [
            "fine_id": .string(fineId.uuidString.lowercased()),
            "rule_slug": ruleSlug.map(AnalyticsValue.string) ?? .null
        ])
    }

    public static func fineSeen(fineId: UUID, ruleSlug: String?, isMine: Bool, status: String) -> AnalyticsEvent {
        .untyped(name: "fine_seen", properties: [
            "fine_id": .string(fineId.uuidString.lowercased()),
            "rule_slug": ruleSlug.map(AnalyticsValue.string) ?? .null,
            "is_mine": .bool(isMine),
            "status": .string(status)
        ])
    }

    public static func finePaid(fineId: UUID, amountMxn: Int) -> AnalyticsEvent {
        .untyped(name: "fine_paid", properties: [
            "fine_id": .string(fineId.uuidString.lowercased()),
            "amount_mxn": .int(amountMxn)
        ])
    }

    public static func notificationTapped(kind: String) -> AnalyticsEvent {
        .untyped(name: "notification_tapped", properties: ["kind": .string(kind)])
    }
}
