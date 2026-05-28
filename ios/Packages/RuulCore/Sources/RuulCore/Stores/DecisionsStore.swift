import Foundation
import Observation

/// `@MainActor` store for Primitiva 16 (Decisions / Voting). Holds two
/// concurrent buckets (open + history), an in-flight detail cache, and
/// drives the propose + vote sheets through draft state. Mutations are
/// followed by a targeted refresh so the list rows reflect the new
/// tally / status without re-fetching everything.
@MainActor
@Observable
public final class DecisionsStore {
    public private(set) var open: [GroupDecisionSummary] = []
    public private(set) var history: [GroupDecisionSummary] = []
    public private(set) var phase: StorePhase = .idle
    public private(set) var errorMessage: String?

    /// Selected detail (populated when `loadDetail(...)` resolves).
    public private(set) var detail: GroupDecisionDetail?
    public private(set) var detailPhase: StorePhase = .idle
    public private(set) var detailErrorMessage: String?

    // MARK: - Propose draft

    public var isProposePresented: Bool = false
    public var draftTitle: String = ""
    public var draftBody: String = ""
    public var draftMethod: DecisionMethod = .majority {
        didSet {
            if draftLegitimacyAutoSync {
                isInternallySettingLegitimacy = true
                draftLegitimacySource = LegitimacySource.defaultFor(method: draftMethod)
                isInternallySettingLegitimacy = false
            }
        }
    }
    /// V2-G1 — independent from `draftMethod`. Defaults track the method
    /// via `LegitimacySource.defaultFor(...)` until the user picks one
    /// explicitly; from that point on we honor their choice.
    public var draftLegitimacySource: LegitimacySource = .majority {
        didSet {
            // Only an external (user-driven) write flips the auto-sync
            // flag off; programmatic syncs from `draftMethod`'s didSet
            // are gated by `isInternallySettingLegitimacy`.
            if !isInternallySettingLegitimacy {
                draftLegitimacyAutoSync = false
            }
        }
    }
    /// Internal flag: while true, changing `draftMethod` re-syncs the
    /// legitimacy source to a sensible default. Flips to false as soon
    /// as the proposer touches the legitimacy picker. Reset on
    /// `beginProposing` / `clearDraft`.
    private var draftLegitimacyAutoSync: Bool = true
    /// Guards re-entrant updates from method→legitimacy auto-sync so
    /// the legitimacy didSet doesn't disable auto-sync.
    private var isInternallySettingLegitimacy: Bool = false
    public var draftType: DecisionType = .proposal
    public var draftOptions: [DraftOption] = []
    public private(set) var draftErrorMessage: String?

    public struct DraftOption: Identifiable, Equatable, Sendable {
        public let id: UUID
        public var label: String
        public init(id: UUID = UUID(), label: String = "") {
            self.id = id
            self.label = label
        }
    }

    // MARK: - Vote draft

    public var isVotePresented: Bool = false
    public var voteDraftDecisionId: UUID?
    public var voteDraftValue: VoteValue = .yes
    public var voteDraftOptionId: UUID?
    public var voteDraftReason: String = ""
    public private(set) var voteDraftErrorMessage: String?

    // MARK: - Storage

    private let repository: CanonicalDecisionsRepository
    private var loadedGroupId: UUID?

    // V2-A1 — realtime listener handle for the active group's
    // `group_decisions` stream.
    private var realtimeSubscription: (any GroupRealtimeSubscription)?
    private var realtimeGroupId: UUID?

    public init(repository: CanonicalDecisionsRepository) {
        self.repository = repository
    }

    // MARK: - Derived

    public var hasOpen: Bool { !open.isEmpty }
    public var hasHistory: Bool { !history.isEmpty }
    public var openCount: Int { open.count }

    // MARK: - List intents

    public func refresh(groupId: UUID) async {
        if (open.isEmpty && history.isEmpty) || loadedGroupId != groupId {
            phase = .loading
        }
        do {
            async let openTask = repository.activeDecisions(groupId: groupId)
            async let historyTask = repository.historyDecisions(groupId: groupId, limit: 50)
            let (openRows, historyRows) = try await (openTask, historyTask)
            open = openRows
            history = historyRows
            phase = .loaded
            loadedGroupId = groupId
            errorMessage = nil
        } catch {
            let message = UserFacingError.from(error).message
            errorMessage = message
            phase = .failed(message: message)
        }
    }

    public func refreshIfNeeded(groupId: UUID) async {
        if loadedGroupId == groupId, !open.isEmpty || !history.isEmpty {
            if case .idle = phase { phase = .loaded }
            return
        }
        await refresh(groupId: groupId)
    }

    // MARK: - Detail

    public func loadDetail(decisionId: UUID) async {
        detail = nil
        detailPhase = .loading
        detailErrorMessage = nil
        do {
            detail = try await repository.detail(decisionId: decisionId)
            detailPhase = .loaded
        } catch {
            let message = UserFacingError.from(error).message
            detailErrorMessage = message
            detailPhase = .failed(message: message)
        }
    }

    public func refreshDetail() async {
        guard let id = detail?.id else { return }
        await loadDetail(decisionId: id)
    }

    public func clearDetail() {
        detail = nil
        detailPhase = .idle
        detailErrorMessage = nil
    }

    // MARK: - Propose

