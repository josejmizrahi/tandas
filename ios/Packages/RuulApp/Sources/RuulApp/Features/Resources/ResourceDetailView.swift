import SwiftUI
import RuulCore

/// Universal Detail (layered scroll, no segmented tabs) for a single
/// `GroupResource` envelope. 6 blocks render in order — Identity /
/// Context / Participation / Coordination / Activity / Actions. The
/// Coordination block dispatches sub-blocks per descriptor; asset
/// receives the real `AssetResponsibilitySection` (custodian + condition
/// + last valuation) while other sub-blocks remain Fase A stubs.
///
/// Doctrines applied: `ruul_universal_detail_layered_doctrine`,
/// `doctrine_resource_detail_v2`, `doctrine_button_styles`,
/// `doctrine_card_styles`, `doctrine_group_space_situational` (empty
/// sub-block = invisible).
public struct ResourceDetailView: View {
    @Bindable var store: ResourcesStore
    @Bindable var membersStore: MembersStore
    let groupId: UUID
    let resource: GroupResource
    let permissionsFetcher: (UUID) async throws -> [String]

    @Environment(\.dismiss) private var dismiss
    @State private var isConfirmingArchive: Bool = false
    @State private var callerPermissions: Set<String> = []

    public init(
        store: ResourcesStore,
        membersStore: MembersStore,
        groupId: UUID,
        resource: GroupResource,
        permissionsFetcher: @escaping (UUID) async throws -> [String] = { _ in [] }
    ) {
        self.store = store
        self.membersStore = membersStore
        self.groupId = groupId
        self.resource = resource
        self.permissionsFetcher = permissionsFetcher
    }

    /// Gate every action behind a known permission key. Defaults to
    /// false until the fetch finishes — tap-then-error is worse than
    /// briefly-missing-actions.
    private func can(_ key: String) -> Bool {
        callerPermissions.contains(key)
    }

    private var descriptor: ResourceTypeDescriptor { resource.resourceType.descriptor }

    /// Subtype data is loaded by `loadDetail` when the resource type
    /// has a dedicated subtype table. For `asset`, surfaces below read
    /// this lazily and gracefully tolerate `nil`.
    private var assetSubtype: AssetSubtypeData? {
        guard store.detail?.resource.id == resource.id else { return nil }
        return store.detail?.assetSubtype
    }

    private var fundSubtype: FundSubtypeData? {
        guard store.detail?.resource.id == resource.id else { return nil }
        return store.detail?.fundSubtype
    }

    private var spaceSubtype: SpaceSubtypeData? {
        guard store.detail?.resource.id == resource.id else { return nil }
        return store.detail?.spaceSubtype
    }

    private var rightSubtype: RightSubtypeData? {
        guard store.detail?.resource.id == resource.id else { return nil }
        return store.detail?.rightSubtype
    }

    private var slotSubtype: SlotSubtypeData? {
        guard store.detail?.resource.id == resource.id else { return nil }
        return store.detail?.slotSubtype
    }

