import Foundation
import Observation

/// 2-step Create flow state machine. Step 1 is the type picker (forces
/// the user to pick from the 18 canonical types before seeing per-type
/// fields); Step 2 is the common form.
public enum CreateResourceStep: String, Sendable, Hashable {
    case type
    case details
}

/// `@MainActor` store for Primitiva 5 (Resources). Holds active
/// envelope rows + the create draft. Foundation surface focuses on the
/// envelope: subtype-specific writes (assign custodian, lock fund, book
/// space, …) ship in Fase B/C with dedicated sheets.
@MainActor
@Observable
public final class ResourcesStore {
    public private(set) var resources: [GroupResource] = []
    public private(set) var phase: StorePhase = .idle
    public private(set) var errorMessage: String?

    public var isCreatePresented: Bool = false

    /// 2-step Create flow: type picker → form. The store drives the
    /// step so the sheet can present either screen on open and the
    /// store decides what "Back" / "Continue" buttons do.
    public var createStep: CreateResourceStep = .type
    public var draftName: String = ""
    public var draftDescription: String = ""
    public var draftType: GroupResourceType = .fund
    public var draftVisibility: ResourceVisibility = .members
    public var draftOwnershipKind: ResourceOwnershipKind = .group
    public var draftOwnerMembershipId: UUID?

    /// Drives the `TransferOwnershipSheet` for an existing resource.
    public var isTransferPresented: Bool = false
    public var transferResourceId: UUID?
    public var transferKind: ResourceOwnershipKind = .group
    public var transferOwnerMembershipId: UUID?
    public var transferNote: String = ""

    // MARK: - Detail + Asset Fase B.1 state

    public private(set) var detail: GroupResourceDetail?
    public private(set) var detailPhase: StorePhase = .idle
    /// Active resource id that the detail surface (and Asset sheets) is
    /// operating on. Used to scope sheet saves correctly.
    public private(set) var activeResourceId: UUID?

    // AssignCustodianSheet
    public var isAssignCustodianPresented: Bool = false
    public var assignCustodianMembershipId: UUID?
    public var assignCustodianReason: String = ""

    // MarkConditionSheet
    public var isMarkConditionPresented: Bool = false
    public var markConditionDraft: AssetCondition = .good
    public var markConditionReason: String = ""

    // RecordValuationSheet
    public var isRecordValuationPresented: Bool = false
    public var valuationAmount: String = ""
    public var valuationUnit: String = "MXN"
    public var valuationBasis: AssetValuationBasis = .memberEstimate

    // Release custodian confirmation (no sheet, dialog only)
    public var isConfirmingReleaseCustodian: Bool = false

    // Fund Fase B.2 state
    public var isConfirmingLockFund: Bool = false
    public var isConfirmingUnlockFund: Bool = false
    public var isSetFundThresholdPresented: Bool = false
    public var fundThresholdAmount: String = ""
    public var fundThresholdUnit: String = "MXN"
    public var fundThresholdReason: String = ""

    // Space Fase B.3 state
    public private(set) var bookings: [GroupResourceBooking] = []
    public private(set) var bookingsPhase: StorePhase = .idle
    public var isBookSpacePresented: Bool = false
    public var bookStartsAt: Date = Date()
    public var bookEndsAt: Date = Date().addingTimeInterval(60 * 60)
    public var bookReason: String = ""
    public var pendingCancelBookingId: UUID?
    public var isConfirmingCancelBooking: Bool = false

    // Right Fase B.4 state
    public var isGrantRightPresented: Bool = false
    public var grantRightHolderId: UUID?
    public var grantRightKind: ResourceRightKind = .access
    public var grantRightHasExpiry: Bool = false
    public var grantRightExpiresAt: Date = Date().addingTimeInterval(60 * 60 * 24 * 30)
    public var grantRightTransferable: Bool = false
    public var grantRightConditions: String = ""
    public var grantRightReason: String = ""
    public var isTransferRightPresented: Bool = false
    public var transferRightNewHolderId: UUID?
    public var isConfirmingRevokeRight: Bool = false
    public var isConfirmingExpireRight: Bool = false

