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

    @Environment(\.dismiss) private var dismiss
    @State private var isConfirmingArchive: Bool = false

    public init(
        store: ResourcesStore,
        membersStore: MembersStore,
        groupId: UUID,
        resource: GroupResource
    ) {
        self.store = store
        self.membersStore = membersStore
        self.groupId = groupId
        self.resource = resource
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
        }
        .refreshable {
            if descriptor.subtypeTable != nil {
                await store.loadDetail(resourceId: resource.id)
            }
            if resource.resourceType == .space {
                await store.refreshBookings(resourceId: resource.id)
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
                    if ok { dismiss() }
                }
            } label: {
                Text(L10n.Resources.archive)
            }
            Button(role: .cancel) {} label: { Text(L10n.Resources.cancel) }
        } message: {
            Text(L10n.Resources.archiveConfirmMessage)
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
            FundMoneySection(subtype: fundSubtype)
        case (.space, .schedule):
            SpaceScheduleSection(
                subtype: spaceSubtype,
                bookings: store.bookings,
                phase: store.bookingsPhase,
                onCancel: { store.presentCancelBooking($0) }
            )
        default:
            stubCoordinationRow(kind)
        }
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
            Label {
                Text(L10n.ResourceDetail.activityStub)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 6. Actions

    @ViewBuilder
    private var actionsSection: some View {
        Section(L10n.ResourceDetail.actionsSection) {
            if descriptor.supportsCustody {
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
            if descriptor.supportsValuation {
                Button {
                    store.presentRecordValuation(seed: assetSubtype)
                } label: {
                    Label(L10n.ResourceDetail.assetRecordValuation, systemImage: "dollarsign.circle")
                }
            }
            if descriptor.supportsBooking, resource.resourceType == .space {
                Button {
                    store.presentBookSpace()
                } label: {
                    Label(L10n.ResourceDetail.spaceBookAction, systemImage: "calendar.badge.plus")
                }
            }
            if descriptor.supportsLocking {
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
            Button {
                store.beginTransferring(resource)
            } label: {
                Label(L10n.ResourceDetail.transferAction, systemImage: "arrow.left.arrow.right")
            }
            Button(role: .destructive) {
                isConfirmingArchive = true
            } label: {
                Label(L10n.ResourceDetail.archiveAction, systemImage: "archivebox")
            }
        }
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
