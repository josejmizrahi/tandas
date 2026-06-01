import SwiftUI
import RuulCore

/// Full list of active mandates for a group (Primitiva 23), grouped
/// by `mandate_type` in canonical display order. Toolbar add =
/// grant; row swipe = revoke (admin gate handled by backend perm).
public struct MandatesListView: View {
    @Bindable var store: MandatesStore
    @Bindable var membersStore: MembersStore
    let groupId: UUID

    @State private var toRevoke: GroupMandate?

    public init(store: MandatesStore, membersStore: MembersStore, groupId: UUID) {
        self.store = store
        self.membersStore = membersStore
        self.groupId = groupId
    }

    public var body: some View {
        List {
            content
        }
        .navigationTitle(L10n.Mandates.title)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await store.refresh(groupId: groupId)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    store.beginGranting()
                } label: {
                    Label(L10n.Mandates.addButton, systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $store.isGrantPresented) {
            GrantMandateSheet(store: store, membersStore: membersStore, groupId: groupId)
        }
        .confirmationDialog(
            Text(L10n.Mandates.revokeConfirmTitle),
            isPresented: revokeDialogBinding,
            titleVisibility: .visible,
            presenting: toRevoke
        ) { mandate in
            Button(role: .destructive) {
                Task { await store.revoke(mandateId: mandate.id, reason: nil, groupId: groupId) }
            } label: {
                Text(L10n.Mandates.revokeAction)
            }
            Button(role: .cancel) {} label: { Text(L10n.Mandates.cancel) }
        } message: { _ in
            Text(L10n.Mandates.revokeConfirmMessage)
        }
        .task {
            await store.refreshIfNeeded(groupId: groupId)
            await membersStore.refreshIfNeeded(groupId: groupId)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch store.phase {
        case .idle, .loading:
            ForEach(0..<3, id: \.self) { _ in placeholderRow }
        case .failed(let message):
            ContentUnavailableView {
                Label(L10n.Mandates.errorTitle, systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button(String(localized: L10n.Mandates.retry)) {
                    Task { await store.refresh(groupId: groupId) }
                }
            }
            .listRowBackground(Color.clear)
        case .loaded:
            if !store.hasMandates {
                ContentUnavailableView {
                    Label(L10n.Mandates.emptyTitle, systemImage: "person.crop.rectangle.badge.checkmark")
                } description: {
                    Text(L10n.Mandates.emptyDescription)
                } actions: {
                    Button {
                        store.beginGranting()
                    } label: {
                        Text(L10n.Mandates.addButton)
                    }
                    .buttonStyle(.glassProminent)
                }
                .listRowBackground(Color.clear)
            } else {
                loadedSections
            }
        }
    }

    @ViewBuilder
    private var loadedSections: some View {
        ForEach(MandateType.displayOrder, id: \.self) { type in
            if let bucket = store.mandatesByType[type], !bucket.isEmpty {
                Section {
                    ForEach(bucket) { mandate in
                        row(for: mandate)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    toRevoke = mandate
                                } label: {
                                    Label(
                                        String(localized: L10n.Mandates.revokeAction),
                                        systemImage: "xmark.circle"
                                    )
                                }
                            }
                    }
                } header: {
                    Label(type.label, systemImage: type.systemImageName)
                }
            }
        }
    }

    @ViewBuilder
    private func row(for mandate: GroupMandate) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(mandate.representativeDisplayName ?? "Miembro")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
                Text(mandate.principalType.label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(.quaternary))
            }
            if let endsAt = mandate.endsAt {
                Text("Vence \(endsAt.formatted(.dateTime.day().month().year()))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                Text(L10n.Mandates.openEndedHint)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            if let who = mandate.grantedByDisplayName, !who.isEmpty {
                Text("Otorgó \(who)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private var revokeDialogBinding: Binding<Bool> {
        Binding(
            get: { toRevoke != nil },
            set: { if !$0 { toRevoke = nil } }
        )
    }

    @ViewBuilder
    private var placeholderRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Placeholder representante").font(.body.weight(.semibold))
            Text("Placeholder principal").font(.caption).foregroundStyle(.secondary)
        }
        .redacted(reason: .placeholder)
    }
}
