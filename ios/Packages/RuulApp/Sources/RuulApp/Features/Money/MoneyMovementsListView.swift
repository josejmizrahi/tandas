import SwiftUI
import RuulCore

/// Paginated movements feed (Primitiva 19, A2.b). Newest-first list
/// with chip-row filter (Todos / Gasto / Liquidación / Multa /
/// Contribución / Cuota) and infinite scroll via seq cursor. Pushed
/// from `MoneyDashboardView`. Pure read surface — no mutations.
struct MoneyMovementsListView: View {
    let container: DependencyContainer
    let groupId: UUID
    let myMembershipId: UUID

    @State private var pendingDetail: MoneyMovement?
    /// V3 Batch B-2 — pendiente push a MemberDetailView desde una party
    /// row del MovementDetail. Resolved client-side desde
    /// `membersStore.items` con el membership_id que el detail emite.
    @State private var pendingMemberSelection: MembershipBoundaryItem?

    var body: some View {
        List {
            filterRow
            content
        }
        .navigationTitle(L10n.MoneyMovements.title)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await container.movementsStore.refresh(groupId: groupId)
        }
        .navigationDestination(item: $pendingDetail) { movement in
            MoneyMovementDetailView(
                movement: movement,
                myMembershipId: myMembershipId,
                mandatesStore: container.mandatesStore,
                onSelectMember: { membershipId in
                    if let item = container.membersStore.items.first(where: {
                        $0.membershipId == membershipId
                    }) {
                        pendingMemberSelection = item
                    }
                }
            )
        }
        .navigationDestination(item: $pendingMemberSelection) { item in
            MemberDetailView(
                sanctionsStore: container.sanctionsStore,
                reputationStore: container.reputationStore,
                moneyStore: container.moneyStore,
                rolesStore: container.rolesStore,
                membersStore: container.membersStore,
                groupId: groupId,
                memberItem: item,
                activityFetcher: { gid, mid, limit in
                    try await container.rpcClient.groupEventsForMember(
                        groupId: gid,
                        membershipId: mid,
                        limit: limit
                    )
                },
                permissionsFetcher: { gid in
                    try await container.groupRepository.listMemberPermissions(
                        groupId: gid,
                        userId: nil
                    )
                },
                quickActionStores: MemberDetailView.QuickActionStores(
                    mandates: container.mandatesStore,
                    reputationFeed: container.reputationFeedStore
                )
            )
        }
        .task {
            await container.movementsStore.refreshIfNeeded(groupId: groupId)
            // V3 Batch B-2 — necesario para resolver tap-on-party del
            // MovementDetail; si membersStore aún no cargó la lista,
            // el tap no encuentra match y queda no-op.
            await container.membersStore.refreshIfNeeded(groupId: groupId)
        }
    }

    // MARK: - Filter chips

    @ViewBuilder
    private var filterRow: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    chip(
                        label: String(localized: L10n.MoneyMovements.allFilter),
                        systemImage: "circle.grid.2x2",
                        isActive: container.movementsStore.activeFilter.isEmpty
                    ) {
                        Task {
                            await container.movementsStore.setFilter([], groupId: groupId)
                        }
                    }
                    ForEach(MoneyMovementType.foundationFilters) { type in
                        chip(
                            label: String(localized: type.label),
                            systemImage: type.systemImageName,
                            isActive: container.movementsStore.activeFilter.contains(type)
                        ) {
                            toggleFilter(type)
                        }
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 4)
            }
            .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    @ViewBuilder
    private func chip(
        label: String,
        systemImage: String,
        isActive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(label, systemImage: systemImage)
                .font(.subheadline.weight(.medium))
                .labelStyle(.titleAndIcon)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(isActive
                                   ? Color.accentColor.opacity(0.18)
                                   : Color.gray.opacity(0.10))
                )
                .foregroundStyle(isActive ? Color.accentColor : .primary)
        }
        .buttonStyle(.plain)
    }

    private func toggleFilter(_ type: MoneyMovementType) {
        var next = container.movementsStore.activeFilter
        if next.contains(type) {
            next.remove(type)
        } else {
            next.insert(type)
        }
        Task {
            await container.movementsStore.setFilter(next, groupId: groupId)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch container.movementsStore.phase {
        case .idle, .loading:
            ForEach(0..<4, id: \.self) { _ in placeholderRow }
        case .failed(let message):
            Section {
                ContentUnavailableView {
                    Label(L10n.MoneyMovements.errorTitle, systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button(String(localized: L10n.MoneyMovements.retry)) {
                        Task { await container.movementsStore.refresh(groupId: groupId) }
                    }
                }
                .listRowBackground(Color.clear)
            }
        case .loaded:
            if container.movementsStore.movements.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label(L10n.MoneyMovements.emptyTitle, systemImage: "tray")
                    } description: {
                        Text(L10n.MoneyMovements.emptyDescription)
                    }
                    .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    ForEach(container.movementsStore.movements) { movement in
                        Button {
                            pendingDetail = movement
                        } label: {
                            row(for: movement)
                        }
                        .buttonStyle(.plain)
                        .onAppear {
                            maybeLoadMore(for: movement)
                        }
                    }
                    if container.movementsStore.isLoadingMore {
                        HStack {
                            Spacer()
                            ProgressView()
                                .padding(.vertical, 8)
                            Spacer()
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func row(for movement: MoneyMovement) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: movement.type.systemImageName)
                .font(.body.weight(.medium))
                .foregroundStyle(.tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(movement.headline)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(movement.type.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let counterparty = movement.counterpartyLabel, !counterparty.isEmpty {
                    Text(counterparty)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                if let when = movement.when {
                    Text(when, format: .dateTime.day().month().year().hour().minute())
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(movement.amount.formatted()) \(movement.unit)")
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.primary)
                    .strikethrough(movement.isReversal)
                if movement.inKind {
                    Text(L10n.MoneyMovements.inKindHint)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func maybeLoadMore(for movement: MoneyMovement) {
        let store = container.movementsStore
        guard !store.reachedEnd, !store.isLoadingMore else { return }
        let trailingWindow = 6
        guard let index = store.movements.firstIndex(of: movement) else { return }
        if index >= store.movements.count - trailingWindow {
            Task { await store.loadMore(groupId: groupId) }
        }
    }

    @ViewBuilder
    private var placeholderRow: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "circle").frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text("Placeholder movement").font(.body.weight(.semibold))
                Text("Placeholder type").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("$0").font(.body.monospacedDigit())
        }
        .redacted(reason: .placeholder)
    }
}