    private let repository: CanonicalResourcesRepository
    private var loadedGroupId: UUID?

    public init(repository: CanonicalResourcesRepository) {
        self.repository = repository
    }

    // MARK: - Derived state

    public var hasResources: Bool { !resources.isEmpty }

    /// Active rows grouped by type, preserving the backend order
    /// inside each bucket.
    public var resourcesByType: [GroupResourceType: [GroupResource]] {
        Dictionary(grouping: resources, by: \.resourceType)
    }

    /// Top 3 rows for the GroupHome card.
    public var topResources: [GroupResource] { Array(resources.prefix(3)) }

    public var canSaveDraft: Bool {
        !draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Intents

    public func refresh(groupId: UUID) async {
        if resources.isEmpty || loadedGroupId != groupId {
            phase = .loading
        }
        do {
            let fetched = try await repository.activeResources(groupId: groupId)
            resources = fetched
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
        if loadedGroupId == groupId, !resources.isEmpty {
            if case .idle = phase { phase = .loaded }
            return
        }
        await refresh(groupId: groupId)
    }

    /// Opens the create sheet with a fresh draft. When `type` is `nil`
    /// the flow starts on the type picker (Step 1); when provided we
    /// skip straight to the details form (Step 2).
    public func beginCreating(type: GroupResourceType? = nil) {
        draftName = ""
        draftDescription = ""
        draftType = type ?? .fund
        draftVisibility = .members
        draftOwnershipKind = .group
        draftOwnerMembershipId = nil
        createStep = (type == nil) ? .type : .details
        errorMessage = nil
        isCreatePresented = true
    }

    /// Step 1 → Step 2 of the Create flow.
    public func advanceFromTypePicker() {
        createStep = .details
        errorMessage = nil
    }

    /// Step 2 → Step 1 of the Create flow.
    public func returnToTypePicker() {
        createStep = .type
        errorMessage = nil
    }

    @discardableResult
    public func createDraft(groupId: UUID) async -> Bool {
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            errorMessage = "Ponle un nombre al recurso."
            return false
        }
        do {
            _ = try await repository.createResource(
                groupId: groupId,
                type: draftType,
                name: name,
                description: draftDescription,
                visibility: draftVisibility,
                ownershipKind: draftOwnershipKind,
                ownerMembershipId: draftOwnerMembershipId
            )
            // Refetch so we get the canonical sort + the wire shape
            // from `group_resources_active` (rather than a one-off
            // local insert).
            await refresh(groupId: groupId)
            isCreatePresented = false
            clearDraft()
            return true
        } catch {
            errorMessage = UserFacingError.from(error).message
            return false
        }
    }

    @discardableResult
    public func archive(resourceId: UUID, reason: String? = nil, groupId: UUID) async -> Bool {
        do {
            try await repository.archiveResource(resourceId: resourceId, reason: reason)
            resources.removeAll(where: { $0.id == resourceId })
            return true
        } catch {
            errorMessage = UserFacingError.from(error).message
            return false
        }
    }

    public func clearDraft() {
        draftName = ""
        draftDescription = ""
        draftType = .fund
        draftVisibility = .members
        draftOwnershipKind = .group
        draftOwnerMembershipId = nil
        createStep = .type
        errorMessage = nil
    }

    public func clearError() { errorMessage = nil }

    // MARK: - Transfer ownership

    public func beginTransferring(_ resource: GroupResource) {
        transferResourceId = resource.id
        transferKind = resource.ownershipKind
        transferOwnerMembershipId = resource.ownerMembershipId
        transferNote = ""
        errorMessage = nil
        isTransferPresented = true
    }

    public var canSaveTransfer: Bool {
        guard transferResourceId != nil else { return false }
        if transferKind == .member, transferOwnerMembershipId == nil { return false }
        return true
    }

    @discardableResult
    public func saveTransfer(groupId: UUID) async -> Bool {
        guard let resourceId = transferResourceId else {
            errorMessage = "No hay recurso seleccionado."
            return false
        }
        if transferKind == .member, transferOwnerMembershipId == nil {
            errorMessage = "Elige a quién pasa la propiedad."
            return false
        }
        do {
            try await repository.transferOwnership(
                resourceId: resourceId,
                ownershipKind: transferKind,
                ownerMembershipId: transferOwnerMembershipId,
                note: transferNote
            )
            await refresh(groupId: groupId)
            isTransferPresented = false
            transferResourceId = nil
            transferOwnerMembershipId = nil
            transferNote = ""
            return true
        } catch {
            errorMessage = UserFacingError.from(error).message
            return false
        }
    }

    // MARK: - Detail load

    public func loadDetail(resourceId: UUID) async {
        if detail?.resource.id != resourceId {
            detail = nil
            detailPhase = .loading
        }
        activeResourceId = resourceId
        do {
            let fetched = try await repository.resourceDetail(resourceId: resourceId)
            detail = fetched
            detailPhase = .loaded
            errorMessage = nil
        } catch {
            let message = UserFacingError.from(error).message
            errorMessage = message
            detailPhase = .failed(message: message)
        }
    }

    public func clearDetail() {
        detail = nil
        detailPhase = .idle
        activeResourceId = nil
    }

    // MARK: - Asset Fase B.1 — Assign / Release custodian

    public func presentAssignCustodian(seed: AssetSubtypeData? = nil) {
        assignCustodianMembershipId = seed?.custodianMembershipId
        assignCustodianReason = ""
        errorMessage = nil
        isAssignCustodianPresented = true
    }

    public var canSaveAssignCustodian: Bool {
        activeResourceId != nil && assignCustodianMembershipId != nil
    }

    @discardableResult
    public func saveAssignCustodian() async -> Bool {
        guard let resourceId = activeResourceId else {
            errorMessage = "No hay recurso activo."
            return false
        }
        guard let membershipId = assignCustodianMembershipId else {
            errorMessage = String(localized: L10n.AssignCustodian.memberRequired)
            return false
        }
        do {
            _ = try await repository.assignAssetCustodian(
                resourceId: resourceId,
                membershipId: membershipId,
                reason: assignCustodianReason,
                clientId: UUID().uuidString
            )
            await loadDetail(resourceId: resourceId)
            isAssignCustodianPresented = false
            assignCustodianMembershipId = nil
            assignCustodianReason = ""
            return true
        } catch {
            errorMessage = UserFacingError.from(error).message
            return false
        }
    }

    public func presentReleaseCustodian() {
        errorMessage = nil
        isConfirmingReleaseCustodian = true
    }

    @discardableResult
    public func confirmReleaseCustodian() async -> Bool {
        guard let resourceId = activeResourceId else {
            errorMessage = "No hay recurso activo."
            return false
        }
        do {
            _ = try await repository.releaseAssetCustodian(
                resourceId: resourceId,
                reason: nil,
                clientId: UUID().uuidString
            )
            await loadDetail(resourceId: resourceId)
            isConfirmingReleaseCustodian = false
            return true
        } catch {
            errorMessage = UserFacingError.from(error).message
            return false
        }
    }

    // MARK: - Asset Fase B.1 — Mark condition

    public func presentMarkCondition(seed: AssetSubtypeData? = nil) {
        markConditionDraft = seed?.condition ?? .good
        markConditionReason = ""
        errorMessage = nil
        isMarkConditionPresented = true
    }

    @discardableResult
    public func saveMarkCondition() async -> Bool {
        guard let resourceId = activeResourceId else {
            errorMessage = "No hay recurso activo."
            return false
        }
        do {
            _ = try await repository.markAssetCondition(
                resourceId: resourceId,
                condition: markConditionDraft,
                reason: markConditionReason,
                clientId: UUID().uuidString
            )
            await loadDetail(resourceId: resourceId)
            isMarkConditionPresented = false
            markConditionReason = ""
            return true
        } catch {
            errorMessage = UserFacingError.from(error).message
            return false
        }
    }

    // MARK: - Asset Fase B.1 — Record valuation

    public func presentRecordValuation(seed: AssetSubtypeData? = nil) {
        valuationAmount = ""
        valuationUnit = seed?.currentValueUnit ?? "MXN"
        valuationBasis = .memberEstimate
        errorMessage = nil
        isRecordValuationPresented = true
    }

    public var canSaveValuation: Bool {
        guard activeResourceId != nil else { return false }
        guard let value = decimalValuationAmount, value > 0 else { return false }
        return !valuationUnit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var decimalValuationAmount: Decimal? {
        let trimmed = valuationAmount.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Decimal(string: trimmed)
    }

    @discardableResult
    public func saveRecordValuation() async -> Bool {
        guard let resourceId = activeResourceId else {
            errorMessage = "No hay recurso activo."
            return false
        }
        guard let value = decimalValuationAmount, value > 0 else {
            errorMessage = String(localized: L10n.RecordValuation.amountRequired)
            return false
        }
        let unit = valuationUnit.trimmingCharacters(in: .whitespacesAndNewlines)
        if unit.isEmpty {
            errorMessage = String(localized: L10n.RecordValuation.unitRequired)
            return false
        }
        do {
            try await repository.recordAssetValuation(
                resourceId: resourceId,
                value: value,
                unit: unit,
                basis: valuationBasis.rawValue
            )
            await loadDetail(resourceId: resourceId)
            isRecordValuationPresented = false
            valuationAmount = ""
            return true
        } catch {
            errorMessage = UserFacingError.from(error).message
            return false
        }
    }
}

// MARK: - Fund Fase B.2 actions

@MainActor
extension ResourcesStore {
    public func presentLockFund() {
        errorMessage = nil
        isConfirmingLockFund = true
    }

    public func presentUnlockFund() {
        errorMessage = nil
        isConfirmingUnlockFund = true
    }

    @discardableResult
    public func confirmLockFund() async -> Bool {
        guard let resourceId = activeResourceId else {
            errorMessage = "No hay recurso activo."
            return false
        }
        do {
            _ = try await repository.lockFund(
                resourceId: resourceId,
                reason: nil,
                clientId: UUID().uuidString
            )
            await loadDetail(resourceId: resourceId)
            isConfirmingLockFund = false
            return true
        } catch {
            errorMessage = UserFacingError.from(error).message
            return false
        }
    }

    @discardableResult
    public func confirmUnlockFund() async -> Bool {
        guard let resourceId = activeResourceId else {
            errorMessage = "No hay recurso activo."
            return false
        }
        do {
            _ = try await repository.unlockFund(
                resourceId: resourceId,
                reason: nil,
                clientId: UUID().uuidString
            )
            await loadDetail(resourceId: resourceId)
            isConfirmingUnlockFund = false
            return true
        } catch {
            errorMessage = UserFacingError.from(error).message
            return false
        }
    }

    public func presentSetFundThreshold(seed: FundSubtypeData? = nil) {
        if let threshold = seed?.thresholdTarget {
            fundThresholdAmount = NSDecimalNumber(decimal: threshold).stringValue
        } else {
            fundThresholdAmount = ""
        }
        fundThresholdUnit = seed?.currency ?? "MXN"
        fundThresholdReason = ""
        errorMessage = nil
        isSetFundThresholdPresented = true
    }

    public var decimalFundThresholdAmount: Decimal? {
        let trimmed = fundThresholdAmount.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Decimal(string: trimmed)
    }

    public var canSaveFundThreshold: Bool {
        guard activeResourceId != nil else { return false }
        guard let value = decimalFundThresholdAmount, value >= 0 else { return false }
        return !fundThresholdUnit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @discardableResult
    public func saveFundThreshold() async -> Bool {
        guard let resourceId = activeResourceId else {
            errorMessage = "No hay recurso activo."
            return false
        }
        guard let value = decimalFundThresholdAmount, value >= 0 else {
            errorMessage = String(localized: L10n.SetFundThreshold.amountRequired)
            return false
        }
        let unit = fundThresholdUnit.trimmingCharacters(in: .whitespacesAndNewlines)
        if unit.isEmpty {
            errorMessage = String(localized: L10n.SetFundThreshold.unitRequired)
            return false
        }
        do {
            _ = try await repository.setFundThreshold(
                resourceId: resourceId,
                thresholdTarget: value,
                unit: unit,
                reason: fundThresholdReason,
                clientId: UUID().uuidString
            )
            await loadDetail(resourceId: resourceId)
            isSetFundThresholdPresented = false
            fundThresholdReason = ""
            return true
        } catch {
            errorMessage = UserFacingError.from(error).message
            return false
        }
    }
}

// MARK: - Space Fase B.3 actions

@MainActor
extension ResourcesStore {
    public func presentBookSpace() {
        let now = Date()
        // Default window: next top-of-hour to one hour later, in the
        // device timezone. Users can override before save.
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month, .day, .hour], from: now)
        let topOfNextHour = cal.date(from: comps).map { $0.addingTimeInterval(60 * 60) } ?? now
        bookStartsAt = topOfNextHour
        bookEndsAt = topOfNextHour.addingTimeInterval(60 * 60)
        bookReason = ""
        errorMessage = nil
        isBookSpacePresented = true
    }

    public var canSaveBookSpace: Bool {
        activeResourceId != nil && bookEndsAt > bookStartsAt
    }

    @discardableResult
    public func saveBookSpace() async -> Bool {
        guard let resourceId = activeResourceId else {
            errorMessage = "No hay recurso activo."
            return false
        }
        guard bookEndsAt > bookStartsAt else {
            errorMessage = String(localized: L10n.BookSpace.invalidWindow)
            return false
        }
        do {
            _ = try await repository.bookResource(
                resourceId: resourceId,
                startsAt: bookStartsAt,
                endsAt: bookEndsAt,
                reason: bookReason,
                clientId: UUID().uuidString
            )
            await refreshBookings(resourceId: resourceId)
            isBookSpacePresented = false
            bookReason = ""
            return true
        } catch {
            errorMessage = UserFacingError.from(error).message
            return false
        }
    }

    public func refreshBookings(resourceId: UUID) async {
        if bookings.isEmpty {
            bookingsPhase = .loading
        }
        do {
            let fetched = try await repository.listBookingsForResource(
                resourceId: resourceId,
                startsAfter: nil,
                endsBefore: nil,
                limit: 50
            )
            bookings = fetched
            bookingsPhase = .loaded
        } catch {
            let message = UserFacingError.from(error).message
            errorMessage = message
            bookingsPhase = .failed(message: message)
        }
    }

    public func clearBookings() {
        bookings = []
        bookingsPhase = .idle
    }

    public func presentCancelBooking(_ bookingId: UUID) {
        pendingCancelBookingId = bookingId
        errorMessage = nil
        isConfirmingCancelBooking = true
    }

    @discardableResult
    public func confirmCancelBooking() async -> Bool {
        guard let bookingId = pendingCancelBookingId else {
            isConfirmingCancelBooking = false
            return false
        }
        guard let resourceId = activeResourceId else {
            errorMessage = "No hay recurso activo."
            return false
        }
        do {
            _ = try await repository.cancelBooking(bookingId: bookingId, reason: nil)
            await refreshBookings(resourceId: resourceId)
            isConfirmingCancelBooking = false
            pendingCancelBookingId = nil
            return true
        } catch {
            errorMessage = UserFacingError.from(error).message
            return false
        }
    }
}

// MARK: - Right Fase B.4 actions

@MainActor
extension ResourcesStore {
    public func presentGrantRight(seed: RightSubtypeData? = nil) {
        grantRightHolderId = seed?.holderMembershipId
        if let raw = seed?.rightKind, let kind = ResourceRightKind(rawValue: raw) {
            grantRightKind = kind
        } else {
            grantRightKind = .access
        }
        if let expires = seed?.expiresAt {
            grantRightHasExpiry = true
            grantRightExpiresAt = expires
        } else {
            grantRightHasExpiry = false
            grantRightExpiresAt = Date().addingTimeInterval(60 * 60 * 24 * 30)
        }
        grantRightTransferable = seed?.transferable ?? false
        grantRightConditions = seed?.conditions ?? ""
        grantRightReason = ""
        errorMessage = nil
        isGrantRightPresented = true
    }

