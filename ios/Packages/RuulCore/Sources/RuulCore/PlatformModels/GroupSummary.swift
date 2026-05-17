import Foundation

/// Aggregated stats for a group, computed from existing projections.
/// Sendable + Hashable so SwiftUI can diff it cheaply.
public struct GroupSummary: Sendable, Hashable, Codable {
    public let memberCount: Int
    public let upcomingEventsCount: Int
    public let myBalanceCents: Int64
    public let myBalanceCurrency: String
    public let pendingFinesCount: Int
    public let pendingFinesOutstandingCents: Int64
    public let openVotesCount: Int
    public let pendingActionsCount: Int

    public init(
        memberCount: Int,
        upcomingEventsCount: Int,
        myBalanceCents: Int64,
        myBalanceCurrency: String,
        pendingFinesCount: Int,
        pendingFinesOutstandingCents: Int64,
        openVotesCount: Int,
        pendingActionsCount: Int
    ) {
        self.memberCount = memberCount
        self.upcomingEventsCount = upcomingEventsCount
        self.myBalanceCents = myBalanceCents
        self.myBalanceCurrency = myBalanceCurrency
        self.pendingFinesCount = pendingFinesCount
        self.pendingFinesOutstandingCents = pendingFinesOutstandingCents
        self.openVotesCount = openVotesCount
        self.pendingActionsCount = pendingActionsCount
    }

    public static let empty = GroupSummary(
        memberCount: 0,
        upcomingEventsCount: 0,
        myBalanceCents: 0,
        myBalanceCurrency: "MXN",
        pendingFinesCount: 0,
        pendingFinesOutstandingCents: 0,
        openVotesCount: 0,
        pendingActionsCount: 0
    )
}
