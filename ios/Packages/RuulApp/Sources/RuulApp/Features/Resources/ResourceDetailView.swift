import SwiftUI
import RuulCore

/// Universal Detail (layered scroll, no segmented tabs) for a single
/// `GroupResource` envelope. Fase A: 6 blocks render in order —
/// Identity / Context / Participation / Coordination / Activity /
/// Actions. The Coordination block is a dispatcher; sub-blocks
/// (`money`, `schedule`, `access`, `responsibility`, `rules`, `usage`)
/// only render when the resource's
/// `descriptor.coordinationBlocks.contains(.kind)`. Per-type sheets
/// (valuation, booking, lock, lifecycle event) land in Fase B/C; this
/// surface ships their headers + placeholders so the layered shape is
/// stable and visible to founders.
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
        .sheet(isPresented: $store.isTransferPresented) {
            TransferOwnershipSheet(
                store: store,
                membersStore: membersStore,
                groupId: groupId
            )
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

            // Per-type metadata fields driven by the descriptor schema.
            // Empty values stay invisible (situational doctrine).
            ForEach(descriptor.metadataSchema, id: \.key) { field in
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
        // Fase A: stub row per sub-block. Fase B/C wires real surfaces
        // (Money pool balance, schedule bookings, access rules, etc.).
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