    public var body: some View {
        List {
            identitySection
            contextSection
            participationSection
            coordinationSection
            activitySection
            actionsSection
        }
        .navigationTitle(L10n.ResourceDetail.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await membersStore.refreshIfNeeded(groupId: groupId)
            if descriptor.subtypeTable != nil {
                await store.loadDetail(resourceId: resource.id)
            }
            if resource.resourceType == .space {
                await store.refreshBookings(resourceId: resource.id)
            }
            await store.loadActivity(resourceId: resource.id, groupId: groupId)
            if descriptor.coordinationBlocks.contains(.money) {
                await store.loadMovements(resourceId: resource.id, groupId: groupId)
            }
            do {
                callerPermissions = Set(try await permissionsFetcher(groupId))
            } catch {
                callerPermissions = []
            }
        }
        .refreshable {
            if descriptor.subtypeTable != nil {
                await store.loadDetail(resourceId: resource.id)
            }
            if resource.resourceType == .space {
                await store.refreshBookings(resourceId: resource.id)
            }
            await store.loadActivity(resourceId: resource.id, groupId: groupId)
            if descriptor.coordinationBlocks.contains(.money) {
                await store.loadMovements(resourceId: resource.id, groupId: groupId)
            }
        }
        .confirmationDialog(
            Text(L10n.Resources.archiveConfirmTitle),
            isPresented: $isConfirmingArchive,
            titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                Task {
                    let ok = await store.archive(resourceId: resource.id, reason: nil, groupId: groupId)
                    // Only dismiss when the action actually executed; on
                    // `decisionOpened` the resource is still active.
                    if ok, case .directAllowed = store.lastGovernanceOutcome {
                        dismiss()
                    }
                }
            } label: {
                Text(L10n.Resources.archive)
            }
            Button(role: .cancel) {} label: { Text(L10n.Resources.cancel) }
        } message: {
            Text(L10n.Resources.archiveConfirmMessage)
        }
        .alert(
            "Se abrió una votación",
            isPresented: detailDecisionOpenedBinding,
            presenting: detailDecisionOpenedFromOutcome
        ) { _ in
            Button("Entendido", role: .cancel) { store.clearGovernanceOutcome() }
        } message: { _ in
            Text("Esta acción requiere decisión grupal. Se ejecutará cuando pase la votación.")
        }
        .confirmationDialog(
            Text(L10n.AssignCustodian.releaseConfirmTitle),
            isPresented: $store.isConfirmingReleaseCustodian,
            titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                Task { await store.confirmReleaseCustodian() }
            } label: {
                Text(L10n.AssignCustodian.releaseConfirm)
            }
            Button(role: .cancel) {} label: { Text(L10n.AssignCustodian.cancel) }
        } message: {
            Text(L10n.AssignCustodian.releaseConfirmBody)
        }
        .sheet(isPresented: $store.isTransferPresented) {
            TransferOwnershipSheet(
                store: store,
                membersStore: membersStore,
                groupId: groupId
            )
        }
        .sheet(isPresented: $store.isAssignCustodianPresented) {
            AssignCustodianSheet(
                store: store,
                membersStore: membersStore,
                groupId: groupId
            )
        }
        .sheet(isPresented: $store.isMarkConditionPresented) {
            MarkConditionSheet(store: store)
        }
        .sheet(isPresented: $store.isRecordValuationPresented) {
            RecordValuationSheet(store: store)
        }
        .sheet(isPresented: $store.isSetFundThresholdPresented) {
            SetFundThresholdSheet(store: store)
        }
        .sheet(isPresented: $store.isBookSpacePresented) {
            BookSpaceSheet(store: store)
        }
        .sheet(isPresented: $store.isGrantRightPresented) {
            GrantRightSheet(store: store, membersStore: membersStore, groupId: groupId)
        }
        .sheet(isPresented: $store.isTransferRightPresented) {
            TransferRightSheet(store: store, membersStore: membersStore, groupId: groupId)
        }
        .sheet(isPresented: $store.isAssignSlotPresented) {
            AssignSlotSheet(store: store, membersStore: membersStore, groupId: groupId)
        }
        .sheet(isPresented: $store.isEditMetadataPresented) {
            EditMetadataSheet(store: store, resource: resource, groupId: groupId)
        }
        .confirmationDialog(
            Text(L10n.AssignSlot.releaseConfirmTitle),
            isPresented: $store.isConfirmingReleaseSlot,
            titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                Task { await store.confirmReleaseSlot() }
            } label: {
                Text(L10n.AssignSlot.releaseConfirm)
            }
            Button(role: .cancel) {} label: { Text(L10n.AssignSlot.cancel) }
        } message: {
            Text(L10n.AssignSlot.releaseConfirmBody)
        }
        .confirmationDialog(
            Text(L10n.AssignSlot.expireConfirmTitle),
            isPresented: $store.isConfirmingExpireSlot,
            titleVisibility: .visible
        ) {
            Button {
                Task { await store.confirmExpireSlot() }
            } label: {
                Text(L10n.AssignSlot.expireConfirm)
            }
            Button(role: .cancel) {} label: { Text(L10n.AssignSlot.cancel) }
        } message: {
            Text(L10n.AssignSlot.expireConfirmBody)
        }
        .confirmationDialog(
            Text(L10n.GrantRight.revokeConfirmTitle),
            isPresented: $store.isConfirmingRevokeRight,
            titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                Task { await store.confirmRevokeRight() }
            } label: {
                Text(L10n.GrantRight.revokeConfirm)
            }
            Button(role: .cancel) {} label: { Text(L10n.GrantRight.cancel) }
        } message: {
            Text(L10n.GrantRight.revokeConfirmBody)
        }
        .confirmationDialog(
            Text(L10n.GrantRight.expireConfirmTitle),
            isPresented: $store.isConfirmingExpireRight,
            titleVisibility: .visible
        ) {
            Button {
                Task { await store.confirmExpireRight() }
            } label: {
                Text(L10n.GrantRight.expireConfirm)
            }
            Button(role: .cancel) {} label: { Text(L10n.GrantRight.cancel) }
        } message: {
            Text(L10n.GrantRight.expireConfirmBody)
        }
        .confirmationDialog(
            Text(L10n.BookSpace.cancelConfirmTitle),
            isPresented: $store.isConfirmingCancelBooking,
            titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                Task { await store.confirmCancelBooking() }
            } label: {
                Text(L10n.BookSpace.cancelConfirm)
            }
            Button(role: .cancel) {} label: { Text(L10n.BookSpace.cancel) }
        } message: {
            Text(L10n.BookSpace.cancelConfirmBody)
        }
        .confirmationDialog(
            Text(L10n.ResourceDetail.fundLockConfirmTitle),
            isPresented: $store.isConfirmingLockFund,
            titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                Task { await store.confirmLockFund() }
            } label: {
                Text(L10n.SetFundThreshold.confirmLock)
            }
            Button(role: .cancel) {} label: { Text(L10n.SetFundThreshold.cancel) }
        } message: {
            Text(L10n.ResourceDetail.fundLockConfirmBody)
        }
        .confirmationDialog(
            Text(L10n.ResourceDetail.fundUnlockConfirmTitle),
            isPresented: $store.isConfirmingUnlockFund,
            titleVisibility: .visible
        ) {
            Button {
                Task { await store.confirmUnlockFund() }
            } label: {
                Text(L10n.SetFundThreshold.confirmUnlock)
            }
            Button(role: .cancel) {} label: { Text(L10n.SetFundThreshold.cancel) }
        } message: {
            Text(L10n.ResourceDetail.fundUnlockConfirmBody)
        }
    }

    // MARK: - 1. Identity

    @ViewBuilder
    private var identitySection: some View {
        Section(L10n.ResourceDetail.identitySection) {
            VStack(spacing: 12) {
                Image(systemName: descriptor.icon)
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 80, height: 80)
                    .background(.thinMaterial, in: Circle())

                VStack(spacing: 4) {
                    Text(resource.name)
                        .font(.title2.weight(.semibold))
                        .multilineTextAlignment(.center)
                    Text(descriptor.label)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(descriptor.subtitle)
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    // MARK: - 2. Context

    @ViewBuilder
    private var contextSection: some View {
        Section(L10n.ResourceDetail.contextSection) {
            if resource.previewText.isEmpty {
                Text(L10n.ResourceDetail.descriptionEmpty)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text(resource.previewText)
                    .font(.body)
            }

            LabeledContent {
                Text(resource.resourceType.label)
            } label: {
                Text(L10n.ResourceDetail.typeLabel)
            }
            LabeledContent {
                Text(resource.ownershipKind.label)
            } label: {
                Text(L10n.ResourceDetail.ownershipLabel)
            }
            LabeledContent {
                Text(resource.visibility.label)
            } label: {
                Text(L10n.ResourceDetail.visibilityLabel)
            }
            LabeledContent {
                Text(resource.status.capitalized)
            } label: {
                Text(L10n.ResourceDetail.statusLabel)
            }
            if let created = resource.createdAt {
                LabeledContent {
                    Text(created, format: .dateTime.day().month().year())
                } label: {
                    Text(L10n.ResourceDetail.createdAtLabel)
                }
            }
            if let updated = resource.updatedAt, updated != resource.createdAt {
                LabeledContent {
                    Text(updated, format: .dateTime.day().month().year())
                } label: {
                    Text(L10n.ResourceDetail.updatedAtLabel)
                }
            }

            ForEach(descriptor.metadataSchema) { field in
                if let value = resource.metadataString(forKey: field.key) {
                    LabeledContent {
                        Text(value)
                            .multilineTextAlignment(.trailing)
                    } label: {
                        Text(field.label)
                    }
                }
            }
        }
    }

    // MARK: - 3. Participation

    @ViewBuilder
    private var participationSection: some View {
        Section(L10n.ResourceDetail.participationSection) {
            Label {
                Text(L10n.ResourceDetail.participationStub)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 4. Coordination (descriptor-gated sub-blocks)

    @ViewBuilder
    private var coordinationSection: some View {
        Section(L10n.ResourceDetail.coordinationSection) {
            ForEach(CoordinationBlockKind.renderOrder, id: \.self) { kind in
                if descriptor.coordinationBlocks.contains(kind) {
                    coordinationRow(kind)
                }
            }
        }
    }

    @ViewBuilder
    private func coordinationRow(_ kind: CoordinationBlockKind) -> some View {
        switch (resource.resourceType, kind) {
        case (.asset, .responsibility):
            AssetResponsibilitySection(
                subtype: assetSubtype,
                custodianMember: custodianMember(for: assetSubtype)
            )
        case (.fund, .money):
            FundMoneySection(subtype: fundSubtype, movements: store.movements)
        case (_, .money):
            ResourceMoneyMovementsSection(movements: store.movements)
        case (.space, .schedule):
            SpaceScheduleSection(
                subtype: spaceSubtype,
                bookings: store.bookings,
                phase: store.bookingsPhase,
                onCancel: { store.presentCancelBooking($0) }
            )
        case (.right, .access):
            RightAccessSection(
                subtype: rightSubtype,
                holderMember: rightHolderMember(for: rightSubtype)
            )
        case (.slot, .responsibility):
            SlotResponsibilitySection(
                subtype: slotSubtype,
                assignedMember: slotAssignedMember(for: slotSubtype)
            )
        default:
            stubCoordinationRow(kind)
        }
    }

    private func slotAssignedMember(for subtype: SlotSubtypeData?) -> MembershipBoundaryItem? {
        guard let mid = subtype?.assignedMembershipId else { return nil }
        return membersStore.items.first(where: { $0.membershipId == mid })
    }

    private func rightHolderMember(for subtype: RightSubtypeData?) -> MembershipBoundaryItem? {
        guard let mid = subtype?.holderMembershipId else { return nil }
        return membersStore.items.first(where: { $0.membershipId == mid })
    }

    @ViewBuilder
    private func stubCoordinationRow(_ kind: CoordinationBlockKind) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.label)
                    .font(.body.weight(.medium))
                Text(L10n.ResourceDetail.coordinationStub)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: kind.systemImageName)
                .foregroundStyle(.tint)
        }
    }

    private func custodianMember(for subtype: AssetSubtypeData?) -> MembershipBoundaryItem? {
        guard let mid = subtype?.custodianMembershipId else { return nil }
        return membersStore.items.first(where: { $0.membershipId == mid })
    }

    // MARK: - 5. Activity

    @ViewBuilder
    private var activitySection: some View {
        Section(L10n.ResourceDetail.activitySection) {
            if store.activity.isEmpty {
                Label {
                    Text(L10n.ResourceDetail.activityStub)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(store.activity.prefix(15)) { event in
                    activityRow(event)
                }
            }
        }
    }

    @ViewBuilder
    private func activityRow(_ event: GroupEvent) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: activityIcon(for: event.eventType))
                .font(.body.weight(.medium))
                .foregroundStyle(.tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(activityLabel(for: event.eventType))
                    .font(.body.weight(.medium))
                if let summary = event.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let occurredAt = event.occurredAt {
                    Text(occurredAt, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func activityIcon(for eventType: String) -> String {
        switch eventType {
        case "resource.created":         return "plus.circle"
        case "resource.archived":        return "archivebox"
        case "resource.assigned":        return "person.crop.circle.badge.checkmark"
        case "resource.returned":        return "arrow.uturn.backward.circle"
        case "resource.transferred":     return "arrow.left.arrow.right.circle"
        case "resource.used":            return "play.circle"
        case "resource.damaged":         return "exclamationmark.triangle"
        case "resource.repaired":        return "wrench.adjustable"
        case "resource.value_updated":   return "dollarsign.circle"
        case "resource.status_changed":  return "arrow.triangle.2.circlepath"
        case "resource.updated":         return "pencil.circle"
        case "booking.created":          return "calendar.badge.plus"
        case "booking.cancelled":        return "calendar.badge.minus"
        default:                         return "circle"
        }
    }

    private func activityLabel(for eventType: String) -> String {
        switch eventType {
        case "resource.created":         return "Creado"
        case "resource.archived":        return "Archivado"
        case "resource.assigned":        return "Asignado"
        case "resource.returned":        return "Liberado"
        case "resource.transferred":     return "Transferido"
        case "resource.used":            return "Uso registrado"
        case "resource.damaged":         return "Marcado como dañado"
        case "resource.repaired":        return "Reparado"
        case "resource.value_updated":   return "Valuación actualizada"
        case "resource.status_changed":  return "Cambio de estado"
        case "resource.updated":         return "Campos actualizados"
        case "booking.created":          return "Reservado"
        case "booking.cancelled":        return "Reserva cancelada"
        default:                         return eventType
        }
    }

    // MARK: - 6. Actions

    @ViewBuilder
    private var actionsSection: some View {
        Section(L10n.ResourceDetail.actionsSection) {
            if descriptor.supportsCustody, can("resources.update") {
                if assetSubtype?.custodianMembershipId == nil {
                    Button {
                        store.presentAssignCustodian(seed: assetSubtype)
                    } label: {
                        Label(L10n.ResourceDetail.assetAssignCustodian, systemImage: "person.crop.circle.badge.plus")
                    }
                } else {
                    Button {
                        store.presentAssignCustodian(seed: assetSubtype)
                    } label: {
                        Label(L10n.ResourceDetail.assetReassignCustodian, systemImage: "person.crop.circle.badge.checkmark")
                    }
                    Button(role: .destructive) {
                        store.presentReleaseCustodian()
                    } label: {
                        Label(L10n.ResourceDetail.assetReleaseCustodian, systemImage: "person.crop.circle.badge.minus")
                    }
                }
                Button {
                    store.presentMarkCondition(seed: assetSubtype)
                } label: {
                    Label(L10n.ResourceDetail.assetMarkCondition, systemImage: "wrench.and.screwdriver")
                }
            }
            if descriptor.supportsValuation, can("resources.update_value") {
                Button {
                    store.presentRecordValuation(seed: assetSubtype)
                } label: {
                    Label(L10n.ResourceDetail.assetRecordValuation, systemImage: "dollarsign.circle")
                }
            }
            if descriptor.supportsBooking, resource.resourceType == .space, can("bookings.create") {
                Button {
                    store.presentBookSpace()
                } label: {
                    Label(L10n.ResourceDetail.spaceBookAction, systemImage: "calendar.badge.plus")
                }
            }
            if resource.resourceType == .slot, can("resources.update") {
                let slotState = slotSubtype?.lifecycleState ?? .unassigned
                Button {
                    store.presentAssignSlot(seed: slotSubtype)
                } label: {
                    Label(
                        slotState == .assigned ? L10n.ResourceDetail.slotReassignAction
                                               : L10n.ResourceDetail.slotAssignAction,
                        systemImage: slotState == .assigned
                            ? "person.crop.circle.badge.checkmark"
                            : "person.crop.circle.badge.plus"
                    )
                }
                if slotState == .assigned {
                    Button(role: .destructive) {
                        store.presentReleaseSlot()
                    } label: {
                        Label(L10n.ResourceDetail.slotReleaseAction, systemImage: "person.crop.circle.badge.minus")
                    }
                }
                if slotState != .expired,
                   let ends = slotSubtype?.slotEndsAt, ends <= Date() {
                    Button(role: .destructive) {
                        store.presentExpireSlot()
                    } label: {
                        Label(L10n.ResourceDetail.slotExpireAction, systemImage: "hourglass")
                    }
                }
            }
            if resource.resourceType == .right, can("resources.update") {
                let state = rightSubtype?.lifecycleState ?? .unassigned
                Button {
                    store.presentGrantRight(seed: rightSubtype)
                } label: {
                    Label(
                        state == .active ? L10n.ResourceDetail.rightRegrantAction
                                         : L10n.ResourceDetail.rightGrantAction,
                        systemImage: state == .active
                            ? "person.crop.circle.badge.checkmark"
                            : "key.horizontal"
                    )
                }
                if state == .active, rightSubtype?.transferable == true {
                    Button {
                        store.presentTransferRight()
                    } label: {
                        Label(L10n.ResourceDetail.rightTransferAction, systemImage: "arrow.left.arrow.right")
                    }
                }
                if state == .active {
                    Button(role: .destructive) {
                        store.presentRevokeRight()
                    } label: {
                        Label(L10n.ResourceDetail.rightRevokeAction, systemImage: "xmark.shield")
                    }
                    if let expires = rightSubtype?.expiresAt, expires <= Date() {
                        Button(role: .destructive) {
                            store.presentExpireRight()
                        } label: {
                            Label(L10n.ResourceDetail.rightExpireAction, systemImage: "hourglass")
                        }
                    }
                }
            }
            if descriptor.supportsLocking, can("resources.update") {
                Button {
                    store.presentSetFundThreshold(seed: fundSubtype)
                } label: {
                    Label(L10n.ResourceDetail.fundSetThresholdAction, systemImage: "target")
                }
                if fundSubtype?.isLocked == true {
                    Button {
                        store.presentUnlockFund()
                    } label: {
                        Label(L10n.ResourceDetail.fundUnlockAction, systemImage: "lock.open")
                    }
                } else {
                    Button {
                        store.presentLockFund()
                    } label: {
                        Label(L10n.ResourceDetail.fundLockAction, systemImage: "lock")
                    }
                }
            }
            if !descriptor.metadataSchema.isEmpty, can("resources.update") {
                Button {
                    store.presentEditMetadata(resource: resource)
                } label: {
                    Label(L10n.ResourceDetail.editMetadataAction, systemImage: "pencil")
                }
            }
            if can("resources.transfer") {
                Button {
                    store.beginTransferring(resource)
                } label: {
                    Label(L10n.ResourceDetail.transferAction, systemImage: "arrow.left.arrow.right")
                }
            }
            if can("resources.archive") {
                Button(role: .destructive) {
                    isConfirmingArchive = true
                } label: {
                    Label(L10n.ResourceDetail.archiveAction, systemImage: "archivebox")
                }
            }
        }
    }

    /// D.22 — surfaces `lastGovernanceOutcome.decisionOpened` for archive
    /// + transfer flows so the user sees an alert instead of a silent
    /// non-action.
    private var detailDecisionOpenedBinding: Binding<Bool> {
        Binding(
            get: { detailDecisionOpenedFromOutcome != nil },
            set: { newValue in
                if !newValue { store.clearGovernanceOutcome() }
            }
        )
    }

    private var detailDecisionOpenedFromOutcome: DecisionOpenedDetails? {
        if case .decisionOpened(let details) = store.lastGovernanceOutcome {
            return details
        }
        return nil
    }
}

// MARK: - AssetResponsibilitySection

/// Real Coordination > Responsibility block for `asset`. Surfaces
/// current custodian, condition badge and last recorded valuation
/// (from the asset subtype row). Empty cluster collapses by row when
/// no data is present.
private struct AssetResponsibilitySection: View {
    let subtype: AssetSubtypeData?
    let custodianMember: MembershipBoundaryItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: "person.badge.shield.checkmark")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.tint)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.ResourceDetail.assetCustodianLabel)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(custodianText)
                        .font(.body.weight(.semibold))
                }
            }
            if let condition = subtype?.condition {
                HStack(spacing: 12) {
                    Image(systemName: condition.systemImageName)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.tint)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.ResourceDetail.assetConditionLabel)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text(condition.label)
                            .font(.body.weight(.semibold))
                    }
                }
            }
            if let value = subtype?.currentValue {
                HStack(spacing: 12) {
                    Image(systemName: "dollarsign.circle")
                        .font(.body.weight(.medium))
                        .foregroundStyle(.tint)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.ResourceDetail.assetValuationLabel)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text(valuationText(value: value, unit: subtype?.currentValueUnit))
                            .font(.body.weight(.semibold))
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var custodianText: String {
        custodianMember?.displayName ?? String(localized: L10n.ResourceDetail.assetCustodianNone)
    }

    private func valuationText(value: Decimal, unit: String?) -> String {
        let amount = NSDecimalNumber(decimal: value).stringValue
        if let unit, !unit.isEmpty {
            return "\(amount) \(unit)"
        }
        return amount
    }
}