    public var canSaveGrantRight: Bool {
        guard activeResourceId != nil, grantRightHolderId != nil else { return false }
        if grantRightHasExpiry, grantRightExpiresAt <= Date() { return false }
        return true
    }

    @discardableResult
    public func saveGrantRight() async -> Bool {
        guard let resourceId = activeResourceId else {
            errorMessage = "No hay recurso activo."
            return false
        }
        guard let holder = grantRightHolderId else {
            errorMessage = String(localized: L10n.GrantRight.memberRequired)
            return false
        }
        if grantRightHasExpiry, grantRightExpiresAt <= Date() {
            errorMessage = String(localized: L10n.GrantRight.expiresFuture)
            return false
        }
        do {
            _ = try await repository.grantRight(
                resourceId: resourceId,
                holderMembershipId: holder,
                rightKind: grantRightKind,
                expiresAt: grantRightHasExpiry ? grantRightExpiresAt : nil,
                conditions: grantRightConditions,
                transferable: grantRightTransferable,
                reason: grantRightReason,
                clientId: UUID().uuidString
            )
            await loadDetail(resourceId: resourceId)
            isGrantRightPresented = false
            grantRightReason = ""
            return true
        } catch {
            errorMessage = UserFacingError.from(error).message
            return false
        }
    }

