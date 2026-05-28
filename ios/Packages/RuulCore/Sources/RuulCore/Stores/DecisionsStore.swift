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
    public var draftType: DecisionType = .proposal {
        didSet {
            // Switching type wipes the reference pick + per-type
            // metadata — the previous entity or per-type fields are
            // no longer relevant.
            if oldValue != draftType {
                draftReferenceId = nil
                draftMembershipTargetState = nil
                draftRuleChangeAction = nil
                draftPoolChargeAmount = ""
                draftPoolChargeUnit = "MXN"
                draftPoolChargeKind = nil
            }
        }
    }
    /// V2-G2 sub-slice 3 — the entity this decision is about, when
    /// `draftType.requiredReferenceKind` is non-nil. The reference
    /// kind is derived from the type (no separate picker); the id is
    /// picked from the relevant active list (sanctions / mandates).
    public var draftReferenceId: UUID?
    /// V2-G2 sub-slice 4 — for `decision_type='membership'` the
    /// proposer must specify the target state (active / suspended /
    /// expelled / inactive). This persists to `metadata.target_state`
    /// and finalize_vote dispatches set_membership_state with it.
    public var draftMembershipTargetState: MembershipDecisionTargetState? = nil
    /// V2-G2 sub-slice 5 — for `decision_type='rule_change'` the
    /// proposer specifies what to do with the referenced rule on
    /// finalize. Persists to `metadata.action`. finalize_vote handler
    /// inlines the matching group_rules.status flip.
    public var draftRuleChangeAction: RuleChangeAction? = nil
    /// V2-G2 sub-slice 6 — for `decision_type='budget'` the proposer
    /// specifies the pool_charge to create on finalize. Amount is a
    /// free-form string here so the UI can hold partial input; the
    /// metadata composer parses it.
    public var draftPoolChargeAmount: String = ""
    public var draftPoolChargeUnit: String = "MXN"
    public var draftPoolChargeKind: PoolChargeKind? = nil
    public var draftOptions: [DraftOption] = []
    public private(set) var draftErrorMessage: String?

    /// Convenience: true when the chosen type binds to an entity AND
    /// the proposer hasn't picked one yet. The propose CTA uses this
    /// alongside `canSaveDraftDecision`.
    public var draftNeedsReferencePick: Bool {
        draftType.requiredReferenceKind != nil && draftReferenceId == nil
    }

    /// V2-G2 sub-slice 4 — membership type also needs a target state
    /// before the CTA fires, otherwise finalize_vote would skip its
    /// handler with a missing target_state.
    public var draftNeedsMembershipTargetState: Bool {
        draftType == .membership && draftMembershipTargetState == nil
    }

    /// V2-G2 sub-slice 5 — rule_change type needs an action.
    public var draftNeedsRuleChangeAction: Bool {
        draftType == .ruleChange && draftRuleChangeAction == nil
    }

    /// V2-G2 sub-slice 6 — budget type needs amount + kind. Unit
    /// defaults to MXN so we don't gate on it; amount must parse to
    /// a positive Decimal.
    public var draftPoolChargeParsedAmount: Decimal? {
        let normalized = draftPoolChargeAmount
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, let value = Decimal(string: normalized) else { return nil }
        return value > 0 ? value : nil
    }

    public var draftNeedsPoolChargeFields: Bool {
        draftType == .budget
            && (draftPoolChargeParsedAmount == nil || draftPoolChargeKind == nil)
    }

    /// V2-G9 — weight strategy attached to a `method='weighted'` draft.
    /// Defaults to `manual / max_weight=10`. Persists into
    /// `group_decisions.metadata.weight_strategy` jsonb.
    public var draftWeightStrategy: WeightStrategy = WeightStrategy()

    /// Composed `metadata` jsonb payload for the current draft.
    /// Membership decisions write `target_state`; rule_change writes
    /// `action`; budget writes amount/unit/charge_kind. Weighted
    /// decisions write `weight_strategy` as a nested object. Future
    /// handlers add more keys here.
    public var draftMetadata: [String: RPCJSONValue]? {
        var payload: [String: RPCJSONValue] = [:]
        if draftType == .membership, let target = draftMembershipTargetState {
            payload["target_state"] = .string(target.rawValue)
        }
        if draftType == .ruleChange, let action = draftRuleChangeAction {
            payload["action"] = .string(action.rawValue)
        }
        if draftType == .budget,
           let amount = draftPoolChargeParsedAmount,
           let kind = draftPoolChargeKind {
            payload["amount"]      = .string("\(amount)")
            payload["unit"]        = .string(draftPoolChargeUnit)
            payload["charge_kind"] = .string(kind.rawValue)
        }
        if draftMethod == .weighted {
            payload["weight_strategy"] = .object([
                "kind":   .string(draftWeightStrategy.kind.rawValue),
                "config": .object([
                    "max_weight": .number(draftWeightStrategy.maxWeight)
                ])
            ])
        }
        return payload.isEmpty ? nil : payload
    }

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
    /// V2-G9 — ranked-choice ballot draft. Indexed by 1-based rank as
    /// the user reorders; the list is materialized from the decision's
    /// options in `beginVoting(on:)`.
    public var voteDraftRankedOrder: [UUID] = []
    /// V2-G9 — weighted ballot draft. Maps option id → weight chosen
    /// by the voter (capped by the decision's `weight_strategy.max_weight`).
    public var voteDraftWeights: [UUID: Decimal] = [:]
    /// V2-G9 — max weight derived from the decision's strategy. Cached
    /// in the store so VoteSheet can size its slider/stepper. Defaults
    /// to `WeightStrategy.defaultMaxWeight` when the strategy can't be
    /// decoded.
    public var voteDraftMaxWeight: Decimal = WeightStrategy.defaultMaxWeight

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

    /// V2-G2 sub-slice 8 — accepts the group's `GroupDecisionRules` so
    /// the propose sheet inherits `default_method` + `default_legitimacy_source`
    /// instead of always defaulting to majority/majority. Pass nil from
    /// surfaces that don't have the store loaded; legitimacy auto-sync
    /// stays on so a method change still re-syncs the source unless the
    /// proposer touches it.
    public func beginProposing(defaults: GroupDecisionRules? = nil) {
        draftTitle = ""
        draftBody = ""
        // Initialize draftMethod + draftLegitimacySource *before* we
        // flip auto-sync on. The didSet observers on both properties
        // turn auto-sync off on every assignment, so we set the values
        // first and enable tracking last.
        let method = defaults?.defaultMethod ?? .majority
        let legitimacy = defaults?.defaultLegitimacySource ?? LegitimacySource.defaultFor(method: method)
        draftMethod = method
        draftLegitimacySource = legitimacy
        draftLegitimacyAutoSync = true
        draftType = .proposal
        draftReferenceId = nil
        draftMembershipTargetState = nil
        draftRuleChangeAction = nil
        draftPoolChargeAmount = ""
        draftPoolChargeUnit = "MXN"
        draftPoolChargeKind = nil
        draftWeightStrategy = WeightStrategy()
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
            && !draftNeedsReferencePick
            && !draftNeedsMembershipTargetState
            && !draftNeedsRuleChangeAction
            && !draftNeedsPoolChargeFields
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
        // V2-G2 sub-slice 3 — reject save when the type requires a
        // reference (sanction/mandate) but the proposer hasn't picked
        // one. The UI gates the button on `canSaveDraftDecision`, so
        // hitting this branch should be rare, but it's defensive.
        if draftNeedsReferencePick {
            draftErrorMessage = String(localized: L10n.Decisions.proposeReferenceRequired)
            return false
        }
        // V2-G2 sub-slice 4 — membership type also needs the target
        // state; without it the backend handler skips silently and the
        // decision goes nowhere.
        if draftNeedsMembershipTargetState {
            draftErrorMessage = String(localized: L10n.Decisions.proposeMembershipTargetStateRequired)
            return false
        }
        // V2-G2 sub-slice 5 — same rationale for rule_change action.
        if draftNeedsRuleChangeAction {
            draftErrorMessage = String(localized: L10n.Decisions.proposeRuleChangeActionRequired)
            return false
        }
        // V2-G2 sub-slice 6 — budget needs amount + kind.
        if draftNeedsPoolChargeFields {
            draftErrorMessage = String(localized: L10n.Decisions.proposeBudgetFieldsRequired)
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
                referenceKind: draftType.requiredReferenceKind,
                referenceId: draftReferenceId,
                metadata: draftMetadata,
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
        draftReferenceId = nil
        draftMembershipTargetState = nil
        draftRuleChangeAction = nil
        draftPoolChargeAmount = ""
        draftPoolChargeUnit = "MXN"
        draftPoolChargeKind = nil
        draftWeightStrategy = WeightStrategy()
        draftOptions = []
        draftErrorMessage = nil
    }

    // MARK: - Vote

    public func beginVoting(on decision: GroupDecisionDetail) {
        voteDraftDecisionId = decision.id
        voteDraftValue = decision.myVote?.voteValue
            ?? VoteValue.allowed(for: decision.method).first
            ?? .yes
        voteDraftOptionId = decision.myVote?.optionId
        voteDraftReason = decision.myVote?.reason ?? ""
        // V2-G9 — initialize ranked/weighted draft state from the
        // decision's options. Order matches `sortOrder` (the proposer's
        // intended display order); the voter can drag to reorder.
        voteDraftRankedOrder = decision.options.map(\.id)
        voteDraftWeights = Dictionary(
            uniqueKeysWithValues: decision.options.map { ($0.id, 0) }
        )
        voteDraftMaxWeight = decision.weightStrategy?.maxWeight
            ?? WeightStrategy.defaultMaxWeight
        voteDraftErrorMessage = nil
        isVotePresented = true
    }

    public func beginVoting(on summary: GroupDecisionSummary) {
        voteDraftDecisionId = summary.id
        voteDraftValue = summary.myVoteValue
            ?? VoteValue.allowed(for: summary.method).first
            ?? .yes
        voteDraftOptionId = summary.myVoteOptionId
        voteDraftReason = ""
        voteDraftRankedOrder = []
        voteDraftWeights = [:]
        voteDraftMaxWeight = WeightStrategy.defaultMaxWeight
        voteDraftErrorMessage = nil
        isVotePresented = true
    }

    @discardableResult
    public func saveDraftVote(groupId: UUID) async -> Bool {
        guard let decisionId = voteDraftDecisionId else {
            voteDraftErrorMessage = String(localized: L10n.Decisions.voteValueRequired)
            return false
        }
        let method: DecisionMethod? = (detail?.id == decisionId) ? detail?.method : nil

        // V2-G9 — branch on method. ranked_choice → cast_ranked_vote;
        // weighted → cast_vote with p_weight; everything else → legacy.
        do {
            switch method {
            case .rankedChoice:
                if voteDraftRankedOrder.isEmpty {
                    voteDraftErrorMessage = String(localized: L10n.Decisions.voteRankedEmptyHint)
                    return false
                }
                let rankings = voteDraftRankedOrder.enumerated().map {
                    (optionId: $0.element, rank: $0.offset + 1)
                }
                _ = try await repository.castRankedVote(
                    decisionId: decisionId,
                    rankings: rankings,
                    reason: voteDraftReason
                )
            case .weighted:
                guard let optionId = voteDraftOptionId else {
                    voteDraftErrorMessage = String(localized: L10n.Decisions.voteWeightedOptionRequiredHint)
                    return false
                }
                let weight = voteDraftWeights[optionId] ?? 0
                if weight <= 0 {
                    voteDraftErrorMessage = String(localized: L10n.Decisions.voteWeightedZeroHint)
                    return false
                }
                if weight > voteDraftMaxWeight {
                    voteDraftErrorMessage = String(localized: L10n.Decisions.voteWeightedOverMaxHint)
                    return false
                }
                _ = try await repository.castVote(
                    decisionId: decisionId,
                    value: .yes,                  // backend ignores when method=weighted
                    optionId: optionId,
                    reason: voteDraftReason,
                    weight: weight
                )
            default:
                // V2-G1 sub-slice 2 — consent/veto block require a reason.
                if let method,
                   voteDraftValue.requiresReason(for: method),
                   voteDraftReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    voteDraftErrorMessage = String(localized: L10n.Decisions.voteReasonRequiredHint)
                    return false
                }
                _ = try await repository.castVote(
                    decisionId: decisionId,
                    value: voteDraftValue,
                    optionId: voteDraftOptionId,
                    reason: voteDraftReason
                )
            }
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
        voteDraftRankedOrder = []
        voteDraftWeights = [:]
        voteDraftMaxWeight = WeightStrategy.defaultMaxWeight
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