// MARK: - FundMoneySection

/// Real Coordination > Money block for `fund`. Surfaces lock status,
/// fund kind, currency and threshold target (when defined). Empty
/// cluster collapses by row when no data is present.
private struct FundMoneySection: View {
    let subtype: FundSubtypeData?
    let movements: [MoneyMovement]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: subtype?.isLocked == true ? "lock.fill" : "lock.open")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.tint)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(subtype?.isLocked == true ? L10n.ResourceDetail.fundLockedBadge : L10n.ResourceDetail.fundUnlockedBadge)
                        .font(.body.weight(.semibold))
                    if let lockedAt = subtype?.lockedAt {
                        Text(lockedAt, format: .dateTime.day().month().year())
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let kind = subtype?.fundKind {
                HStack(spacing: 12) {
                    Image(systemName: "tag")
                        .font(.body.weight(.medium))
                        .foregroundStyle(.tint)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.ResourceDetail.fundKindLabel)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text(kind.label)
                            .font(.body.weight(.semibold))
                    }
                }
            }
            if let currency = subtype?.currency, !currency.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "dollarsign.circle")
                        .font(.body.weight(.medium))
                        .foregroundStyle(.tint)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.ResourceDetail.fundCurrencyLabel)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text(currency)
                            .font(.body.weight(.semibold))
                    }
                }
            }
            HStack(spacing: 12) {
                Image(systemName: "target")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.tint)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.ResourceDetail.fundThresholdLabel)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(thresholdText)
                        .font(.body.weight(.semibold))
                }
            }
            if !movements.isEmpty {
                Divider()
                    .padding(.vertical, 4)
                ResourceMoneyMovementsSection(movements: movements)
            }
        }
        .padding(.vertical, 4)
    }

    private var thresholdText: String {
        guard let value = subtype?.thresholdTarget else {
            return String(localized: L10n.ResourceDetail.fundThresholdNone)
        }
        let amount = NSDecimalNumber(decimal: value).stringValue
        if let currency = subtype?.currency, !currency.isEmpty {
            return "\(amount) \(currency)"
        }
        return amount
    }
}