    public func presentTransferRight() {
        transferRightNewHolderId = nil
        errorMessage = nil
        isTransferRightPresented = true
    }

    public var canSaveTransferRight: Bool {
        activeResourceId != nil && transferRightNewHolderId != nil
    }

    @discardableResult
    public func saveTransferRight() async -> Bool {
        guard let resourceId = activeResourceId else {
            errorMessage = "No hay recurso activo."
            return false
        }
        guard let newHolder = transferRightNewHolderId else {
            errorMessage = String(localized: L10n.GrantRight.memberRequired)
            return false
        }
        do {
            _ = try await repository.transferRight(
                resourceId: resourceId,
                newHolderMembershipId: newHolder,
                reason: nil,
                clientId: UUID().uuidString
            )
            await loadDetail(resourceId: resourceId)
            isTransferRightPresented = false
            transferRightNewHolderId = nil
            return true
        } catch {
            errorMessage = UserFacingError.from(error).message
            return false
        }
    }

    public func presentRevokeRight() {
        errorMessage = nil
        isConfirmingRevokeRight = true
    }

    @discardableResult
    public func confirmRevokeRight() async -> Bool {
        guard let resourceId = activeResourceId else {
            errorMessage = "No hay recurso activo."
            return false
        }
        do {
            _ = try await repository.revokeRight(
                resourceId: resourceId,
                reason: nil,
                clientId: UUID().uuidString
            )
            await loadDetail(resourceId: resourceId)
            isConfirmingRevokeRight = false
            return true
        } catch {
            errorMessage = UserFacingError.from(error).message
            return false
        }
    }