    public func beginProposing() {
        draftTitle = ""
        draftBody = ""
        // Initialize draftMethod + draftLegitimacySource *before* we
        // flip auto-sync on. The didSet observers on both properties
        // turn auto-sync off on every assignment, so we set the values
        // first and enable tracking last.
        draftMethod = .majority
        draftLegitimacySource = LegitimacySource.defaultFor(method: .majority)
        draftLegitimacyAutoSync = true
        draftType = .proposal
        draftOptions = []
        draftErrorMessage = nil
        isProposePresented = true
    }

    public func addDraftOption() {
        draftOptions.append(DraftOption())
    }

    public func removeDraftOption(at offsets: IndexSet) {
        draftOptions.remove(atOffsets: offsets)
    }

    public var canSaveDraftDecision: Bool {
        !draftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @discardableResult
    public func saveDraftDecision(groupId: UUID) async -> Bool {
        let trimmedTitle = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            draftErrorMessage = String(localized: L10n.Decisions.proposeTitleRequired)
            return false
        }
        let cleanedOptions = draftOptions
            .map { $0.label.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !cleanedOptions.isEmpty && cleanedOptions.count < 2 {
            draftErrorMessage = String(localized: L10n.Decisions.proposeOptionTooFew)
            return false
        }
        let payload: [StartVoteParams.OptionDraft]? = cleanedOptions.isEmpty
            ? nil
            : cleanedOptions.map { StartVoteParams.OptionDraft(label: $0, body: nil) }
        do {
            _ = try await repository.propose(
                groupId: groupId,
                title: trimmedTitle,
                body: draftBody,
                decisionType: draftType,
                method: draftMethod,
                legitimacySource: draftLegitimacySource,
                options: payload
            )
            await refresh(groupId: groupId)
            isProposePresented = false
            clearDraft()
            return true
        } catch {
            draftErrorMessage = UserFacingError.from(error).message
            return false
        }
    }

    public func clearDraft() {
        draftTitle = ""
        draftBody = ""
        draftMethod = .majority
        draftLegitimacySource = LegitimacySource.defaultFor(method: .majority)
        draftLegitimacyAutoSync = true
        draftType = .proposal
        draftOptions = []
        draftErrorMessage = nil
    }

    // MARK: - Vote

    public func beginVoting(on decision: GroupDecisionDetail) {
        voteDraftDecisionId = decision.id
        voteDraftValue = decision.myVote?.voteValue ?? .yes
        voteDraftOptionId = decision.myVote?.optionId
        voteDraftReason = decision.myVote?.reason ?? ""
        voteDraftErrorMessage = nil
        isVotePresented = true
    }

    public func beginVoting(on summary: GroupDecisionSummary) {
        voteDraftDecisionId = summary.id
        voteDraftValue = summary.myVoteValue ?? .yes
        voteDraftOptionId = summary.myVoteOptionId
        voteDraftReason = ""
        voteDraftErrorMessage = nil
        isVotePresented = true
    }

    @discardableResult
    public func saveDraftVote(groupId: UUID) async -> Bool {
        guard let decisionId = voteDraftDecisionId else {
            voteDraftErrorMessage = String(localized: L10n.Decisions.voteValueRequired)
            return false
        }
        do {
            _ = try await repository.castVote(
                decisionId: decisionId,
                value: voteDraftValue,
                optionId: voteDraftOptionId,
                reason: voteDraftReason
            )
            await refresh(groupId: groupId)
            if detail?.id == decisionId {
                await refreshDetail()
            }
            isVotePresented = false
            clearVoteDraft()
            return true
        } catch {
            voteDraftErrorMessage = UserFacingError.from(error).message
            return false
        }
    }

    public func clearVoteDraft() {
        voteDraftDecisionId = nil
        voteDraftValue = .yes
        voteDraftOptionId = nil
        voteDraftReason = ""
        voteDraftErrorMessage = nil
    }

    // MARK: - Lifecycle actions

    @discardableResult
    public func finalize(decisionId: UUID, groupId: UUID) async -> Bool {
        do {
            _ = try await repository.finalize(decisionId: decisionId)
            await refresh(groupId: groupId)
            if detail?.id == decisionId {
                await refreshDetail()
            }
            return true
        } catch {
            errorMessage = UserFacingError.from(error).message
            return false
        }
    }

    @discardableResult
    public func cancel(decisionId: UUID, reason: String? = nil, groupId: UUID) async -> Bool {
        do {
            try await repository.cancel(decisionId: decisionId, reason: reason)
            await refresh(groupId: groupId)
            if detail?.id == decisionId {
                await refreshDetail()
            }
            return true
        } catch {
            errorMessage = UserFacingError.from(error).message
            return false
        }
    }

    public func clearError() {
        errorMessage = nil
        draftErrorMessage = nil
        voteDraftErrorMessage = nil
    }

    // MARK: - Realtime (V2-A1)

    public func startListening(groupId: UUID, realtime: any GroupRealtimeService) async {
        if realtimeGroupId == groupId, realtimeSubscription != nil { return }
        await stopListening()
        realtimeGroupId = groupId
        realtimeSubscription = await realtime.subscribe(
            groupId: groupId,
            table: .decisions,
            onChange: { [weak self] in
                await self?.refresh(groupId: groupId)
            }
        )
    }

    public func stopListening() async {
        guard let sub = realtimeSubscription else { return }
        realtimeSubscription = nil
        realtimeGroupId = nil
        await sub.cancel()
    }
}