// MARK: - ResourceMoneyMovementsSection

/// Shared Money block for resource types that carry monetary movements
/// without a dedicated subtype (asset/inventory/real_estate/IP/vehicle
/// /points/money). Surfaces the top 3 movements linked via resource_id
/// or source_resource_id.
private struct ResourceMoneyMovementsSection: View {
    let movements: [MoneyMovement]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Image(systemName: "creditcard")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.tint)
                    .frame(width: 24)
                Text(L10n.ResourceDetail.coordinationMoney)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if movements.isEmpty {
                Text(L10n.ResourceDetail.coordinationStub)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 36)
            } else {
                ForEach(movements.prefix(3)) { movement in
                    movementRow(movement)
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func movementRow(_ movement: MoneyMovement) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "arrow.up.arrow.down.circle")
                .font(.body.weight(.medium))
                .foregroundStyle(.tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(NSDecimalNumber(decimal: movement.amount).stringValue) \(movement.unit)")
                    .font(.body.weight(.semibold))
                Text(movement.type.rawValue.capitalized)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let description = movement.description, !description.isEmpty {
                    Text(description)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }
}

// MARK: - SpaceScheduleSection

/// Real Coordination > Schedule block for `space`. Surfaces address /
/// capacity / rules + upcoming confirmed bookings (filtered against
/// cancellation audit rows). Empty rows collapse per the situational
/// doctrine.
private struct SpaceScheduleSection: View {
    let subtype: SpaceSubtypeData?
    let bookings: [GroupResourceBooking]
    let phase: StorePhase
    let onCancel: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let address = subtype?.address, !address.isEmpty {
                row(icon: "mappin.and.ellipse",
                    label: L10n.ResourceDetail.spaceAddressLabel,
                    value: address)
            }
            if let capacity = subtype?.capacity {
                row(icon: "person.2",
                    label: L10n.ResourceDetail.spaceCapacityLabel,
                    value: "\(capacity)")
            }
            if let rules = subtype?.rules, !rules.isEmpty {
                row(icon: "list.bullet.rectangle",
                    label: L10n.ResourceDetail.spaceRulesLabel,
                    value: rules)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    Image(systemName: "calendar")
                        .font(.body.weight(.medium))
                        .foregroundStyle(.tint)
                        .frame(width: 24)
                    Text(L10n.ResourceDetail.spaceUpcomingLabel)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if upcomingActive.isEmpty {
                    Text(L10n.ResourceDetail.spaceUpcomingNone)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 36)
                } else {
                    ForEach(upcomingActive) { booking in
                        bookingRow(booking)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var upcomingActive: [GroupResourceBooking] {
        let cancelled = Set(bookings.compactMap { $0.status == .cancelled ? $0.id : nil })
        return bookings
            .filter { $0.status == .confirmed && !cancelled.contains($0.id) }
            .sorted(by: { $0.startsAt < $1.startsAt })
            .prefix(5)
            .map { $0 }
    }

    @ViewBuilder
    private func row(icon: String, label: LocalizedStringResource, value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.body.weight(.medium))
                .foregroundStyle(.tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.body.weight(.semibold))
                    .multilineTextAlignment(.leading)
            }
        }
    }

    @ViewBuilder
    private func bookingRow(_ booking: GroupResourceBooking) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "calendar.badge.clock")
                .font(.body.weight(.medium))
                .foregroundStyle(.tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(booking.startsAt, format: .dateTime.weekday().day().month().hour().minute())
                    .font(.body.weight(.semibold))
                if let ends = booking.endsAt {
                    Text(ends, format: .dateTime.hour().minute())
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let reason = booking.reason, !reason.isEmpty {
                    Text(reason)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Button(role: .destructive) {
                onCancel(booking.id)
            } label: {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel(Text(L10n.BookSpace.cancelAction))
        }
    }
}

// MARK: - RightAccessSection

/// Real Coordination > Access block for `right`. Surfaces holder +
/// right_kind + expires_at + transferable + conditions + lifecycle
/// status. Empty rows collapse per the situational doctrine.
private struct RightAccessSection: View {
    let subtype: RightSubtypeData?
    let holderMember: MembershipBoundaryItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: statusIcon)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.tint)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusLabel)
                        .font(.body.weight(.semibold))
                    if let grantedAt = subtype?.grantedAt {
                        Text(grantedAt, format: .dateTime.day().month().year())
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            HStack(spacing: 12) {
                Image(systemName: "person.crop.circle")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.tint)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.ResourceDetail.rightHolderLabel)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(holderText)
                        .font(.body.weight(.semibold))
                }
            }
            if let kind = subtype?.rightKind, !kind.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "tag")
                        .font(.body.weight(.medium))
                        .foregroundStyle(.tint)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.ResourceDetail.rightKindLabel)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text(kindLabel(kind))
                            .font(.body.weight(.semibold))
                    }
                }
            }
            HStack(spacing: 12) {
                Image(systemName: "hourglass")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.tint)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.ResourceDetail.rightExpiresLabel)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    expiresContent
                }
            }
            HStack(spacing: 12) {
                Image(systemName: (subtype?.transferable == true) ? "arrow.left.arrow.right" : "lock")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.tint)
                    .frame(width: 24)
                Text((subtype?.transferable == true)
                     ? L10n.ResourceDetail.rightTransferableYes
                     : L10n.ResourceDetail.rightTransferableNo)
                    .font(.body.weight(.semibold))
            }
            if let conditions = subtype?.conditions, !conditions.isEmpty {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "doc.plaintext")
                        .font(.body.weight(.medium))
                        .foregroundStyle(.tint)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.ResourceDetail.rightConditionsLabel)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text(conditions)
                            .font(.body)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var statusLabel: LocalizedStringResource {
        switch subtype?.lifecycleState ?? .unassigned {
        case .active:     return L10n.ResourceDetail.rightStatusActive
        case .expired:    return L10n.ResourceDetail.rightStatusExpired
        case .revoked:    return L10n.ResourceDetail.rightStatusRevoked
        case .unassigned: return L10n.ResourceDetail.rightStatusUnassigned
        }
    }

    private var statusIcon: String {
        switch subtype?.lifecycleState ?? .unassigned {
        case .active:     return "checkmark.shield"
        case .expired:    return "hourglass.tophalf.filled"
        case .revoked:    return "xmark.shield"
        case .unassigned: return "person.crop.circle.badge.questionmark"
        }
    }

    private var holderText: String {
        holderMember?.displayName ?? String(localized: L10n.ResourceDetail.rightHolderNone)
    }

    @ViewBuilder
    private var expiresContent: some View {
        if let expires = subtype?.expiresAt {
            Text(expires, format: .dateTime.day().month().year().hour().minute())
                .font(.body.weight(.semibold))
        } else {
            Text(L10n.ResourceDetail.rightExpiresNone)
                .font(.body.weight(.semibold))
        }
    }

    private func kindLabel(_ rawKind: String) -> String {
        if let known = ResourceRightKind(rawValue: rawKind) {
            return String(localized: known.label)
        }
        return rawKind
    }
}