    public func presentExpireRight() {
        errorMessage = nil
        isConfirmingExpireRight = true
    }

    @discardableResult
    public func confirmExpireRight() async -> Bool {
        guard let resourceId = activeResourceId else {
            errorMessage = "No hay recurso activo."
            return false
        }
        do {
            _ = try await repository.expireRight(
                resourceId: resourceId,
                clientId: UUID().uuidString
            )
            await loadDetail(resourceId: resourceId)
            isConfirmingExpireRight = false
            return true
        } catch {
            errorMessage = UserFacingError.from(error).message
            return false
        }
    }
}

/// Valuation basis whitelist matching `record_asset_valuation.p_basis`
/// default + common conventions. Backend currently accepts any text;
/// the iOS surface narrows to a stable set so the picker stays sane.
public enum AssetValuationBasis: String, CaseIterable, Identifiable, Sendable, Hashable {
    case memberEstimate = "member_estimate"
    case invoice
    case kbb
    case other

    public var id: String { rawValue }

    public var label: LocalizedStringResource {
        switch self {
        case .memberEstimate: return L10n.RecordValuation.basisMemberEstimate
        case .invoice:        return L10n.RecordValuation.basisInvoice
        case .kbb:            return L10n.RecordValuation.basisKbb
        case .other:          return L10n.RecordValuation.basisOther
        }
    }
}
