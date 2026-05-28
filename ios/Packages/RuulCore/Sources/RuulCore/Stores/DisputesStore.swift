import Foundation
import Observation

/// `@MainActor` store for Primitiva 14 (Disputas). Caches the active
/// disputes list per group + drives every flow on top of disputes:
/// open (generic + sanction-specific), append event, resolve and
/// escalate-to-vote. Detail + timeline are also tracked here so the
/// `DisputeDetailView` doesn't need its own store.
@MainActor
@Observable
public final class DisputesStore {
    public private(set) var disputes: [GroupDispute] = []
    public private(set) var phase: StorePhase = .idle
    public private(set) var errorMessage: String?

    /// Drives the `DisputeSanctionSheet` from a SanctionRowView action.
    public var isDisputeSanctionPresented: Bool = false
    public var draftSanctionId: UUID?
    public var draftSummary: String = ""

    // MARK: - Detail + timeline (C2)

    public private(set) var detail: GroupDisputeDetail?
    public private(set) var events: [GroupDisputeEvent] = []
    public private(set) var detailPhase: StorePhase = .idle
    public private(set) var detailErrorMessage: String?

    // MARK: - Open generic dispute draft (C2)

    public var isOpenPresented: Bool = false
    public var openDraftTitle: String = ""
    public var openDraftDescription: String = ""
    public var openDraftSubjectKind: DisputeSubjectKind = .other
    public var openDraftSubjectId: UUID?
    public var openDraftRespondentMembershipId: UUID?
    public private(set) var openDraftErrorMessage: String?

    // MARK: - Append event draft (C2)

    public var isAppendEventPresented: Bool = false
    public var eventDraftDisputeId: UUID?
    public var eventDraftType: DisputeEventType = .comment
    public var eventDraftBody: String = ""
    public private(set) var eventDraftErrorMessage: String?

    // MARK: - Resolve dispute draft (C2)

    public var isResolvePresented: Bool = false
    public var resolveDraftDisputeId: UUID?
    public var resolveDraftMethod: DisputeResolutionMethod = .conversation
    public var resolveDraftText: String = ""
    public private(set) var resolveDraftErrorMessage: String?

    // MARK: - Escalate to vote draft (C2)

    public var isEscalatePresented: Bool = false
    public var escalateDraftDisputeId: UUID?
    public var escalateDraftTitle: String = ""
    public var escalateDraftMethod: DecisionMethod = .majority
    public var escalateDraftClosesAt: Date?
    public var escalateDraftHasCloseDate: Bool = false
    public private(set) var escalateDraftErrorMessage: String?
    public private(set) var lastEscalatedDecisionId: UUID?

    // MARK: - Storage

    private let repository: CanonicalDisputesRepository
    private var loadedGroupId: UUID?

    // V2-A1 — realtime listener handle for the active group's
    // `group_disputes` stream.
    private var realtimeSubscription: (any GroupRealtimeSubscription)?
    private var realtimeGroupId: UUID?

    public init(repository: CanonicalDisputesRepository) {
        self.repository = repository
    }

    // MARK: - Derived

    public var hasDisputes: Bool { !disputes.isEmpty }
    public var activeCount: Int { disputes.count }
    public var sanctionDisputesCount: Int { disputes.filter(\.isSanctionDispute).count }

