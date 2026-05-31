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
        }
        .refreshable {
            if descriptor.subtypeTable != nil {
                await store.loadDetail(resourceId: resource.id)
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
