import SwiftUI
import RuulCore

/// Full list of active cultural norms for a group (Primitiva 20),
/// grouped by `norm_type` in canonical display order. Toolbar add =
/// propose; row swipe (or context menu) = endorse / retirar.
public struct CulturalNormsListView: View {
    @Bindable var store: CulturalNormsStore
    let groupId: UUID
    let onPromotedToRule: (() -> Void)?

    @State private var toRetire: GroupCulturalNorm?
    @State private var toPromote: GroupCulturalNorm?

    public init(
        store: CulturalNormsStore,
        groupId: UUID,
        onPromotedToRule: (() -> Void)? = nil
    ) {
        self.store = store
        self.groupId = groupId
        self.onPromotedToRule = onPromotedToRule
    }

    public var body: some View {
        List {
            content
        }
        .navigationTitle(L10n.CulturalNorms.title)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await store.refresh(groupId: groupId)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    store.beginCreating()
                } label: {
                    Label(L10n.CulturalNorms.addButton, systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $store.isCreatePresented) {
            EditCulturalNormView(store: store, groupId: groupId)
        }
        .sheet(item: $toPromote) { norm in
            PromoteNormToRuleSheet(
                store: store,
                groupId: groupId,
                norm: norm,
                onSuccess: { _ in
                    onPromotedToRule?()
                }
            )
        }
        .confirmationDialog(
            Text(L10n.CulturalNorms.retireConfirmTitle),
            isPresented: retireDialogBinding,
            titleVisibility: .visible,
            presenting: toRetire
        ) { norm in
            Button(role: .destructive) {
                Task { await store.retire(normId: norm.id, reason: nil, groupId: groupId) }
            } label: {
                Text(L10n.CulturalNorms.retireAction)
            }
            Button(role: .cancel) {} label: { Text(L10n.CulturalNorms.cancel) }
        } message: { _ in
            Text(L10n.CulturalNorms.retireConfirmMessage)
        }
        .task {
            await store.refreshIfNeeded(groupId: groupId)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch store.phase {
        case .idle, .loading:
            ForEach(0..<3, id: \.self) { _ in placeholderRow }
        case .failed(let message):
            ContentUnavailableView {
                Label(L10n.CulturalNorms.errorTitle, systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button(String(localized: L10n.CulturalNorms.retry)) {
                    Task { await store.refresh(groupId: groupId) }
                }
            }
            .listRowBackground(Color.clear)
        case .loaded:
            if !store.hasNorms {
                ContentUnavailableView {
                    Label(L10n.CulturalNorms.emptyTitle, systemImage: "sparkles")
                } description: {
                    Text(L10n.CulturalNorms.emptyDescription)
                } actions: {
                    Button {
                        store.beginCreating()
                    } label: {
                        Text(L10n.CulturalNorms.addButton)
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
        ForEach(CulturalNormType.displayOrder, id: \.self) { type in
            if let bucket = store.normsByType[type], !bucket.isEmpty {
                Section {
                    ForEach(bucket) { norm in
                        row(for: norm)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    toRetire = norm
                                } label: {
                                    Label(
                                        String(localized: L10n.CulturalNorms.retireAction),
                                        systemImage: "archivebox"
                                    )
                                }

                                Button {
                                    toPromote = norm
                                } label: {
                                    Label(
                                        String(localized: L10n.CulturalNorms.promoteAction),
                                        systemImage: "checkmark.seal"
                                    )
                                }
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                Button {
                                    Task { await store.endorse(normId: norm.id, groupId: groupId) }
                                } label: {
                                    Label(
                                        String(localized: L10n.CulturalNorms.endorseButton),
                                        systemImage: "hand.thumbsup"
                                    )
                                }
                            }
                            .contextMenu {
                                Button {
                                    toPromote = norm
                                } label: {
                                    Label(
                                        String(localized: L10n.CulturalNorms.promoteAction),
                                        systemImage: "checkmark.seal"
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
    private func row(for norm: GroupCulturalNorm) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(norm.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
                Text(endorsementsLabel(norm.endorsedCount))
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(.quaternary))
            }
            if let body = norm.body, !body.isEmpty {
                Text(body)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            HStack(spacing: 8) {
                Text(norm.status.label)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.quaternary))
                    .foregroundStyle(norm.isEndorsed ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                if let who = norm.proposedByDisplayName, !who.isEmpty {
                    Text(proposedBySubtitle(who))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func endorsementsLabel(_ count: Int) -> String {
        if count == 1 {
            return String(localized: L10n.CulturalNorms.endorsedSingular)
        }
        return "\(count) respaldos"
    }

    private func proposedBySubtitle(_ who: String) -> String {
        "Propuesto por \(who)"
    }

    private var retireDialogBinding: Binding<Bool> {
        Binding(
            get: { toRetire != nil },
            set: { if !$0 { toRetire = nil } }
        )
    }

    @ViewBuilder
    private var placeholderRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Placeholder norma").font(.body.weight(.semibold))
            Text("Placeholder descripción de la norma cultural.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .redacted(reason: .placeholder)
    }
}
