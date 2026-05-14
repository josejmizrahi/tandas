import Foundation
import RuulCore

/// Identifiable wrapper for the rule-edit sheet. Carries the rule, its
/// group, an optional proposed fine amount (from a system suggestion), and
/// an optional pending action id to acknowledge once the edit completes.
public struct RuleEditRouteContext: Identifiable, Hashable, Sendable {
    public let rule: GroupRule
    public let group: RuulCore.Group
    public let proposedAmount: Int?
    public let pendingActionId: UUID?

    public init(rule: GroupRule, group: RuulCore.Group, proposedAmount: Int?, pendingActionId: UUID?) {
        self.rule = rule
        self.group = group
        self.proposedAmount = proposedAmount
        self.pendingActionId = pendingActionId
    }
    public var id: UUID { rule.id }
}

/// Identifiable wrapper for the `OpenVotesListView` push destination on
/// the groupTab stack. The id is the active group's id so SwiftUI rebuilds
/// the destination on group switch.
public struct OpenVotesRouteContext: Identifiable, Hashable, Sendable {
    public let id: UUID

    public init(id: UUID) {
        self.id = id
    }
}

/// Identifiable wrapper for the `VoteDetailView` push destination. Lives in
/// groupTab stack (vote-row tap from `OpenVotesListView`) and in homeTab stack
/// (`.votePending` from the Pendientes section). Identity is vote id.
public struct VoteDetailRouteContext: Identifiable, Hashable, Sendable {
    public let vote: Vote

    public init(vote: Vote) {
        self.vote = vote
    }
    public var id: UUID { vote.id }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(vote.id)
    }
    public static func == (lhs: VoteDetailRouteContext, rhs: VoteDetailRouteContext) -> Bool {
        lhs.vote.id == rhs.vote.id
    }
}

/// Identifiable wrapper used by `ruulSheet(item:)` when routing the
/// appellant vote screen. Carries both the Appeal and Fine so the sheet
/// can display the full context without an extra fetch.
public struct AppealRouteContext: Identifiable, Hashable, Sendable {
    public let appeal: Appeal
    public let fine: Fine

    public init(appeal: Appeal, fine: Fine) {
        self.appeal = appeal
        self.fine = fine
    }
    public var id: UUID { appeal.id }
}

// CheckInScannerCoordinator must be Identifiable for fullScreenCover(item:).
extension CheckInScannerCoordinator: Identifiable {
    public nonisolated var id: UUID { event.id }
}
