import SwiftUI
import RuulCore

/// Detail surface for a single `GroupResource` envelope (Primitiva 5).
/// Read-only Foundation slice — identity hero + descripción + detalles
/// (type/ownership/visibility/timestamps) + actividad placeholder +
/// acciones (Archivar). Subtype-specific fields (fund balance, space
/// booking calendar, asset custody history, document attachments) are
/// deferred to dedicated slices.
///
/// Pattern: Wallet card hero + grouped sections. Empty sections collapse
/// per `doctrine_group_space_situational`.
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

    public var body: some View {
        List {
            heroSection
            aboutSection
            detailsSection
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

    // MARK: - Hero

    @ViewBuilder
    private var heroSection: some View {
        Section {
            VStack(spacing: 12) {
                Image(systemName: resource.resourceType.systemImageName)
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 80, height: 80)
                    .background(.thinMaterial, in: Circle())

                VStack(spacing: 4) {
                    Text(resource.name)
                        .font(.title2.weight(.semibold))
                        .multilineTextAlignment(.center)
                    Text(resource.resourceType.label)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    // MARK: - About

    @ViewBuilder
    private var aboutSection: some View {
        Section(L10n.ResourceDetail.aboutSection) {
            if resource.previewText.isEmpty {
                Text(L10n.ResourceDetail.aboutEmpty)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text(resource.previewText)
                    .font(.body)
            }
        }
    }

    // MARK: - Details

    @ViewBuilder
    private var detailsSection: some View {
        Section(L10n.ResourceDetail.detailsSection) {
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
        }
    }

    // MARK: - Activity (placeholder)

    @ViewBuilder
    private var activitySection: some View {
        Section(L10n.ResourceDetail.activitySection) {
            Text(L10n.ResourceDetail.activityPlaceholder)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

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