// MARK: - SlotResponsibilitySection

/// Real Coordination > Responsibility block for `slot`. Surfaces slot
/// window + assigned member + lifecycle status. Empty rows collapse
/// per the situational doctrine.
private struct SlotResponsibilitySection: View {
    let subtype: SlotSubtypeData?
    let assignedMember: MembershipBoundaryItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: statusIcon)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.tint)
                    .frame(width: 24)
                Text(statusLabel)
                    .font(.body.weight(.semibold))
            }
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "calendar.badge.clock")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.tint)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.ResourceDetail.slotWindowLabel)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    windowContent
                }
            }
            HStack(spacing: 12) {
                Image(systemName: "person.crop.circle")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.tint)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.ResourceDetail.slotAssigneeLabel)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(assigneeText)
                        .font(.body.weight(.semibold))
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var statusLabel: LocalizedStringResource {
        switch subtype?.lifecycleState ?? .unassigned {
        case .unassigned: return L10n.ResourceDetail.slotStatusUnassigned
        case .assigned:   return L10n.ResourceDetail.slotStatusAssigned
        case .released:   return L10n.ResourceDetail.slotStatusReleased
        case .expired:    return L10n.ResourceDetail.slotStatusExpired
        }
    }

    private var statusIcon: String {
        switch subtype?.lifecycleState ?? .unassigned {
        case .unassigned: return "circle.dashed"
        case .assigned:   return "checkmark.circle"
        case .released:   return "arrow.uturn.backward.circle"
        case .expired:    return "hourglass.tophalf.filled"
        }
    }

    @ViewBuilder
    private var windowContent: some View {
        if let starts = subtype?.slotStartsAt {
            VStack(alignment: .leading, spacing: 2) {
                Text(starts, format: .dateTime.weekday().day().month().hour().minute())
                    .font(.body.weight(.semibold))
                if let ends = subtype?.slotEndsAt {
                    Text(ends, format: .dateTime.weekday().day().month().hour().minute())
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            Text(L10n.ResourceDetail.slotWindowNone)
                .font(.body.weight(.semibold))
        }
    }

    private var assigneeText: String {
        assignedMember?.displayName ?? String(localized: L10n.ResourceDetail.slotAssigneeNone)
    }
}