    public var canSaveDraft: Bool {
        guard draftSanctionId != nil else { return false }
        return !draftSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var canSaveOpenDraft: Bool {
        !openDraftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var canSaveEventDraft: Bool {
        guard eventDraftDisputeId != nil else { return false }
        // Comment / mediation note / other require a body. Evidence
        // can carry a body too but historically allows empty.
        switch eventDraftType {
        case .comment, .mediationNote, .other:
            return !eventDraftBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .evidenceAdded:
            return !eventDraftBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .statusChange, .resolution, .escalation:
            return false
        }
    }

    public var canSaveResolveDraft: Bool {
        guard resolveDraftDisputeId != nil else { return false }
        return !resolveDraftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var canSaveEscalateDraft: Bool {
        guard escalateDraftDisputeId != nil else { return false }
        return !escalateDraftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - List intents

    public func refresh(groupId: UUID) async {
        if disputes.isEmpty || loadedGroupId != groupId {
            phase = .loading
        }
        do {
            disputes = try await repository.activeDisputes(groupId: groupId)
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
        if loadedGroupId == groupId, !disputes.isEmpty {
            if case .idle = phase { phase = .loaded }
            return
        }
        await refresh(groupId: groupId)
    }

    // MARK: - Sanction dispute path (legacy entry from SanctionsListView)

    public func beginDisputingSanction(_ sanctionId: UUID) {
        draftSanctionId = sanctionId
        draftSummary = ""
        errorMessage = nil
        isDisputeSanctionPresented = true
    }

    @discardableResult
    public func saveDraft(groupId: UUID) async -> Bool {
        guard let sanctionId = draftSanctionId else {
            errorMessage = "No hay sanción seleccionada."
            return false
        }
        let trimmed = draftSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            errorMessage = "Escribe un resumen."
            return false
        }
        do {
            _ = try await repository.disputeSanction(sanctionId: sanctionId, summary: trimmed)
            await refresh(groupId: groupId)
            isDisputeSanctionPresented = false
            errorMessage = nil
            return true
        } catch {
            errorMessage = UserFacingError.from(error).message
            return false
        }
    }

    public func clearDraft() {
        draftSanctionId = nil
        draftSummary = ""
        errorMessage = nil
    }

    // MARK: - Detail + timeline

    public func loadDetail(disputeId: UUID) async {
        detail = nil
        events = []
        detailPhase = .loading
        detailErrorMessage = nil
        do {
            async let detailTask = repository.detail(disputeId: disputeId)
            async let eventsTask = repository.events(disputeId: disputeId)
            let (det, evs) = try await (detailTask, eventsTask)
            detail = det
            events = evs
            detailPhase = .loaded
        } catch {
            let message = UserFacingError.from(error).message
            detailErrorMessage = message
            detailPhase = .failed(message: message)
        }
    }

    public func refreshDetail() async {
        guard let id = detail?.id else { return }
        await loadDetail(disputeId: id)
    }

    public func clearDetail() {
        detail = nil
        events = []
        detailPhase = .idle
        detailErrorMessage = nil
    }

    // MARK: - Open generic dispute

    public func beginOpeningDispute(
        subjectKind: DisputeSubjectKind = .other,
        subjectId: UUID? = nil,
        respondentMembershipId: UUID? = nil
    ) {
        openDraftTitle = ""
        openDraftDescription = ""
        openDraftSubjectKind = subjectKind
        openDraftSubjectId = subjectId
        openDraftRespondentMembershipId = respondentMembershipId
        openDraftErrorMessage = nil
        isOpenPresented = true
    }

    @discardableResult
    public func saveOpenDraft(groupId: UUID) async -> Bool {
        let trimmedTitle = openDraftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            openDraftErrorMessage = String(localized: L10n.Disputes.openTitleRequired)
            return false
        }
        let trimmedDesc = openDraftDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            _ = try await repository.openDispute(
                groupId: groupId,
                subjectKind: openDraftSubjectKind,
                subjectId: openDraftSubjectId,
                title: trimmedTitle,
                description: trimmedDesc.isEmpty ? nil : trimmedDesc,
                respondentMembershipId: openDraftRespondentMembershipId
            )
            await refresh(groupId: groupId)
            isOpenPresented = false
            openDraftErrorMessage = nil
            openDraftTitle = ""
            openDraftDescription = ""
            return true
        } catch {
            openDraftErrorMessage = UserFacingError.from(error).message
            return false
        }
    }

    // MARK: - Append event

    public func beginAppendingEvent(
        disputeId: UUID,
        defaultType: DisputeEventType = .comment
    ) {
        eventDraftDisputeId = disputeId
        eventDraftType = defaultType
        eventDraftBody = ""
        eventDraftErrorMessage = nil
        isAppendEventPresented = true
    }

    @discardableResult
    public func saveEventDraft() async -> Bool {
        guard let disputeId = eventDraftDisputeId else {
            eventDraftErrorMessage = String(localized: L10n.Disputes.eventBodyRequired)
            return false
        }
        let trimmed = eventDraftBody.trimmingCharacters(in: .whitespacesAndNewlines)
        if !canSaveEventDraft {
            eventDraftErrorMessage = String(localized: L10n.Disputes.eventBodyRequired)
            return false
        }
        do {
            _ = try await repository.appendEvent(
                disputeId: disputeId,
                eventType: eventDraftType,
                body: trimmed.isEmpty ? nil : trimmed
            )
            if detail?.id == disputeId {
                await refreshDetail()
            }
            isAppendEventPresented = false
            eventDraftErrorMessage = nil
            eventDraftBody = ""
            return true
        } catch {
            eventDraftErrorMessage = UserFacingError.from(error).message
            return false
        }
    }

    // MARK: - Resolve

    public func beginResolving(disputeId: UUID) {
        resolveDraftDisputeId = disputeId
        resolveDraftMethod = .conversation
        resolveDraftText = ""
        resolveDraftErrorMessage = nil
        isResolvePresented = true
    }

    @discardableResult
    public func saveResolveDraft(groupId: UUID) async -> Bool {
        guard let disputeId = resolveDraftDisputeId else {
            resolveDraftErrorMessage = String(localized: L10n.Disputes.resolveBodyRequired)
            return false
        }
        let trimmed = resolveDraftText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            resolveDraftErrorMessage = String(localized: L10n.Disputes.resolveBodyRequired)
            return false
        }
        do {
            try await repository.recordResolution(
                disputeId: disputeId,
                method: resolveDraftMethod,
                resolutionText: trimmed
            )
            await refresh(groupId: groupId)
            if detail?.id == disputeId {
                await refreshDetail()
            }
            isResolvePresented = false
            resolveDraftErrorMessage = nil
            return true
        } catch {
            resolveDraftErrorMessage = UserFacingError.from(error).message
            return false
        }
    }

    // MARK: - Escalate to vote

    public func beginEscalating(disputeId: UUID, suggestedTitle: String? = nil) {
        escalateDraftDisputeId = disputeId
        escalateDraftTitle = suggestedTitle ?? ""
        escalateDraftMethod = .majority
        escalateDraftClosesAt = nil
        escalateDraftHasCloseDate = false
        escalateDraftErrorMessage = nil
        lastEscalatedDecisionId = nil
        isEscalatePresented = true
    }

    @discardableResult
    public func saveEscalateDraft(groupId: UUID) async -> Bool {
        guard let disputeId = escalateDraftDisputeId else {
            escalateDraftErrorMessage = String(localized: L10n.Disputes.escalateTitleRequired)
            return false
        }
        let trimmedTitle = escalateDraftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedTitle.isEmpty {
            escalateDraftErrorMessage = String(localized: L10n.Disputes.escalateTitleRequired)
            return false
        }
        let closesAt = escalateDraftHasCloseDate ? escalateDraftClosesAt : nil
        if let closesAt, closesAt <= Date() {
            escalateDraftErrorMessage = String(localized: L10n.Disputes.escalateClosesAtFuture)
            return false
        }
        do {
            let decisionId = try await repository.escalateToVote(
                disputeId: disputeId,
                decisionTitle: trimmedTitle,
                decisionMethod: escalateDraftMethod,
                closesAt: closesAt
            )
            lastEscalatedDecisionId = decisionId
            await refresh(groupId: groupId)
            if detail?.id == disputeId {
                await refreshDetail()
            }
            isEscalatePresented = false
            escalateDraftErrorMessage = nil
            return true
        } catch {
            escalateDraftErrorMessage = UserFacingError.from(error).message
            return false
        }
    }

    public func clearError() {
        errorMessage = nil
        openDraftErrorMessage = nil
        eventDraftErrorMessage = nil
        resolveDraftErrorMessage = nil
        escalateDraftErrorMessage = nil
    }

    // MARK: - Realtime (V2-A1)

    public func startListening(groupId: UUID, realtime: any GroupRealtimeService) async {
        if realtimeGroupId == groupId, realtimeSubscription != nil { return }
        await stopListening()
        realtimeGroupId = groupId
        realtimeSubscription = await realtime.subscribe(
            groupId: groupId,
            table: .disputes,
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
